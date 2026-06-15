from fastapi import APIRouter, Depends, HTTPException, Request, Query
from firebase_config import get_firestore
from auth import get_current_user
from gemini import process_chat_message, parse_notification_text
from schemas.categories import EXPENSE_CATEGORIES
from utils import (
    get_current_month_key, serialize_doc,
    sum_month_expense, sum_category_expense, fetch_budget,
    get_today_date_range, get_week_date_range,
    sum_month_income, is_today, resolve_month_key,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment
from typing import Optional
from services.notification_service import resolve_category_from_receiver_name, parse_receiver_name
from services.report_service import (
    get_missing_budget_categories,
    get_top_spending_category,
    get_spend_alerts
)
import logging

logger = logging.getLogger("bachatbot.chat")

router = APIRouter()


# ═══════════════════════════════════════════════════════════════════════════════
# Helpers — one function per action type
# ═══════════════════════════════════════════════════════════════════════════════

def _handle_expense_or_income(db, uid, action, source, month_key, idempotency_key=None):
    """
    Save transaction, increment budget.spent (if expense + budget exists),
    create a transaction_saved alert.
    Returns (transaction_dict, budget_update_or_None, alert_or_None, reply_part).

    If idempotency_key is provided, checks for an existing transaction with
    that key first and skips the write if found (prevents duplicates during
    offline sync recovery).
    """
    amount = float(action["amount"])
    category = action.get("category")
    tx_type = action.get("type", "expense")
    description = action.get("description", "")

    # ── Idempotency check — skip if transaction already exists ───────────
    existing_tx = None
    if idempotency_key:
        try:
            existing_docs = list(
                db.collection("users").document(uid)
                .collection("transactions")
                .where("idempotencyKey", "==", idempotency_key)
                .limit(1)
                .stream()
            )
            if existing_docs:
                existing_tx = existing_docs[0]
                print(f"[CHAT] Idempotency hit: key={idempotency_key} tx={existing_tx.id} — skipping duplicate write")
        except Exception as e:
            print(f"[CHAT] Idempotency check failed (proceeding with write): {e}")

    if existing_tx:
        # Return the existing record without creating a duplicate
        ed = existing_tx.to_dict()
        tx_ref_id = existing_tx.id
        transaction_out = {
            "id": tx_ref_id,
            "amount": ed.get("amount", amount),
            "category": ed.get("category", category),
            "type": ed.get("type", tx_type),
            "status": ed.get("status", "confirmed"),
            "source": ed.get("source", source),
            "description": ed.get("description", description),
            "monthKey": ed.get("monthKey", month_key),
            "isDeleted": ed.get("isDeleted", False),
            "deletedAt": None,
            "originalMessageId": None,
            "deduplicated": True,
        }
        cat_display = category or "Income"
        reply_part = f"Rs {int(amount)} {cat_display}"
        # Still check budget status for the reply but don't increment
        return transaction_out, None, None, reply_part

    # ── Save transaction ─────────────────────────────────────────────────
    tx_ref = (
        db.collection("users").document(uid)
        .collection("transactions").document()
    )
    tx_data = {
        "amount": amount,
        "category": category,
        "type": tx_type,
        "status": "confirmed",
        "source": source,
        "description": description,
        "monthKey": month_key,
        "isDeleted": False,
        "deletedAt": None,
        "originalMessageId": None,
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    }
    if idempotency_key:
        tx_data["idempotencyKey"] = idempotency_key
    tx_ref.set(tx_data)
    print(f"[CHAT] Transaction saved: id={tx_ref.id} {tx_type} {category} Rs {amount}")

    transaction_out = {
        "id": tx_ref.id,
        "amount": amount,
        "category": category,
        "type": tx_type,
        "status": "confirmed",
        "source": source,
        "description": description,
        "monthKey": month_key,
        "isDeleted": False,
        "deletedAt": None,
        "originalMessageId": None,
    }

    # ── Budget increment (expenses only) ─────────────────────────────────
    budget_update = None
    percent_used = 0.0

    if tx_type == "expense" and category:
        budgets_ref = db.collection("users").document(uid).collection("budgets")
        matching = list(
            budgets_ref
            .where("category", "==", category)
            .where("monthKey", "==", month_key)
            .limit(1)
            .stream()
        )
        if matching:
            bref = matching[0].reference
            old_spent = matching[0].to_dict().get("spent", 0.0)
            bref.update({
                "spent": Increment(amount),
                "updatedAt": SERVER_TIMESTAMP,
            })
            updated = bref.get().to_dict()
            new_spent = updated.get("spent", 0.0)
            blimit = updated.get("limit", 0.0)
            remaining = max(0.0, blimit - new_spent)
            percent_used = round((new_spent / blimit) * 100, 2) if blimit > 0 else 0.0
            budget_update = {
                "id": matching[0].id,
                "category": updated.get("category", category),
                "limit": blimit,
                "spent": new_spent,
                "remaining": remaining,
                "percentUsed": percent_used,
                "monthKey": month_key,
            }
            print(f"[CHAT] [BUDGET] {category}: spent {old_spent} -> {new_spent} ({percent_used}%)")

            # Rebalance if overspent — purely additive, no other flow changes
            if new_spent > blimit:
                try:
                    from services.budget_service import rebalance_on_overspend
                    rb = rebalance_on_overspend(
                        db, uid, category, new_spent, blimit, matching[0].id, month_key
                    )
                    if rb:
                        budget_update["limit"] = rb["newLimit"]
                        budget_update["remaining"] = max(0.0, rb["newLimit"] - new_spent)
                        budget_update["percentUsed"] = round(
                            (new_spent / rb["newLimit"]) * 100, 2
                        ) if rb["newLimit"] > 0 else 0.0
                        print(f"[CHAT] [REBALANCE] covered Rs {rb['totalCovered']:.0f} of Rs {rb['overspend']:.0f}")
                except Exception as _rb_err:
                    print(f"[CHAT] [REBALANCE] error (non-fatal): {_rb_err}")
        else:
            print(f"[CHAT] [BUDGET] No budget for '{category}' in {month_key}")

    # ── Alert ────────────────────────────────────────────────────────────
    alert_out = None
    desc = description.strip() if description else ""
    try:
        if tx_type == "expense":
            if desc and desc.lower() not in ((category or "").lower(), "expense", ""):
                msg = f"Rs {int(amount)} {desc} ({category or 'expense'}) saved."
            else:
                cat_label = f"{category} " if category else ""
                msg = f"Rs {int(amount)} {cat_label}expense saved."
            if budget_update and percent_used >= 80:
                msg = f"{category} Rs {int(amount)} saved, {int(percent_used)}% budget used!"
            alert_type = "expense"
        else:
            cat_label = category or "income"
            msg = f"Rs {int(amount)} {cat_label} income added."
            alert_type = "income"

        aref = db.collection("users").document(uid).collection("alerts").document()
        aref.set({
            "type": alert_type,
            "message": msg,
            "category": category,
            "severity": "medium" if percent_used >= 80 else "low",
            "isRead": False,
            "isDeleted": False,
            "monthKey": month_key,
            "relatedTransactionId": tx_ref.id,
            "createdAt": SERVER_TIMESTAMP,
        })
        alert_out = {
            "id": aref.id, "type": alert_type,
            "message": msg, "category": category,
            "severity": "medium" if percent_used >= 80 else "low",
            "isRead": False, "monthKey": month_key,
            "relatedTransactionId": tx_ref.id,
        }
        print(f"[CHAT] [ALERT] {aref.id}: '{msg}'")
    except Exception as e:
        print(f"[CHAT] [ALERT] FAILED: {e}")

    # Reply part — include item/note if provided
    cat_display = category or "Income"
    if desc and desc.lower() not in (cat_display.lower(), "expense", "income", ""):
        reply_part = f"Rs {int(amount)} {desc} ({cat_display})"
    else:
        reply_part = f"Rs {int(amount)} {cat_display}"

    return transaction_out, budget_update, alert_out, reply_part


def _handle_set_budget(db, uid, action, month_key):
    """
    Upsert budget: overwrite limit, keep spent.
    Returns (budget_update_dict, alert_or_None, reply_part).

    Rejects the update if the new limit is below the amount already spent
    in this category for the given month.
    """
    category = action.get("category")
    limit_val = float(action["limit"])

    print(f"[CHAT] Setting budget: {category} limit=Rs {limit_val} monthKey={month_key}")

    # ── Spent-floor validation ────────────────────────────────────────────
    actual_spent = sum_category_expense(db, uid, category, month_key)
    if limit_val < actual_spent:
        print(
            f"[CHAT] [BUDGET] REJECTED: {category} limit Rs {limit_val} "
            f"< already spent Rs {actual_spent}"
        )
        reply_part = (
            f"{category} budget Rs {int(limit_val)} set garna mildaina — "
            f"timi yesma Rs {int(actual_spent)} kharcha garisakeko chau yo mahina. "
            f"Budget Rs {int(actual_spent)} bhanda mathi set gara."
        )
        return None, None, reply_part

    budgets_ref = db.collection("users").document(uid).collection("budgets")
    matching = list(
        budgets_ref
        .where("category", "==", category)
        .where("monthKey", "==", month_key)
        .limit(1)
        .stream()
    )

    if matching:
        bref = matching[0].reference
        bref.update({"limit": limit_val, "updatedAt": SERVER_TIMESTAMP})
        budget_id = matching[0].id
        spent = matching[0].to_dict().get("spent", 0.0)
        print(f"[CHAT] [BUDGET] Updated id={budget_id}, kept spent={spent}")
    else:
        new_ref = budgets_ref.document()
        new_ref.set({
            "category": category,
            "limit": limit_val,
            "spent": 0.0,
            "alertThreshold": 80,
            "monthKey": month_key,
            "createdAt": SERVER_TIMESTAMP,
            "updatedAt": SERVER_TIMESTAMP,
        })
        budget_id = new_ref.id
        spent = 0.0
        print(f"[CHAT] [BUDGET] Created id={budget_id}")

    pct = round((spent / limit_val) * 100, 2) if limit_val > 0 else 0.0
    remaining = max(0.0, limit_val - spent)
    budget_update = {
        "id": budget_id,
        "category": category,
        "limit": limit_val,
        "spent": spent,
        "remaining": remaining,
        "percentUsed": pct,
        "monthKey": month_key,
    }

    # Alert
    alert_out = None
    try:
        msg = f"{category} budget Rs {int(limit_val)} set gareko chu."
        aref = db.collection("users").document(uid).collection("alerts").document()
        aref.set({
            "type": "budget_set",
            "message": msg,
            "category": category,
            "severity": "low",
            "isRead": False,
            "isDeleted": False,
            "monthKey": month_key,
            "createdAt": SERVER_TIMESTAMP,
        })
        alert_out = {
            "id": aref.id, "type": "budget_set",
            "message": msg, "category": category,
            "severity": "low", "isRead": False, "monthKey": month_key,
        }
        print(f"[CHAT] [ALERT] {aref.id}: '{msg}'")
    except Exception as e:
        print(f"[CHAT] [ALERT] FAILED: {e}")

    reply_part = f"{category} budget Rs {int(limit_val)} set"

    return budget_update, alert_out, reply_part


# ═══════════════════════════════════════════════════════════════════════════════
# POST /chat
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/chat")
@router.post("/messages")
async def chat(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    body = await request.json()
    user_message = body.get("message") or body.get("text", "")
    user_message = user_message.strip()
    source = body.get("source", "chat")
    idempotency_key = body.get("idempotencyKey") or None

    # ── Request logging (confirms the route is being hit) ────────────────
    logger.info("[CHAT] POST /messages user=%s body=%s", uid, body)

    print(f"\n{'='*60}")
    print(f"[CHAT] uid={uid} source={source} message='{user_message}'")
    print(f"{'='*60}")

    if not user_message:
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {"code": "EMPTY_MESSAGE", "message": "Message cannot be empty."},
            },
        )

    # ── Save user message ────────────────────────────────────────────────
    messages_ref = db.collection("users").document(uid).collection("messages")
    user_msg_ref = messages_ref.document()
    user_msg_ref.set({
        "role": "user",
        "parts": [{"text": user_message}],
        "content": user_message,  # Keep for backward compatibility
        "intent": None,
        "extractedData": None,
        "relatedTransactionId": None,
        "status": "pending",       # Will be updated to "delivered" after bot replies
        "createdAt": SERVER_TIMESTAMP,
    })

    # ── Fetch Chat History (Sliding Window: last 20 messages) ───────────
    history = []
    try:
        hist_docs = list(
            messages_ref
            .order_by("createdAt", direction="DESCENDING")
            .limit(20)
            .stream()
        )
        hist_docs.reverse() # Chronological order
        
        last_role = None
        for doc in hist_docs:
            m = doc.to_dict()
            if doc.id == user_msg_ref.id:
                continue # Skip the message we just saved
                
            h_role = m.get("role")
            if h_role == "assistant": h_role = "model"
            
            h_parts = m.get("parts")
            if not h_parts and m.get("content"):
                h_parts = [{"text": m.get("content")}]
            
            if h_role and h_parts:
                # Strictly enforce alternating roles for Gemini
                if h_role != last_role:
                    history.append({"role": h_role, "parts": h_parts})
                    last_role = h_role
        
        # If history ends with 'user', we might want to trim it so the next 
        # message (which is always 'user') doesn't break alternation.
        if history and history[-1]["role"] == "user":
            history.pop()

    except Exception as hist_err:
        print(f"[CHAT] History fetch failed: {hist_err}")

    # ── Conversational Confirmation Check ────────────────────────────────
    from utils import is_affirmative, is_denial
    
    pending_ref = db.collection("users").document(uid).collection("pendingAction").document("current")
    pending_doc = pending_ref.get()
    
    if pending_doc.exists and source != "notification":
        pending = pending_doc.to_dict()
        text_lower = user_message.lower().strip()
        
        if is_affirmative(text_lower):
            # COMMIT: confirm the pending Firestore transactions that were
            # already saved when the user first typed the expense message.
            last_transaction = None
            last_budget_update = None
            alerts_created = []
            reply_parts = []
            
            actions = pending.get("actions", [])
            month_key = pending.get("monthKey") or get_current_month_key()
            pending_source = pending.get("source", "chat")
            # IDs of the pending transactions already stored in Firestore
            pending_tx_ids = pending.get("pendingTxIds", [])
            
            if pending_tx_ids:
                # ── Confirm each pre-saved pending transaction ───────────
                for tx_id in pending_tx_ids:
                    try:
                        tx_ref = (
                            db.collection("users").document(uid)
                            .collection("transactions").document(tx_id)
                        )
                        tx_doc = tx_ref.get()
                        if not tx_doc.exists:
                            print(f"[CHAT][CONFIRM] Pending tx {tx_id} not found — skipping")
                            continue
                        tx = tx_doc.to_dict()
                        if tx.get("status") != "pending":
                            print(f"[CHAT][CONFIRM] tx {tx_id} already {tx.get('status')} — skipping")
                            continue

                        amount   = float(tx.get("amount", 0))
                        category = tx.get("category")
                        tx_type  = tx.get("type", "expense")
                        tx_mk    = tx.get("monthKey", month_key)

                        if tx.get("source") == "notification" and not category:
                            # ENFORCE CATEGORY: If it's a notification and we don't have a category yet,
                            # we cannot confirm it. Ask the user for the category.
                            cat_options = "/".join(c for c in EXPENSE_CATEGORIES if c != "Other")
                            reply = f"Kun category ma halne? ({cat_options}/Other)"
                            
                            assistant_msg_ref = messages_ref.document()
                            assistant_msg_ref.set({
                                "role": "model",
                                "parts": [{"text": reply}],
                                "content": reply,
                                "intent": "notification_parse_ask_category",
                                "extractedData": None,
                                "relatedTransactionId": tx_id,
                                "createdAt": SERVER_TIMESTAMP,
                            })
                            return {
                                "success": True,
                                "data": {
                                    "reply": reply,
                                    "intent": "notification_parse_ask_category",
                                    "needsConfirmation": True,
                                    "transaction": tx,
                                    "budgetUpdate": None,
                                    "alerts": [],
                                },
                            }

                        tx_ref.update({
                            "status":    "confirmed",
                            "updatedAt": SERVER_TIMESTAMP,
                        })

                        # Budget increment for expenses
                        budget_update = None
                        percent_used  = 0.0
                        if tx_type == "expense" and category:
                            bud_docs = list(
                                db.collection("users").document(uid).collection("budgets")
                                .where("category", "==", category)
                                .where("monthKey", "==", tx_mk)
                                .limit(1)
                                .stream()
                            )
                            if bud_docs:
                                bref = bud_docs[0].reference
                                bref.update({
                                    "spent":     Increment(amount),
                                    "updatedAt": SERVER_TIMESTAMP,
                                })
                                upd = bref.get().to_dict()
                                new_spent    = upd.get("spent", 0.0)
                                blimit       = upd.get("limit", 0.0)
                                remaining    = max(0.0, blimit - new_spent)
                                percent_used = round((new_spent / blimit) * 100, 2) if blimit > 0 else 0.0
                                budget_update = {
                                    "id":          bud_docs[0].id,
                                    "category":    category,
                                    "limit":       blimit,
                                    "spent":       new_spent,
                                    "remaining":   remaining,
                                    "percentUsed": percent_used,
                                    "monthKey":    tx_mk,
                                }
                                print(f"[CHAT][CONFIRM] Budget {category}: spent={new_spent} ({percent_used}%)")

                        if budget_update:
                            last_budget_update = budget_update

                        # Alert
                        try:
                            if tx_type == "expense":
                                cat_label = f"{category} " if category else ""
                                msg = f"Rs {int(amount)} {cat_label}expense saved."
                                if budget_update and percent_used >= 80:
                                    msg = f"{category} Rs {int(amount)} saved, {int(percent_used)}% budget used!"
                                alert_type = "expense"
                            else:
                                cat_label = category or "income"
                                msg = f"Rs {int(amount)} {cat_label} income added."
                                alert_type = "income"

                            aref = db.collection("users").document(uid).collection("alerts").document()
                            aref.set({
                                "type":                  alert_type,
                                "message":               msg,
                                "category":              category,
                                "severity":              "medium" if percent_used >= 80 else "low",
                                "isRead":                False,
                                "isDeleted":             False,
                                "monthKey":              tx_mk,
                                "relatedTransactionId":  tx_id,
                                "createdAt":             SERVER_TIMESTAMP,
                            })
                            alerts_created.append({
                                "id":       aref.id, "type": alert_type,
                                "message":  msg,     "category": category,
                                "severity": "medium" if percent_used >= 80 else "low",
                                "isRead":   False,   "monthKey": tx_mk,
                                "relatedTransactionId": tx_id,
                            })
                        except Exception as ae:
                            print(f"[CHAT][CONFIRM] Alert FAILED: {ae}")

                        cat_display = category or "Income"
                        reply_parts.append(f"Rs {int(amount)} {cat_display}")
                        last_transaction = {
                            "id":       tx_id,
                            "amount":   amount,
                            "category": category,
                            "type":     tx_type,
                            "status":   "confirmed",
                            "source":   tx.get("source", pending_source),
                            "monthKey": tx_mk,
                        }
                        print(f"[CHAT][CONFIRM] Confirmed tx {tx_id} Rs {amount} {category}")
                    except Exception as ce:
                        print(f"[CHAT][CONFIRM] Error confirming tx {tx_id}: {ce}")
            else:
                # Fallback: no stored IDs (old pending format) — create new confirmed transactions
                for action in actions:
                    txn, bud, alt, rp = _handle_expense_or_income(
                        db, uid, action, pending_source, month_key,
                    )
                    last_transaction = txn
                    if bud:
                        last_budget_update = bud
                    if alt:
                        alerts_created.append(alt)
                    reply_parts.append(rp)
                
            pending_ref.delete()
            
            # Save assistant message
            assistant_msg_ref = messages_ref.document()
            primary_intent = "confirm_expense"
            
            # Synthesize combined reply
            if len(reply_parts) > 1:
                reply = ", ".join(reply_parts) + " ma save gareko chu ✅"
            elif reply_parts:
                reply = reply_parts[0] + " ma save gareko chu ✅"
            else:
                reply = "Kharcha save gareko chu ✅"
                
            assistant_msg_ref.set({
                "role": "model",
                "parts": [{"text": reply}],
                "content": reply,
                "intent": primary_intent,
                "extractedData": [
                    {k: a.get(k) for k in ("intent", "amount", "category", "type", "limit", "monthKey")}
                    for a in actions
                ],
                "relatedTransactionId": last_transaction["id"] if last_transaction else None,
                "createdAt": SERVER_TIMESTAMP,
            })
            
            return {
                "success": True,
                "data": {
                    "reply": reply,
                    "intent": primary_intent,
                    "needsConfirmation": False,
                    "transaction": last_transaction,
                    "budgetUpdate": last_budget_update,
                    "alerts": alerts_created,
                },
            }
            
        elif is_denial(text_lower):
            pending_tx_ids = pending.get("pendingTxIds", [])

            if pending.get("waitingForBudget"):
                # User said skip/no to setting budget → confirm the expense WITHOUT a budget
                exp_month_key = pending.get("monthKey", get_current_month_key())
                waiting_cat = pending.get("waitingCategory", "")
                confirmed_tx = None
                for tx_id in pending_tx_ids:
                    try:
                        tx_ref_tmp = db.collection("users").document(uid).collection("transactions").document(tx_id)
                        tx_doc_tmp = tx_ref_tmp.get()
                        if tx_doc_tmp.exists and tx_doc_tmp.to_dict().get("status") == "pending":
                            tx_ref_tmp.update({"status": "confirmed", "updatedAt": SERVER_TIMESTAMP})
                            confirmed_tx = {
                                "id": tx_id,
                                "amount": tx_doc_tmp.to_dict().get("amount", 0),
                                "category": waiting_cat,
                                "type": "expense", "status": "confirmed",
                                "monthKey": exp_month_key,
                            }
                    except Exception as ce:
                        print(f"[CHAT][SKIP-BUDGET] Error confirming tx {tx_id}: {ce}")
                pending_ref.delete()
                reply = (
                    f"Thik cha, {waiting_cat} ko budget ahile set gareina. "
                    f"Expense ta save bhayeko cha ✅\n"
                    f"Category page bata kahile pani budget set garna saknuhuncha."
                )
            else:
                # DISCARD: mark pending transactions as cancelled
                for tx_id in pending_tx_ids:
                    try:
                        db.collection("users").document(uid).collection("transactions").document(tx_id).update({
                            "status": "cancelled",
                            "updatedAt": SERVER_TIMESTAMP
                        })
                        print(f"[CHAT][CANCEL] Marked tx {tx_id} as cancelled")
                    except Exception as ce:
                        print(f"[CHAT][CANCEL] Error cancelling tx {tx_id}: {ce}")
                pending_ref.delete()
                reply = "Thik cha, cancel gareko chu."

            # Save assistant message
            assistant_msg_ref = messages_ref.document()
            assistant_msg_ref.set({
                "role": "model",
                "parts": [{"text": reply}],
                "content": reply,
                "intent": "confirm_expense",
                "extractedData": None,
                "relatedTransactionId": None,
                "createdAt": SERVER_TIMESTAMP,
            })

            return {
                "success": True,
                "data": {
                    "reply": reply,
                    "intent": "confirm_expense",
                    "needsConfirmation": False,
                    "transaction": None,
                    "budgetUpdate": None,
                    "alerts": [],
                },
            }

        else:
            # User sent a new message — preserve pendingAction if waiting for budget set
            if pending.get("waitingForBudget"):
                print("[CHAT] Keeping pending action (waitingForBudget=True) for budget set handling.")
            else:
                pending_ref.delete()
                print("[CHAT] Pending action discarded due to new unrelated user message.")

    # ════════════════════════════════════════════════════════════════════
    # NOTIFICATION BRANCH — source == "notification"
    # Creates a PENDING transaction + notification doc.
    # Does NOT update budgets or confirm the transaction.
    # Returns early with needsConfirmation = true.
    # ════════════════════════════════════════════════════════════════════
    if source == "notification":
        source_app = body.get("sourceApp", "Unknown")
        original_message_id = body.get("originalMessageId", None)
        month_key = get_current_month_key()

        # A. Parse via Gemini (notification-specific prompt)
        parsed = await parse_notification_text(user_message)
        amount    = parsed.get("amount", 0.0)
        category  = parsed.get("category")   # can be None now
        tx_type   = parsed.get("type", "expense")

        # Determine if category is uncertain
        category_uncertain = (
            category is None
            or category in ("Other", "Unknown", "other", "unknown")
        )

        print(
            f"[CHAT][NOTIF] uid={uid} app={source_app} "
            f"amount={amount} category={category} type={tx_type} "
            f"uncertain={category_uncertain}"
        )

        # B. Parse receiver name + resolve suggested category
        receiver_name = parse_receiver_name(user_message)
        suggested_category = resolve_category_from_receiver_name(receiver_name)
        # If resolver gives a category, use it (overrides uncertain flag)
        if suggested_category and category_uncertain:
            category = suggested_category
            category_uncertain = False
            print(f"[CHAT][NOTIF] receiver_name='{receiver_name}' resolved → category='{category}'")
        else:
            print(f"[CHAT][NOTIF] receiver_name='{receiver_name}' suggestedCategory='{suggested_category}'")

        # C. Create PENDING transaction
        tx_ref = (
            db.collection("users").document(uid)
            .collection("transactions").document()
        )
        tx_data = {
            "amount":             float(amount),
            "category":           category if not category_uncertain else None,
            "type":               tx_type,
            "status":             "pending",
            "source":             "notification",
            "description":        user_message,
            "monthKey":           month_key,
            "isDeleted":          False,
            "deletedAt":          None,
            "originalMessageId":  original_message_id,
            # New fields for notification-based transactions
            "receiverName":       receiver_name,
            "suggestedCategory":  suggested_category,
            "createdAt":          SERVER_TIMESTAMP,
            "updatedAt":          SERVER_TIMESTAMP,
        }
        tx_ref.set(tx_data)
        print(f"[CHAT][NOTIF] Pending transaction created: id={tx_ref.id}")

        transaction_out = {
            "id":                tx_ref.id,
            "amount":            float(amount),
            "category":          category if not category_uncertain else None,
            "type":              tx_type,
            "status":            "pending",
            "source":            "notification",
            "description":       user_message,
            "monthKey":          month_key,
            "isDeleted":         False,
            "deletedAt":         None,
            "originalMessageId": original_message_id,
            "receiverName":      receiver_name,
            "suggestedCategory": suggested_category,
        }

        # D. Create notification doc
        notif_ref = (
            db.collection("users").document(uid)
            .collection("notifications").document()
        )
        notif_data = {
            "rawText":           user_message,
            "parsedAmount":      float(amount),
            "parsedCategory":    category if not category_uncertain else None,
            "parsedType":        tx_type,
            "sourceApp":         source_app,
            "status":            "pending",
            "transactionId":     tx_ref.id,
            # New fields
            "receiverName":      receiver_name,
            "suggestedCategory": suggested_category,
            "createdAt":         SERVER_TIMESTAMP,
        }
        notif_ref.set(notif_data)
        print(f"[CHAT][NOTIF] Notification doc created: id={notif_ref.id}")

        notification_out = {
            "id":                notif_ref.id,
            "rawText":           user_message,
            "parsedAmount":      float(amount),
            "parsedCategory":    category if not category_uncertain else None,
            "parsedType":        tx_type,
            "sourceApp":         source_app,
            "status":            "pending",
            "transactionId":     tx_ref.id,
            "receiverName":      receiver_name,
            "suggestedCategory": suggested_category,
        }

        # Save pending action for conversational follow-up
        pending_ref = db.collection("users").document(uid).collection("pendingAction").document("current")
        pending_ref.set({
            "actions": [{
                "intent": "confirm_expense",
                "amount": float(amount),
                "category": category if not category_uncertain else None,
                "type": tx_type,
            }],
            "pendingTxIds": [tx_ref.id],
            "source": "notification",
            "monthKey": month_key,
            "createdAt": SERVER_TIMESTAMP,
        })

        # E. Build reply — different for certain vs uncertain category
        if category_uncertain:
            # Category unknown → ask the user
            cat_options = "/".join(c for c in EXPENSE_CATEGORIES if c != "Other")
            receiver_hint = f" ({receiver_name})" if receiver_name else ""
            if tx_type == "expense":
                reply = (
                    f"{source_app} bata Rs {int(amount)} expense detect bhayo{receiver_hint}. "
                    f"Kun category ma halne? ({cat_options}/Other)"
                )
            else:
                reply = (
                    f"{source_app} bata Rs {int(amount)} income detect bhayo{receiver_hint}. "
                    f"Kun category ma halne? ({cat_options}/Other)"
                )
            reply_intent = "notification_parse_ask_category"
        else:
            # Category is confident
            if tx_type == "expense":
                reply = (
                    f"{source_app} bata Rs {int(amount)} {category} ma "
                    f"kharcha bhako jasto cha. Thik cha?"
                )
            else:
                reply = (
                    f"{source_app} bata Rs {int(amount)} income aayeko "
                    f"jasto cha. Thik cha?"
                )
            reply_intent = "notification_parse"

        # Save assistant message
        assistant_msg_ref = messages_ref.document()
        assistant_msg_ref.set({
            "role":                 "model",
            "parts":                [{"text": reply}],
            "content":              reply,
            "intent":               reply_intent,
            "extractedData":        [{
                "intent": reply_intent,
                "amount": float(amount),
                "category": category if not category_uncertain else None,
                "type": tx_type,
            }],
            "relatedTransactionId": tx_ref.id,
            "status": "delivered",
            "createdAt":            SERVER_TIMESTAMP,
        })
        # Mark user message as delivered now that backend processed it
        try:
            user_msg_ref.update({"status": "delivered"})
        except Exception:
            pass

        # E. Return notification-style response
        return {
            "success": True,
            "data": {
                "reply":             reply,
                "intent":            reply_intent,
                "needsConfirmation": True,
                "categoryUncertain": category_uncertain,
                "transaction":       transaction_out,
                "notification":      notification_out,
                "budgetUpdate":      None,
                "alerts":            [],
            },
        }
    # ════════════════════════════════════════════════════════════════════
    # END NOTIFICATION BRANCH — normal chat flow continues below
    # ════════════════════════════════════════════════════════════════════

    # ── Fetch user context for personalized Gemini responses ────────────
    first_name = "User"
    is_first_message = False
    try:
        profile_doc = db.collection("users").document(uid).get()
        if profile_doc.exists:
            profile_data = profile_doc.to_dict()
            first_name = profile_data.get("firstName") or profile_data.get("name") or "User"

        # Check if this is the user's very first chat message
        existing_msgs = list(
            messages_ref
            .where("role", "==", "user")
            .limit(2)
            .stream()
        )
        # Only the message we just saved exists → first message
        is_first_message = len(existing_msgs) <= 1

        # Compute missing budget categories for current month
        curr_month = get_current_month_key()
        missing_budget_categories = get_missing_budget_categories(db, uid, curr_month)

    except Exception as ctx_err:
        print(f"[CHAT] Context lookup failed (non-critical): {ctx_err}")
        missing_budget_categories = []

    # ── Call Gemini ──────────────────────────────────────────────────────
    try:
        gemini_result = await process_chat_message(
            user_message,
            first_name=first_name,
            is_first_message=is_first_message,
            missing_budget_categories=missing_budget_categories,
            history=history,
        )
        gemini_reply = gemini_result["reply"]
        actions = gemini_result["actions"]
    except Exception as gemini_route_err:
        logger.exception("[CHAT] Gemini call failed unexpectedly: %s", gemini_route_err)
        fallback_reply = "Chat server ma samasya aayo. Kehi samay pachi feri try garnus."
        # Save fallback bot message so the conversation is not left hanging
        try:
            messages_ref.document().set({
                "role": "model",
                "parts": [{"text": fallback_reply}],
                "content": fallback_reply,
                "intent": "general_chat",
                "extractedData": None,
                "relatedTransactionId": None,
                "createdAt": SERVER_TIMESTAMP,
            })
        except Exception:
            pass
        return {
            "success": True,
            "data": {
                "reply": fallback_reply,
                "intent": "general_chat",
                "needsConfirmation": False,
                "transaction": None,
                "budgetUpdate": None,
                "alerts": [],
            },
        }

    print(f"[CHAT] uid={uid} actions={[a.get('intent') for a in actions]}")

    # ── Rent category fallback ───────────────────────────────────────────
    # If Gemini returned "Other" but the user clearly mentioned rent,
    # correct the category to "Rent" for expense_log / set_budget actions.
    _RENT_KEYWORDS = ["rent", "room rent", "flat rent", "house rent",
                       "bhada", "ghar bhada", "kotha bhada", "kiraya"]
    text_lower = user_message.lower()
    for action in actions:
        act_intent = action.get("intent", "")
        act_cat = action.get("category") or ""
        if act_intent in ("expense_log", "income_log", "set_budget",
                          "query_category_spend", "query_budget_status"):
            if act_cat.lower() in ("other", "others", ""):
                if any(kw in text_lower for kw in _RENT_KEYWORDS):
                    print(f"[CHAT] Rent fallback: overriding category "
                          f"'{act_cat}' → 'Rent' (matched keyword in message)")
                    action["category"] = "Rent"

    # ── Accumulators ─────────────────────────────────────────────────────
    last_transaction = None
    last_budget_update = None
    alerts_created = []
    reply_parts = []           # pieces like "Rs 150 Food", "Transport budget Rs 5000 set"
    primary_intent = actions[0].get("intent", "general_chat") if actions else "general_chat"
    pending_actions = []

    # Track undone category to inherit it if a correction follows in same turn
    undone_category = None

    # ── Process each action ──────────────────────────────────────────────
    for action in actions:
        intent = action.get("intent", "general_chat")
        raw_mk = action.get("monthKey")
        month_key = resolve_month_key(raw_mk) if raw_mk else get_current_month_key()

        # ── EXPENSE / INCOME ─────────────────────────────────────────────
        if intent in ("expense_log", "income_log") and action.get("amount"):
            # Correction inheritance: if no category but we just did an undo
            if not action.get("category") and undone_category:
                print(f"[CHAT] Correction: inheriting category '{undone_category}' for new {intent}")
                action["category"] = undone_category

            if action.get("category"):
                category_val = action["category"]
                amt_val = int(float(action["amount"]))

                # ── No-budget check for expenses ─────────────────────────
                if intent == "expense_log":
                    bud_check = list(
                        db.collection("users").document(uid).collection("budgets")
                        .where("category", "==", category_val)
                        .where("monthKey", "==", month_key)
                        .limit(1)
                        .stream()
                    )
                    if not bud_check:
                        # No budget for this category → save as pending, ask user to set budget
                        p_tx_ref = (
                            db.collection("users").document(uid)
                            .collection("transactions").document()
                        )
                        p_tx_ref.set({
                            "amount": float(action["amount"]),
                            "category": category_val,
                            "type": "expense",
                            "status": "pending",
                            "source": source,
                            "description": action.get("description", user_message),
                            "monthKey": month_key,
                            "isDeleted": False,
                            "deletedAt": None,
                            "originalMessageId": None,
                            "createdAt": SERVER_TIMESTAMP,
                            "updatedAt": SERVER_TIMESTAMP,
                        })

                        # Fetch income remaining for helpful context
                        try:
                            u_doc = db.collection("users").document(uid).get()
                            income_map = (u_doc.to_dict() or {}).get("income", {})
                            total_income = sum(float(income_map.get(k, 0) or 0) for k in ("inHand", "inBank", "onlineBanking"))
                            all_bud = list(db.collection("users").document(uid).collection("budgets").where("monthKey", "==", month_key).stream())
                            total_alloc = sum(float((b.to_dict() or {}).get("limit", 0) or 0) for b in all_bud)
                            remaining_income = max(0.0, total_income - total_alloc)
                        except Exception:
                            total_income = 0.0
                            remaining_income = 0.0

                        if total_income > 0:
                            no_bud_reply = (
                                f"{category_val} ko budget set gareko chaina yo mahina. "
                                f"Rs {int(remaining_income)} income remaining cha. "
                                f"Kati budget set garnu huncha {category_val} ko lagi? "
                                f"(e.g. '{category_val} budget 5000 set gara')\n"
                                f"Budget set garepaxi Rs {amt_val} {category_val} ma track gardinchu."
                            )
                        else:
                            no_bud_reply = (
                                f"{category_val} ko budget set gareko chaina. "
                                f"Pahile '{category_val} budget 5000 set gara' likh, "
                                f"ani Rs {amt_val} {category_val} ma track gardinchu."
                            )

                        # Store pendingAction with waitingForBudget flag
                        pending_ref_nb = db.collection("users").document(uid).collection("pendingAction").document("current")
                        pending_ref_nb.set({
                            "actions": [{"intent": "expense_log", "amount": float(action["amount"]), "category": category_val, "type": "expense"}],
                            "pendingTxIds": [p_tx_ref.id],
                            "source": source,
                            "monthKey": month_key,
                            "waitingForBudget": True,
                            "waitingCategory": category_val,
                            "createdAt": SERVER_TIMESTAMP,
                        })

                        # Save assistant message
                        assistant_msg_ref = messages_ref.document()
                        assistant_msg_ref.set({
                            "role": "model",
                            "parts": [{"text": no_bud_reply}],
                            "content": no_bud_reply,
                            "intent": "need_budget_before_expense",
                            "extractedData": [{"intent": "expense_log", "amount": float(action["amount"]), "category": category_val}],
                            "relatedTransactionId": p_tx_ref.id,
                            "status": "delivered",
                            "createdAt": SERVER_TIMESTAMP,
                        })
                        try:
                            user_msg_ref.update({"status": "delivered"})
                        except Exception:
                            pass

                        print(f"[CHAT] No budget for {category_val} — going pending. tx={p_tx_ref.id}")
                        return {
                            "success": True,
                            "data": {
                                "reply": no_bud_reply,
                                "intent": "need_budget_before_expense",
                                "needsConfirmation": True,
                                "transaction": None,
                                "budgetUpdate": None,
                                "alerts": [],
                            },
                        }

                # Budget exists (or it's income_log) → immediate log
                txn, bud, alt, rp = _handle_expense_or_income(
                    db, uid, action, source, month_key, idempotency_key
                )
                last_transaction = txn
                if bud: last_budget_update = bud
                if alt: alerts_created.append(alt)
                reply_parts.append(rp)
            else:
                # AMBIGUOUS -> PENDING (Confirmation/Category ask needed)
                pending_actions.append(action)
                # Build partial reply for verification question later
                amt_val = int(float(action["amount"]))
                reply_parts.append(f"Rs {amt_val}")

        # ── SET NOTIFICATION CATEGORY ────────────────────────────────────
        elif intent == "set_notification_category" and action.get("category"):
            chosen_cat = action["category"]
            print(f"[CHAT] set_notification_category: {chosen_cat}")

            # Find most recent pending notification transaction with null category
            tx_col = db.collection("users").document(uid).collection("transactions")
            candidates = list(
                tx_col
                .where("source", "==", "notification")
                .where("status", "==", "pending")
                .order_by("createdAt", direction="DESCENDING")
                .limit(5)
                .stream()
            )

            target = None
            for doc in candidates:
                d = doc.to_dict()
                cat = d.get("category")
                if cat is None or cat in ("Other", "Unknown", ""):
                    target = doc
                    break

            if target:
                td = target.to_dict()
                t_amt = td.get("amount", 0)

                # Update transaction category
                target.reference.update({
                    "category": chosen_cat,
                    "updatedAt": SERVER_TIMESTAMP,
                })

                # Also update matching notification doc
                notif_docs = list(
                    db.collection("users").document(uid)
                    .collection("notifications")
                    .where("transactionId", "==", target.id)
                    .limit(1)
                    .stream()
                )
                for nd in notif_docs:
                    nd.reference.update({"parsedCategory": chosen_cat})

                reply_parts.append(
                    f"Thik cha, Rs {int(t_amt)} {chosen_cat} ma rakheko chu ✅"
                )
                last_transaction = {
                    "id": target.id,
                    "amount": t_amt,
                    "category": chosen_cat,
                    "type": td.get("type", "expense"),
                    "status": "pending",
                    "source": "notification",
                }
                print(
                    f"[CHAT] Updated pending tx {target.id} category → {chosen_cat}"
                )
            else:
                reply_parts.append(
                    f"Category set garna pending notification transaction bhetiyena."
                )
                print("[CHAT] No pending notification tx with null category found")

        # ── SET BUDGET ───────────────────────────────────────────────────
        elif intent == "set_budget" and action.get("limit") is not None and action.get("category"):
            bud, alt, rp = _handle_set_budget(db, uid, action, month_key)
            last_budget_update = bud
            if alt:
                alerts_created.append(alt)
            reply_parts.append(rp)

        # ── QUERY MONTH TOTAL ────────────────────────────────────────────
        elif intent == "query_month_total":
            total = sum_month_expense(db, uid, month_key)
            reply_parts.append(f"Yo mahina Rs {int(total)} kharcha vayo")
            print(f"[CHAT] query_month_total: Rs {total}")

        # ── QUERY REPORT (daily / weekly / monthly) ──────────────────────
        elif intent == "query_report":
            report_period = (action.get("reportPeriod") or "monthly").strip().lower()
            print(f"[CHAT] query_report: period={report_period}")

            # Fetch all confirmed, non-deleted transactions for this month
            tx_docs = list(
                db.collection("users").document(uid).collection("transactions")
                .where("monthKey", "==", month_key)
                .where("status", "==", "confirmed")
                .stream()
            )

            r_expense = 0.0
            r_income = 0.0
            r_categories = {}

            if report_period == "daily":
                day_start, day_end = get_today_date_range()
                for doc in tx_docs:
                    data = doc.to_dict()
                    if data.get("isDeleted", False):
                        continue
                    created_at = data.get("createdAt")
                    if not is_today(created_at):
                        continue
                    amount = data.get("amount", 0.0)
                    tx_type = data.get("type", "")
                    category = data.get("category")
                    if tx_type == "expense":
                        r_expense += amount
                        if category:
                            r_categories[category] = r_categories.get(category, 0.0) + amount
                    elif tx_type == "income":
                        r_income += amount

                # Build reply
                cat_parts = ", ".join(f"{c}: Rs {int(v)}" for c, v in sorted(r_categories.items(), key=lambda x: -x[1]))
                if r_expense > 0 and cat_parts:
                    reply_parts.append(
                        f"Aaja ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. {cat_parts}"
                    )
                elif r_expense > 0:
                    reply_parts.append(
                        f"Aaja ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income"
                    )
                else:
                    reply_parts.append("Aaja kei kharcha bhayena")

            elif report_period == "weekly":
                week_start, week_end = get_week_date_range()
                for doc in tx_docs:
                    data = doc.to_dict()
                    if data.get("isDeleted", False):
                        continue
                    created_at = data.get("createdAt")
                    # Filter to last 7 days
                    if created_at:
                        try:
                            ts = created_at if (hasattr(created_at, 'tzinfo') and created_at.tzinfo) else created_at.replace(tzinfo=__import__('datetime').timezone.utc)
                            if ts < week_start:
                                continue
                        except Exception:
                            pass  # include if we can't determine date
                    else:
                        continue
                    amount = data.get("amount", 0.0)
                    tx_type = data.get("type", "")
                    category = data.get("category")
                    if tx_type == "expense":
                        r_expense += amount
                        if category:
                            r_categories[category] = r_categories.get(category, 0.0) + amount
                    elif tx_type == "income":
                        r_income += amount

                # Build reply
                cat_parts = ", ".join(f"{c}: Rs {int(v)}" for c, v in sorted(r_categories.items(), key=lambda x: -x[1]))
                if r_expense > 0 and cat_parts:
                    reply_parts.append(
                        f"Yo hapta ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. {cat_parts}"
                    )
                elif r_expense > 0:
                    reply_parts.append(
                        f"Yo hapta ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income"
                    )
                else:
                    reply_parts.append("Yo hapta ma kei kharcha bhayena")

            else:
                # monthly (default)
                for doc in tx_docs:
                    data = doc.to_dict()
                    if data.get("isDeleted", False):
                        continue
                    amount = data.get("amount", 0.0)
                    tx_type = data.get("type", "")
                    category = data.get("category")
                    if tx_type == "expense":
                        r_expense += amount
                        if category:
                            r_categories[category] = r_categories.get(category, 0.0) + amount
                    elif tx_type == "income":
                        r_income += amount

                savings = r_income - r_expense
                cat_breakdown = "\n".join(f"{c}: Rs {int(v)}" for c, v in sorted(r_categories.items(), key=lambda x: -x[1]))
                
                reply = (
                    f"Yo mahina:\n\n"
                    f"Total Expense: Rs {int(r_expense)}\n"
                    f"Total Income: Rs {int(r_income)}\n"
                    f"Savings: Rs {int(savings)}\n\n"
                    f"{cat_breakdown}"
                )
                reply_parts.append(reply.strip())

            print(f"[CHAT] query_report result: expense={r_expense} income={r_income} cats={list(r_categories.keys())}")

        # ── QUERY CATEGORY SPEND ─────────────────────────────────────────
        elif intent == "query_category_spend" and action.get("category"):
            cat = action["category"]
            total = sum_category_expense(db, uid, cat, month_key)
            reply_parts.append(f"{cat} ma Rs {int(total)} kharcha gareko chau yo mahina")
            print(f"[CHAT] query_category_spend: {cat} -> Rs {total}")

        # ── QUERY BUDGET STATUS ──────────────────────────────────────────
        elif intent == "query_budget_status" and action.get("category"):
            cat = action["category"]
            b = fetch_budget(db, uid, cat, month_key)
            if b:
                bl = b.get("limit", 0)
                bs = b.get("spent", 0)
                br = max(0, bl - bs)
                bp = round((bs / bl * 100), 1) if bl > 0 else 0
                reply_parts.append(f"{cat} budget Rs {int(bl)}, spent Rs {int(bs)}, baki Rs {int(br)} ({bp}%)")
            else:
                reply_parts.append(f"{cat} ko lagi budget set gareko chaina yo mahina")
            print(f"[CHAT] query_budget_status: {cat}")

        # ── QUERY PAST REPORT ─────────────────────────────────────────────
        elif intent == "query_past_report":
            mk = month_key  # already resolved via resolve_month_key above
            print(f"[CHAT] query_past_report: monthKey={mk} category={action.get('category')}")

            # Fetch all confirmed, non-deleted transactions for that month
            past_tx_docs = list(
                db.collection("users").document(uid).collection("transactions")
                .where("monthKey", "==", mk)
                .where("status", "==", "confirmed")
                .stream()
            )
            r_expense = 0.0
            r_income = 0.0
            r_categories = {}
            for doc in past_tx_docs:
                data = doc.to_dict()
                if data.get("isDeleted", False):
                    continue
                amt = data.get("amount", 0.0)
                tx_t = data.get("type", "")
                cat = data.get("category")
                if tx_t == "expense":
                    r_expense += amt
                    if cat:
                        r_categories[cat] = r_categories.get(cat, 0.0) + amt
                elif tx_t == "income":
                    r_income += amt

            target_cat = action.get("category")
            if target_cat:
                cat_total = r_categories.get(target_cat, 0.0)
                reply_parts.append(
                    f"{mk} ma {target_cat} ma Rs {int(cat_total)} kharcha gareko thiyo"
                )
            else:
                net = r_income - r_expense
                cat_parts = ", ".join(
                    f"{c}: Rs {int(v)}"
                    for c, v in sorted(r_categories.items(), key=lambda x: -x[1])
                )
                base = (f"{mk} ko report: Rs {int(r_expense)} kharcha, "
                        f"Rs {int(r_income)} income. Net savings: Rs {int(net)}")
                if cat_parts:
                    reply_parts.append(f"{base}. {cat_parts}")
                else:
                    reply_parts.append(base)

            print(f"[CHAT] query_past_report result: expense={r_expense} income={r_income} cats={list(r_categories.keys())}")

        # ── UNDO LAST EXPENSE ────────────────────────────────────────────
        elif intent == "undo_last_expense":
            cat_filter = action.get("category")
            print(f"[CHAT] Undo last expense, category filter={cat_filter}")

            tx_col = db.collection("users").document(uid).collection("transactions")
            q = (
                tx_col
                .where("type", "==", "expense")
                .where("status", "==", "confirmed")
                .where("isDeleted", "==", False)
                .order_by("createdAt", direction="DESCENDING")
                .limit(5)
            )
            candidates = list(q.stream())

            target = None
            for doc in candidates:
                d = doc.to_dict()
                if cat_filter and d.get("category") != cat_filter:
                    continue
                target = doc
                break

            if target:
                td = target.to_dict()
                t_amt = td.get("amount", 0)
                t_cat = td.get("category", "Unknown")

                target.reference.update({
                    "isDeleted": True,
                    "deletedAt": SERVER_TIMESTAMP,
                    "updatedAt": SERVER_TIMESTAMP,
                })
                print(f"[CHAT] [UNDO] Soft-deleted tx={target.id} Rs {t_amt} {t_cat}")

                # Decrement budget
                if t_cat:
                    t_mk = td.get("monthKey", month_key)
                    bud_docs = list(
                        db.collection("users").document(uid).collection("budgets")
                        .where("category", "==", t_cat)
                        .where("monthKey", "==", t_mk)
                        .limit(1)
                        .stream()
                    )
                    if bud_docs:
                        bud_docs[0].reference.update({
                            "spent": Increment(-float(t_amt)),
                            "updatedAt": SERVER_TIMESTAMP,
                        })
                        print(f"[CHAT] [UNDO] Budget decremented: {t_cat}")

                reply_parts.append(f"Rs {int(t_amt)} {t_cat} expense undo gareko chu")
                last_transaction = {
                    "id": target.id, "amount": t_amt, "category": t_cat,
                    "type": "expense", "status": "confirmed", "isDeleted": True,
                }
            else:
                reply_parts.append("Kei expense fela parena undo garna lai")
                print("[CHAT] [UNDO] No matching expense")

        # ── QUERY TOP SPENDING CATEGORY ──────────────────────────────────
        elif intent == "query_top_spend_category":
            top = get_top_spending_category(db, uid, month_key)
            if top:
                reply_parts.append(
                    f"Yo mahina sabai bhanda dherai kharcha {top['category']} ma (Rs {int(top['amount'])}) bhayeko cha."
                )
            else:
                reply_parts.append("Yo mahina kei kharcha bhetiyena.")
            print(f"[CHAT] query_top_spend_category: {top}")

        # ── QUERY SPEND FEEDBACK / SUGGESTIONS ───────────────────────────
        elif intent == "query_spend_feedback":
            alerts = get_spend_alerts(db, uid, month_key)
            top_cat = alerts.get("highestCategory")
            over_cats = alerts.get("overBudgetCategories", [])
            
            if not top_cat:
                reply_parts.append("Hajur ko spending data bhetiyena, kehi kharcha track garnuhos ani ma suggestion dinchu.")
            else:
                feedback = [f"Yo mahina sabai bhanda dherai kharcha {top_cat} ma bhayeko cha."]
                if over_cats:
                    over_list = ", ".join([c["category"] for c in over_cats])
                    feedback.append(f"Hajur le {over_list} ma budget bhanda dherai kharcha garnubhako cha.")
                    feedback.append("Budget control garna ali dhyan dinu hola.")
                else:
                    feedback.append("Sabai category budget bitrai chan, ramro gardai hunuhuncha!")
                reply_parts.append(" ".join(feedback))
            print(f"[CHAT] query_spend_feedback: {alerts}")

        # ── GENERAL CHAT / GREETING ──────────────────────────────────────
        else:
            print(f"[CHAT] General/greeting — no DB writes")

    # ── After action loop: confirm any pending expense waiting for budget ──
    # If user just set a budget for a category that had a pending expense,
    # auto-confirm that expense now.
    set_budget_categories = [
        a.get("category") for a in actions
        if a.get("intent") == "set_budget" and a.get("category")
    ]
    if set_budget_categories:
        try:
            wb_doc = db.collection("users").document(uid).collection("pendingAction").document("current").get()
            if wb_doc.exists:
                wb = wb_doc.to_dict()
                if wb.get("waitingForBudget") and wb.get("waitingCategory") in set_budget_categories:
                    waiting_cat = wb["waitingCategory"]
                    wb_month_key = wb.get("monthKey", get_current_month_key())
                    wb_tx_ids = wb.get("pendingTxIds", [])
                    confirmed_labels = []
                    for tx_id in wb_tx_ids:
                        try:
                            tx_ref_wb = db.collection("users").document(uid).collection("transactions").document(tx_id)
                            tx_doc_wb = tx_ref_wb.get()
                            if tx_doc_wb.exists and tx_doc_wb.to_dict().get("status") == "pending":
                                tx_d = tx_doc_wb.to_dict()
                                exp_amt = float(tx_d.get("amount", 0))
                                exp_cat = tx_d.get("category", waiting_cat)
                                exp_desc = tx_d.get("description", "")

                                tx_ref_wb.update({"status": "confirmed", "updatedAt": SERVER_TIMESTAMP})

                                # Increment budget spent
                                bud_wb = list(
                                    db.collection("users").document(uid).collection("budgets")
                                    .where("category", "==", exp_cat)
                                    .where("monthKey", "==", wb_month_key)
                                    .limit(1).stream()
                                )
                                if bud_wb:
                                    bud_wb[0].reference.update({"spent": Increment(exp_amt), "updatedAt": SERVER_TIMESTAMP})
                                    upd_bud = bud_wb[0].reference.get().to_dict()
                                    new_s = upd_bud.get("spent", 0)
                                    blim = upd_bud.get("limit", 0)
                                    pct_wb = round((new_s / blim * 100), 2) if blim > 0 else 0
                                    last_budget_update = {
                                        "id": bud_wb[0].id, "category": exp_cat,
                                        "limit": blim, "spent": new_s,
                                        "remaining": max(0, blim - new_s),
                                        "percentUsed": pct_wb, "monthKey": wb_month_key,
                                    }

                                # Alert
                                try:
                                    a_desc = exp_desc.strip() if exp_desc else ""
                                    if a_desc and a_desc.lower() not in (exp_cat.lower(), ""):
                                        a_msg = f"Rs {int(exp_amt)} {a_desc} ({exp_cat}) saved."
                                    else:
                                        a_msg = f"Rs {int(exp_amt)} {exp_cat} expense saved."
                                    a_ref = db.collection("users").document(uid).collection("alerts").document()
                                    a_ref.set({
                                        "type": "expense", "message": a_msg, "category": exp_cat,
                                        "severity": "low", "isRead": False, "isDeleted": False,
                                        "monthKey": wb_month_key, "relatedTransactionId": tx_id,
                                        "createdAt": SERVER_TIMESTAMP,
                                    })
                                    alerts_created.append({
                                        "id": a_ref.id, "type": "expense", "message": a_msg,
                                        "category": exp_cat, "severity": "low",
                                        "isRead": False, "monthKey": wb_month_key,
                                        "relatedTransactionId": tx_id,
                                    })
                                except Exception:
                                    pass

                                if a_desc and a_desc.lower() not in (exp_cat.lower(), ""):
                                    confirmed_labels.append(f"Rs {int(exp_amt)} {a_desc} ({exp_cat})")
                                else:
                                    confirmed_labels.append(f"Rs {int(exp_amt)} {exp_cat}")
                                last_transaction = {
                                    "id": tx_id, "amount": exp_amt, "category": exp_cat,
                                    "type": "expense", "status": "confirmed", "monthKey": wb_month_key,
                                }
                        except Exception as ce:
                            print(f"[CHAT][WAIT-BUDGET] confirm tx {tx_id} failed: {ce}")

                    db.collection("users").document(uid).collection("pendingAction").document("current").delete()
                    if confirmed_labels:
                        reply_parts.append("ra " + ", ".join(confirmed_labels) + " pani track gareko chu")
                    primary_intent = "expense_log"  # trigger frontend categories refresh
                    print(f"[CHAT][WAIT-BUDGET] Auto-confirmed {len(confirmed_labels)} expense(s) after budget set.")
        except Exception as wb_err:
            print(f"[CHAT][WAIT-BUDGET] Check failed (non-critical): {wb_err}")

    # ── Conversational Confirmation Holding ──────────────────────────────
    if pending_actions:
        # ── Save each pending action as a PENDING transaction in Firestore ──
        # Status = pending so they are excluded from all budget/report calculations
        # until the user confirms via the chat or the /confirm-transactions endpoint.
        pending_tx_ids = []
        for a in pending_actions:
            p_tx_ref = (
                db.collection("users").document(uid)
                .collection("transactions").document()
            )
            p_tx_data = {
                "amount":            float(a["amount"]),
                "category":          a.get("category"),
                "type":              a.get("type", "expense"),
                "status":            "pending",
                "source":            source,
                "description":       a.get("description", user_message),
                "monthKey":          resolve_month_key(a.get("monthKey")) if a.get("monthKey") else get_current_month_key(),
                "isDeleted":         False,
                "deletedAt":         None,
                "originalMessageId": None,
                "createdAt":         SERVER_TIMESTAMP,
                "updatedAt":         SERVER_TIMESTAMP,
            }
            if idempotency_key:
                p_tx_data["idempotencyKey"] = idempotency_key
            p_tx_ref.set(p_tx_data)
            pending_tx_ids.append(p_tx_ref.id)
            print(f"[CHAT] Pending transaction saved: id={p_tx_ref.id} Rs {a['amount']} {a.get('category')}")

        # Store the pending action doc (for conversational yes/no resolution)
        # Now also store the transaction IDs so the confirm path can look them up.
        pending_ref = db.collection("users").document(uid).collection("pendingAction").document("current")
        pending_ref.set({
            "actions": pending_actions,
            "pendingTxIds": pending_tx_ids,
            "source": source,
            "monthKey": month_key,
            "idempotencyKey": idempotency_key,
            "createdAt": SERVER_TIMESTAMP,
        })
        
        # Build bilingual question: e.g. "Rs 250 Food ma?" or "Rs 250 Food ma ra Rs 20 Transport ma?"
        question_parts = []
        pending_transactions_out = []
        for a, tx_id in zip(pending_actions, pending_tx_ids):
            amt = int(float(a["amount"]))
            cat = a.get("category") or "Income"
            
            # Find a nice short label from user message
            label = cat
            words = [w.strip("?.!,") for w in user_message.lower().split()]
            for word in words:
                # Ignore numbers, amount itself, common verbs and prepositions
                if (word not in ("spent", "khaye", "gayo", "diye", "aayo", "on", "in", "for", "yo", "ma", "ra", "le", "ko", "bata", "maile", "spent", "paid")
                    and not word.isdigit()
                    and len(word) >= 3):
                    label = word
                    break
                    
            if a.get("intent") == "expense_log":
                question_parts.append(f"{amt} {label} ma")
            else:
                question_parts.append(f"{amt} {label}")

            # Structured pending transaction info for frontend
            pending_transactions_out.append({
                "id":       tx_id,
                "amount":   float(a["amount"]),
                "label":    label,
                "category": a.get("category"),
                "status":   "pending",
            })
                
        question = " ra ".join(question_parts) + "?"
        
        # If there are other non-expense actions in the same message, we append their replies before the question
        other_reply_parts = []
        for a, rp in zip(actions, reply_parts):
            if a.get("intent") not in ("expense_log", "income_log"):
                other_reply_parts.append(rp)
                
        final_reply = question
        if other_reply_parts:
            final_reply = ". ".join(other_reply_parts) + ". " + question
            
        # Save assistant message
        assistant_msg_ref = messages_ref.document()
        assistant_msg_ref.set({
            "role": "model",
            "parts": [{"text": final_reply}],
            "content": final_reply,
            "intent": "confirm_expense_ask",
            "extractedData": [
                {k: a.get(k) for k in ("intent", "amount", "category", "type", "limit", "monthKey")}
                for a in pending_actions
            ],
            "relatedTransactionId": None,
            "status": "delivered",
            "createdAt": SERVER_TIMESTAMP,
        })
        # Mark user message as delivered
        try:
            user_msg_ref.update({"status": "delivered"})
        except Exception:
            pass
        
        print(f"[CHAT] Stored pendingAction with {len(pending_tx_ids)} pending txs. Question: {final_reply}")
        
        return {
            "success": True,
            "data": {
                "reply": final_reply,
                "intent": "confirm_expense_ask",
                "needsConfirmation": True,
                # pendingTransactions gives frontend the IDs to confirm/cancel via API
                "pendingTransactions": pending_transactions_out,
                "transaction": None,
                "budgetUpdate": None,
                "alerts": [],
            },
        }

    # ── Build final reply ────────────────────────────────────────────────
    if reply_parts:
        # Synthesize a combined reply from the action parts
        has_expense = any(a.get("intent") in ("expense_log", "income_log") for a in actions)
        has_budget = any(a.get("intent") == "set_budget" for a in actions)

        if has_expense and has_budget:
            # Mix of expenses + budget sets
            expense_parts = []
            budget_parts = []
            for a, rp in zip(actions, reply_parts):
                if a.get("intent") in ("expense_log", "income_log"):
                    expense_parts.append(rp)
                elif a.get("intent") == "set_budget":
                    budget_parts.append(rp)

            pieces = []
            if expense_parts:
                pieces.append(", ".join(expense_parts) + " ma save gareko chu")
            if budget_parts:
                pieces.append(" ra ".join(budget_parts) + " gareko chu")

            reply = " ra ".join(pieces) + " ✅"

        elif has_expense:
            if len(reply_parts) > 1:
                reply = ", ".join(reply_parts) + " ma save gareko chu ✅"
            else:
                reply = reply_parts[0] + " ma save gareko chu ✅"

        elif has_budget:
            reply = " ra ".join(reply_parts) + " gareko chu ✅"

        else:
            # Queries / undo / etc.
            reply = ". ".join(reply_parts) + "."
    else:
        # Pure general chat — use Gemini's natural reply
        reply = gemini_reply

    # ── Save assistant message ───────────────────────────────────────────
    assistant_msg_ref = messages_ref.document()
    extracted = None
    if primary_intent not in ("general_chat", "greeting"):
        extracted = [
            {k: a.get(k) for k in ("intent", "amount", "category", "type", "limit", "monthKey")}
            for a in actions
        ]

    assistant_msg_ref.set({
        "role": "model",
        "parts": [{"text": reply}],
        "content": reply,
        "intent": primary_intent,
        "extractedData": extracted,
        "relatedTransactionId": last_transaction["id"] if last_transaction else None,
        "status": "delivered",
        "createdAt": SERVER_TIMESTAMP,
    })
    # Mark user message as delivered now that bot has replied successfully
    try:
        user_msg_ref.update({"status": "delivered"})
    except Exception:
        pass

    print(
        f"[CHAT] DONE: actions={[a.get('intent') for a in actions]}, "
        f"tx={'YES ' + last_transaction['id'] if last_transaction else 'NO'}, "
        f"budget={'YES' if last_budget_update else 'NO'}, "
        f"alerts={len(alerts_created)}"
    )
    print(f"{'='*60}\n")

    return {
        "success": True,
        "data": {
            "reply": reply,
            "intent": primary_intent,
            "needsConfirmation": False,
            "transaction": last_transaction,
            "budgetUpdate": last_budget_update,
            "alerts": alerts_created,
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# POST /chat/sync  — process batched offline messages
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/chat/sync")
async def chat_sync(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """
    Process a batch of messages that were queued while the user was offline.
    Messages are sorted by clientTimestamp and processed sequentially through
    the same pipeline as POST /chat.

    Request body:
    {
        "messages": [
            {"message": "...", "source": "chat", "clientTimestamp": "ISO-8601"},
            ...
        ]
    }
    """
    uid = current_user["uid"]
    db = get_firestore()

    body = await request.json()
    queued_messages = body.get("messages", [])

    if not queued_messages or not isinstance(queued_messages, list):
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {"code": "EMPTY_BATCH", "message": "No messages provided."},
            },
        )

    # ── Enforce batch limit ──────────────────────────────────────────────
    MAX_BATCH = 20
    if len(queued_messages) > MAX_BATCH:
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "BATCH_TOO_LARGE",
                    "message": f"Maximum {MAX_BATCH} messages per sync call.",
                },
            },
        )

    print(f"\n{'='*60}")
    print(f"[SYNC] uid={uid}  batch_size={len(queued_messages)}")
    print(f"{'='*60}")

    # ── Sort by clientTimestamp (chronological order) ─────────────────────
    from datetime import datetime as _dt, timezone as _tz

    def _parse_ts(msg):
        ts_str = msg.get("clientTimestamp", "")
        if not ts_str:
            return _dt.min.replace(tzinfo=_tz.utc)
        try:
            ts = _dt.fromisoformat(ts_str.replace("Z", "+00:00"))
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=_tz.utc)
            return ts
        except Exception:
            return _dt.min.replace(tzinfo=_tz.utc)

    queued_messages.sort(key=_parse_ts)

    messages_ref = db.collection("users").document(uid).collection("messages")

    results = []
    total_processed = 0
    total_skipped = 0

    # ── Process each message sequentially ─────────────────────────────────
    for idx, msg_payload in enumerate(queued_messages):
        user_message = (msg_payload.get("message") or "").strip()
        source = msg_payload.get("source", "chat")
        client_ts_str = msg_payload.get("clientTimestamp", "")
        sync_idempotency_key = msg_payload.get("idempotencyKey") or None

        if not user_message:
            results.append({
                "clientTimestamp": client_ts_str,
                "status": "skipped",
                "reason": "empty_message",
                "reply": None,
                "intent": None,
                "transaction": None,
                "budgetUpdate": None,
                "alerts": [],
            })
            total_skipped += 1
            continue

        # Skip notification-sourced messages (notifications are real-time only)
        if source == "notification":
            results.append({
                "clientTimestamp": client_ts_str,
                "status": "skipped",
                "reason": "notification_not_supported_in_sync",
                "reply": None,
                "intent": None,
                "transaction": None,
                "budgetUpdate": None,
                "alerts": [],
            })
            total_skipped += 1
            continue

        print(f"[SYNC] [{idx+1}/{len(queued_messages)}] message='{user_message}' ts={client_ts_str}")

        # ── Deduplication check ──────────────────────────────────────────
        try:
            if client_ts_str:
                dup_query = list(
                    messages_ref
                    .where("role", "==", "user")
                    .where("content", "==", user_message)
                    .where("clientTimestamp", "==", client_ts_str)
                    .limit(1)
                    .stream()
                )
                if dup_query:
                    print(f"[SYNC] Duplicate detected — skipping")
                    results.append({
                        "clientTimestamp": client_ts_str,
                        "status": "already_processed",
                        "reply": None,
                        "intent": None,
                        "transaction": None,
                        "budgetUpdate": None,
                        "alerts": [],
                    })
                    total_skipped += 1
                    continue
        except Exception as dedup_err:
            # If dedup check fails (e.g. missing index), continue processing
            print(f"[SYNC] Dedup check failed (proceeding): {dedup_err}")

        # ── Derive monthKey from clientTimestamp ──────────────────────────
        parsed_client_ts = _parse_ts(msg_payload)
        if parsed_client_ts.year > 2000:
            derived_month_key = parsed_client_ts.strftime("%Y-%m")
        else:
            derived_month_key = get_current_month_key()

        try:
            # ── Save user message ────────────────────────────────────────
            user_msg_ref = messages_ref.document()
            user_msg_ref.set({
                "role": "user",
                "parts": [{"text": user_message}],
                "content": user_message,
                "intent": None,
                "extractedData": None,
                "relatedTransactionId": None,
                "clientTimestamp": client_ts_str,
                "source": "offline_sync",
                "createdAt": SERVER_TIMESTAMP,
            })

            # ── Call Gemini ──────────────────────────────────────────────
            # Compute missing budget categories for the derived month
            missing_budget_categories = get_missing_budget_categories(db, uid, derived_month_key)

            gemini_result = await process_chat_message(
                user_message,
                missing_budget_categories=missing_budget_categories
            )
            gemini_reply = gemini_result["reply"]
            actions = gemini_result["actions"]

            print(f"[SYNC] actions={[a.get('intent') for a in actions]}")

            # ── Rent keyword fallback (same as POST /chat) ───────────────
            _RENT_KEYWORDS = ["rent", "room rent", "flat rent", "house rent",
                               "bhada", "ghar bhada", "kotha bhada", "kiraya"]
            text_lower = user_message.lower()
            for action in actions:
                act_intent = action.get("intent", "")
                act_cat = action.get("category") or ""
                if act_intent in ("expense_log", "income_log", "set_budget",
                                  "query_category_spend", "query_budget_status"):
                    if act_cat.lower() in ("other", "others", ""):
                        if any(kw in text_lower for kw in _RENT_KEYWORDS):
                            action["category"] = "Rent"

            # ── Accumulators ─────────────────────────────────────────────
            last_transaction = None
            last_budget_update = None
            alerts_created = []
            reply_parts = []
            primary_intent = actions[0].get("intent", "general_chat") if actions else "general_chat"

            # ── Process each action ──────────────────────────────────────
            for action in actions:
                intent = action.get("intent", "general_chat")
                # Use derived monthKey from clientTimestamp, not server time
                raw_mk = action.get("monthKey")
                month_key = resolve_month_key(raw_mk) if raw_mk else derived_month_key

                # ── EXPENSE / INCOME ─────────────────────────────────────
                if intent in ("expense_log", "income_log") and action.get("amount"):
                    amount_val = float(action["amount"])
                    category_val = action.get("category")
                    tx_type_val = action.get("type", "expense")
                    description_val = action.get("description", "")
                    
                    # ── Idempotency check ────────────────────────────────
                    existing_tx = None
                    if sync_idempotency_key:
                        try:
                            existing_docs = list(
                                db.collection("users").document(uid)
                                .collection("transactions")
                                .where("idempotencyKey", "==", sync_idempotency_key)
                                .limit(1)
                                .stream()
                            )
                            if existing_docs:
                                existing_tx = existing_docs[0]
                                print(f"[SYNC] Idempotency hit: key={sync_idempotency_key} tx={existing_tx.id}")
                        except Exception as e:
                            print(f"[SYNC] Idempotency check failed: {e}")
                            
                    if existing_tx:
                        ed = existing_tx.to_dict()
                        last_transaction = {
                            "id": existing_tx.id,
                            "amount": ed.get("amount", amount_val),
                            "category": ed.get("category", category_val),
                            "type": ed.get("type", tx_type_val),
                            "status": ed.get("status", "pending"),
                            "source": ed.get("source", "offline_sync"),
                            "description": ed.get("description", description_val),
                            "monthKey": ed.get("monthKey", month_key),
                            "isDeleted": ed.get("isDeleted", False),
                            "deletedAt": None,
                            "originalMessageId": None,
                            "deduplicated": True,
                        }
                    else:
                        # Create PENDING transaction
                        tx_ref = (
                            db.collection("users").document(uid)
                            .collection("transactions").document()
                        )
                        tx_data = {
                            "amount": amount_val,
                            "category": category_val,
                            "type": tx_type_val,
                            "status": "pending",
                            "source": "offline_sync",
                            "description": description_val,
                            "monthKey": month_key,
                            "isDeleted": False,
                            "deletedAt": None,
                            "originalMessageId": None,
                            "createdAt": SERVER_TIMESTAMP,
                            "updatedAt": SERVER_TIMESTAMP,
                        }
                        if sync_idempotency_key:
                            tx_data["idempotencyKey"] = sync_idempotency_key
                        tx_ref.set(tx_data)
                        
                        last_transaction = {
                            "id": tx_ref.id,
                            "amount": amount_val,
                            "category": category_val,
                            "type": tx_type_val,
                            "status": "pending",
                            "source": "offline_sync",
                            "description": description_val,
                            "monthKey": month_key,
                            "isDeleted": False,
                            "deletedAt": None,
                            "originalMessageId": None,
                        }
                        print(f"[SYNC] Pending transaction created: id={tx_ref.id} Rs {amount_val}")
                        
                    # Build reply part
                    cat_disp = category_val or "Income"
                    reply_parts.append(f"Rs {int(amount_val)} {cat_disp}")

                # ── SET NOTIFICATION CATEGORY ────────────────────────────
                elif intent == "set_notification_category" and action.get("category"):
                    chosen_cat = action["category"]
                    tx_col = db.collection("users").document(uid).collection("transactions")
                    candidates = list(
                        tx_col
                        .where("source", "==", "notification")
                        .where("status", "==", "pending")
                        .order_by("createdAt", direction="DESCENDING")
                        .limit(5)
                        .stream()
                    )
                    target = None
                    for doc in candidates:
                        d = doc.to_dict()
                        cat = d.get("category")
                        if cat is None or cat in ("Other", "Unknown", ""):
                            target = doc
                            break
                    if target:
                        td = target.to_dict()
                        t_amt = td.get("amount", 0)
                        target.reference.update({
                            "category": chosen_cat,
                            "updatedAt": SERVER_TIMESTAMP,
                        })
                        notif_docs = list(
                            db.collection("users").document(uid)
                            .collection("notifications")
                            .where("transactionId", "==", target.id)
                            .limit(1)
                            .stream()
                        )
                        for nd in notif_docs:
                            nd.reference.update({"parsedCategory": chosen_cat})
                        reply_parts.append(
                            f"Thik cha, Rs {int(t_amt)} {chosen_cat} ma rakheko chu ✅"
                        )
                        last_transaction = {
                            "id": target.id, "amount": t_amt,
                            "category": chosen_cat,
                            "type": td.get("type", "expense"),
                            "status": "pending", "source": "notification",
                        }
                    else:
                        reply_parts.append(
                            "Category set garna pending notification transaction bhetiyena."
                        )

                # ── SET BUDGET ───────────────────────────────────────────
                elif intent == "set_budget" and action.get("limit") is not None and action.get("category"):
                    bud, alt, rp = _handle_set_budget(db, uid, action, month_key)
                    last_budget_update = bud
                    if alt:
                        alerts_created.append(alt)
                    reply_parts.append(rp)

                # ── QUERY MONTH TOTAL ────────────────────────────────────
                elif intent == "query_month_total":
                    total = sum_month_expense(db, uid, month_key)
                    reply_parts.append(f"Yo mahina total kharcha Rs {int(total)} cha")

                # ── QUERY REPORT ─────────────────────────────────────────
                elif intent == "query_report":
                    report_period = (action.get("reportPeriod") or "monthly").strip().lower()
                    tx_docs = list(
                        db.collection("users").document(uid).collection("transactions")
                        .where("monthKey", "==", month_key)
                        .where("status", "==", "confirmed")
                        .stream()
                    )
                    r_expense = 0.0
                    r_income = 0.0
                    r_categories = {}

                    if report_period == "daily":
                        for doc in tx_docs:
                            data = doc.to_dict()
                            if data.get("isDeleted", False):
                                continue
                            if not is_today(data.get("createdAt")):
                                continue
                            amount = data.get("amount", 0.0)
                            if data.get("type") == "expense":
                                r_expense += amount
                                cat = data.get("category")
                                if cat:
                                    r_categories[cat] = r_categories.get(cat, 0.0) + amount
                            elif data.get("type") == "income":
                                r_income += amount
                        cat_parts = ", ".join(f"{c}: Rs {int(v)}" for c, v in sorted(r_categories.items(), key=lambda x: -x[1]))
                        if r_expense > 0 and cat_parts:
                            reply_parts.append(f"Aaja ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. {cat_parts}")
                        elif r_expense > 0:
                            reply_parts.append(f"Aaja ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income")
                        else:
                            reply_parts.append("Aaja kei kharcha bhayena")

                    elif report_period == "weekly":
                        week_start, _ = get_week_date_range()
                        for doc in tx_docs:
                            data = doc.to_dict()
                            if data.get("isDeleted", False):
                                continue
                            created_at = data.get("createdAt")
                            if created_at:
                                try:
                                    ts = created_at if (hasattr(created_at, 'tzinfo') and created_at.tzinfo) else created_at.replace(tzinfo=_tz.utc)
                                    if ts < week_start:
                                        continue
                                except Exception:
                                    pass
                            else:
                                continue
                            amount = data.get("amount", 0.0)
                            if data.get("type") == "expense":
                                r_expense += amount
                                cat = data.get("category")
                                if cat:
                                    r_categories[cat] = r_categories.get(cat, 0.0) + amount
                            elif data.get("type") == "income":
                                r_income += amount
                        cat_parts = ", ".join(f"{c}: Rs {int(v)}" for c, v in sorted(r_categories.items(), key=lambda x: -x[1]))
                        if r_expense > 0 and cat_parts:
                            reply_parts.append(f"Yo hapta ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. {cat_parts}")
                        elif r_expense > 0:
                            reply_parts.append(f"Yo hapta ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income")
                        else:
                            reply_parts.append("Yo hapta ma kei kharcha bhayena")

                    else:
                        for doc in tx_docs:
                            data = doc.to_dict()
                            if data.get("isDeleted", False):
                                continue
                            amount = data.get("amount", 0.0)
                            if data.get("type") == "expense":
                                r_expense += amount
                                cat = data.get("category")
                                if cat:
                                    r_categories[cat] = r_categories.get(cat, 0.0) + amount
                            elif data.get("type") == "income":
                                r_income += amount
                        net = r_income - r_expense
                        cat_parts = ", ".join(f"{c}: Rs {int(v)}" for c, v in sorted(r_categories.items(), key=lambda x: -x[1]))
                        if r_expense > 0 and cat_parts:
                            reply_parts.append(f"Yo mahina ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. Net savings: Rs {int(net)}. {cat_parts}")
                        elif r_expense > 0:
                            reply_parts.append(f"Yo mahina ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. Net savings: Rs {int(net)}")
                        else:
                            reply_parts.append("Yo mahina ma kei kharcha bhayena")

                # ── QUERY CATEGORY SPEND ─────────────────────────────────
                elif intent == "query_category_spend" and action.get("category"):
                    cat = action["category"]
                    total = sum_category_expense(db, uid, cat, month_key)
                    reply_parts.append(f"{cat} ma Rs {int(total)} kharcha gareko chau yo mahina")

                # ── QUERY BUDGET STATUS ──────────────────────────────────
                elif intent == "query_budget_status" and action.get("category"):
                    cat = action["category"]
                    b = fetch_budget(db, uid, cat, month_key)
                    if b:
                        bl = b.get("limit", 0)
                        bs = b.get("spent", 0)
                        br = max(0, bl - bs)
                        bp = round((bs / bl * 100), 1) if bl > 0 else 0
                        reply_parts.append(f"{cat} budget Rs {int(bl)}, spent Rs {int(bs)}, baki Rs {int(br)} ({bp}%)")
                    else:
                        reply_parts.append(f"{cat} ko lagi budget set gareko chaina yo mahina")

                # ── QUERY PAST REPORT (sync) ─────────────────────────────
                elif intent == "query_past_report":
                    mk = month_key
                    past_tx_docs = list(
                        db.collection("users").document(uid).collection("transactions")
                        .where("monthKey", "==", mk)
                        .where("status", "==", "confirmed")
                        .stream()
                    )
                    r_expense = 0.0
                    r_income = 0.0
                    r_categories = {}
                    for doc in past_tx_docs:
                        data = doc.to_dict()
                        if data.get("isDeleted", False):
                            continue
                        amt = data.get("amount", 0.0)
                        tx_t = data.get("type", "")
                        cat = data.get("category")
                        if tx_t == "expense":
                            r_expense += amt
                            if cat:
                                r_categories[cat] = r_categories.get(cat, 0.0) + amt
                        elif tx_t == "income":
                            r_income += amt

                    target_cat = action.get("category")
                    if target_cat:
                        cat_total = r_categories.get(target_cat, 0.0)
                        reply_parts.append(
                            f"{mk} ma {target_cat} ma Rs {int(cat_total)} kharcha gareko thiyo"
                        )
                    else:
                        net = r_income - r_expense
                        cat_parts = ", ".join(
                            f"{c}: Rs {int(v)}"
                            for c, v in sorted(r_categories.items(), key=lambda x: -x[1])
                        )
                        base = (f"{mk} ko report: Rs {int(r_expense)} kharcha, "
                                f"Rs {int(r_income)} income. Net savings: Rs {int(net)}")
                        if cat_parts:
                            reply_parts.append(f"{base}. {cat_parts}")
                        else:
                            reply_parts.append(base)

                # ── UNDO LAST EXPENSE ────────────────────────────────────
                elif intent == "undo_last_expense":
                    cat_filter = action.get("category")
                    tx_col = db.collection("users").document(uid).collection("transactions")
                    q = (
                        tx_col
                        .where("type", "==", "expense")
                        .where("status", "==", "confirmed")
                        .where("isDeleted", "==", False)
                        .order_by("createdAt", direction="DESCENDING")
                        .limit(5)
                    )
                    candidates = list(q.stream())
                    target = None
                    for doc in candidates:
                        d = doc.to_dict()
                        if cat_filter and d.get("category") != cat_filter:
                            continue
                        target = doc
                        break
                    if target:
                        td = target.to_dict()
                        t_amt = td.get("amount", 0)
                        t_cat = td.get("category", "Unknown")
                        target.reference.update({
                            "isDeleted": True,
                            "deletedAt": SERVER_TIMESTAMP,
                            "updatedAt": SERVER_TIMESTAMP,
                        })
                        if t_cat:
                            t_mk = td.get("monthKey", month_key)
                            bud_docs = list(
                                db.collection("users").document(uid).collection("budgets")
                                .where("category", "==", t_cat)
                                .where("monthKey", "==", t_mk)
                                .limit(1)
                                .stream()
                            )
                            if bud_docs:
                                bud_docs[0].reference.update({
                                    "spent": Increment(-float(t_amt)),
                                    "updatedAt": SERVER_TIMESTAMP,
                                })
                        reply_parts.append(f"Rs {int(t_amt)} {t_cat} expense undo gareko chu")
                        last_transaction = {
                            "id": target.id, "amount": t_amt, "category": t_cat,
                            "type": "expense", "status": "confirmed", "isDeleted": True,
                        }
                    else:
                        reply_parts.append("Kei expense fela parena undo garna lai")

                # ── QUERY TOP SPENDING CATEGORY (sync) ───────────────────
                elif intent == "query_top_spend_category":
                    top = get_top_spending_category(db, uid, month_key)
                    if top:
                        reply_parts.append(
                            f"Yo mahina sabai bhanda dherai kharcha {top['category']} ma (Rs {int(top['amount'])}) bhayeko cha."
                        )
                    else:
                        reply_parts.append("Yo mahina kei kharcha bhetiyena.")

                # ── QUERY SPEND FEEDBACK / SUGGESTIONS (sync) ────────────
                elif intent == "query_spend_feedback":
                    alerts = get_spend_alerts(db, uid, month_key)
                    top_cat = alerts.get("highestCategory")
                    over_cats = alerts.get("overBudgetCategories", [])
                    if not top_cat:
                        reply_parts.append("Hajur ko spending data bhetiyena.")
                    else:
                        feedback = [f"Yo mahina sabai bhanda dherai kharcha {top_cat} ma bhayeko cha."]
                        if over_cats:
                            over_list = ", ".join([c["category"] for c in over_cats])
                            feedback.append(f"Hajur le {over_list} ma budget bhanda dherai kharcha garnubhako cha.")
                        else:
                            feedback.append("Sabai category budget bitrai chan, ramro gardai hunuhuncha!")
                        reply_parts.append(" ".join(feedback))

                # ── GENERAL CHAT / GREETING ──────────────────────────────
                else:
                    pass

            # ── Build final reply (same logic as POST /chat) ─────────────
            if reply_parts:
                has_expense = any(a.get("intent") in ("expense_log", "income_log") for a in actions)
                has_budget = any(a.get("intent") == "set_budget" for a in actions)

                if has_expense and has_budget:
                    expense_parts = []
                    budget_parts = []
                    for a, rp in zip(actions, reply_parts):
                        if a.get("intent") in ("expense_log", "income_log"):
                            expense_parts.append(rp)
                        elif a.get("intent") == "set_budget":
                            budget_parts.append(rp)
                    pieces = []
                    if expense_parts:
                        pieces.append(", ".join(expense_parts) + " ma save gareko chu")
                    if budget_parts:
                        pieces.append(" ra ".join(budget_parts) + " gareko chu")
                    reply = " ra ".join(pieces) + " ✅"
                elif has_expense:
                    if len(reply_parts) > 1:
                        reply = "Confirm garnuhos: " + ", ".join(reply_parts)
                    else:
                        reply = "Confirm garnuhos: " + reply_parts[0]
                elif has_budget:
                    reply = " ra ".join(reply_parts) + " gareko chu ✅"
                else:
                    reply = ". ".join(reply_parts) + "."
            else:
                reply = gemini_reply

            # ── Save assistant message ───────────────────────────────────
            assistant_msg_ref = messages_ref.document()
            extracted = None
            if primary_intent not in ("general_chat", "greeting"):
                extracted = [
                    {k: a.get(k) for k in ("intent", "amount", "category", "type", "limit", "monthKey")}
                    for a in actions
                ]
            assistant_msg_ref.set({
                "role": "model",
                "parts": [{"text": reply}],
                "content": reply,
                "intent": primary_intent,
                "extractedData": extracted,
                "relatedTransactionId": last_transaction["id"] if last_transaction else None,
                "clientTimestamp": client_ts_str,
                "source": "offline_sync",
                "createdAt": SERVER_TIMESTAMP,
            })

            print(f"[SYNC] [{idx+1}] DONE: intent={primary_intent} reply='{reply[:60]}...'")

            results.append({
                "clientTimestamp": client_ts_str,
                "status": "processed",
                "reply": reply,
                "intent": primary_intent,
                "needsConfirmation": has_expense,
                "transaction": last_transaction,
                "budgetUpdate": last_budget_update,
                "alerts": alerts_created,
            })
            total_processed += 1

        except Exception as e:
            print(f"[SYNC] [{idx+1}] ERROR: {e}")
            results.append({
                "clientTimestamp": client_ts_str,
                "status": "error",
                "reason": str(e),
                "reply": None,
                "intent": None,
                "transaction": None,
                "budgetUpdate": None,
                "alerts": [],
            })
            total_skipped += 1

    print(f"[SYNC] COMPLETE: processed={total_processed} skipped={total_skipped}")
    print(f"{'='*60}\n")

    return {
        "success": True,
        "data": {
            "results": results,
            "totalProcessed": total_processed,
            "totalSkipped": total_skipped,
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# GET /messages
# ═══════════════════════════════════════════════════════════════════════════════

@router.get("/messages")
async def get_messages(
    limit: int = Query(default=50, ge=1, le=200),
    before: Optional[str] = Query(default=None, description="Message doc ID — return messages older than this (cursor pagination)"),
    current_user: dict = Depends(get_current_user),
):
    """
    Return chat message history for the current user, oldest-first.

    - Messages are stored permanently; the backend never wipes them.
    - Call this when the chat screen opens to restore conversation history.
    - Use `before=<messageId>` (the oldest message id you already have) to load
      earlier pages (infinite scroll upward).
    - Response includes `pendingAction` if the bot is waiting for a yes/no answer.
    """
    uid = current_user["uid"]
    db = get_firestore()

    messages_ref = db.collection("users").document(uid).collection("messages")

    query = messages_ref.order_by("createdAt", direction="DESCENDING")

    # Cursor: start after the document the caller already has
    if before:
        try:
            cursor_doc = messages_ref.document(before).get()
            if cursor_doc.exists:
                query = query.start_after(cursor_doc)
        except Exception:
            pass  # bad cursor — return from start

    query = query.limit(limit)
    docs = list(query.stream())

    messages = []
    for doc in docs:
        data = doc.to_dict()
        serialized = serialize_doc(data)
        serialized["id"] = doc.id

        # Normalize legacy role value
        if serialized.get("role") == "assistant":
            serialized["role"] = "model"

        # Back-fill parts from content for old messages
        if not serialized.get("parts") and serialized.get("content"):
            serialized["parts"] = [{"text": serialized["content"]}]

        messages.append(serialized)

    # Return in chronological order (oldest first) for display
    messages.reverse()

    has_more = len(docs) == limit
    # oldest doc in the DESCENDING result is the last element before reversing
    next_cursor = docs[-1].id if has_more else None

    # Include any active pendingAction so the frontend can restore its UI
    pending_action = None
    try:
        pending_doc = (
            db.collection("users").document(uid)
            .collection("pendingAction").document("current")
            .get()
        )
        if pending_doc.exists:
            pa = pending_doc.to_dict()
            pending_action = {
                "actions": pa.get("actions", []),
                "pendingTxIds": pa.get("pendingTxIds", []),
                "source": pa.get("source", "chat"),
                "monthKey": pa.get("monthKey"),
            }
    except Exception:
        pass

    return {
        "success": True,
        "data": {
            "messages": messages,
            "hasMore": has_more,
            "nextCursor": next_cursor,
            "pendingAction": pending_action,
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# DELETE /messages/{id}
# ═══════════════════════════════════════════════════════════════════════════════

@router.delete("/messages/{message_id}")
async def delete_message(
    message_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Delete a message from chat history."""
    uid = current_user["uid"]
    db = get_firestore()

    msg_ref = (
        db.collection("users").document(uid)
        .collection("messages").document(message_id)
    )
    doc = msg_ref.get()
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {"code": "MESSAGE_NOT_FOUND", "message": "Message not found"},
            },
        )

    msg_ref.delete()
    return {"success": True, "message": "Message deleted"}