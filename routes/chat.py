from fastapi import APIRouter, Depends, HTTPException, Request, Query
from firebase_config import get_firestore
from auth import get_current_user
from gemini import process_chat_message, parse_notification_text
from schemas.categories import EXPENSE_CATEGORIES
from utils import (
    get_current_month_key, serialize_doc,
    sum_month_expense, sum_category_expense, fetch_budget,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment
from typing import Optional

router = APIRouter()


# ═══════════════════════════════════════════════════════════════════════════════
# Helpers — one function per action type
# ═══════════════════════════════════════════════════════════════════════════════

def _handle_expense_or_income(db, uid, action, source, month_key):
    """
    Save transaction, increment budget.spent (if expense + budget exists),
    create a transaction_saved alert.
    Returns (transaction_dict, budget_update_or_None, alert_or_None, reply_part).
    """
    amount = float(action["amount"])
    category = action.get("category")
    tx_type = action.get("type", "expense")
    description = action.get("description", "")

    # ── Save transaction ─────────────────────────────────────────────────
    tx_ref = (
        db.collection("users").document(uid)
        .collection("transactions").document()
    )
    tx_ref.set({
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
    })
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
        else:
            print(f"[CHAT] [BUDGET] No budget for '{category}' in {month_key}")

    # ── Alert ────────────────────────────────────────────────────────────
    alert_out = None
    try:
        label = "expense" if tx_type == "expense" else "income"
        cat_label = f"{category} " if category else ""
        msg = f"Rs {int(amount)} {cat_label}{label} saved."
        if tx_type == "expense" and budget_update and percent_used >= 80:
            msg = f"{category} Rs {int(amount)} saved, {int(percent_used)}% budget used!"

        aref = db.collection("users").document(uid).collection("alerts").document()
        aref.set({
            "type": "transaction_saved",
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
            "id": aref.id, "type": "transaction_saved",
            "message": msg, "category": category,
            "severity": "medium" if percent_used >= 80 else "low",
            "isRead": False, "monthKey": month_key,
            "relatedTransactionId": tx_ref.id,
        }
        print(f"[CHAT] [ALERT] {aref.id}: '{msg}'")
    except Exception as e:
        print(f"[CHAT] [ALERT] FAILED: {e}")

    # Reply part
    cat_display = category or "Income"
    reply_part = f"Rs {int(amount)} {cat_display}"

    return transaction_out, budget_update, alert_out, reply_part


def _handle_set_budget(db, uid, action, month_key):
    """
    Upsert budget: overwrite limit, keep spent.
    Returns (budget_update_dict, alert_or_None, reply_part).
    """
    category = action.get("category")
    limit_val = float(action["limit"])

    print(f"[CHAT] Setting budget: {category} limit=Rs {limit_val} monthKey={month_key}")

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
async def chat(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    body = await request.json()
    user_message = body.get("message", "").strip()
    source = body.get("source", "chat")

    print(f"\n{'='*60}")
    print(f"[CHAT] uid={uid} message='{user_message}'")
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
        "content": user_message,
        "intent": None,
        "extractedData": None,
        "relatedTransactionId": None,
        "createdAt": SERVER_TIMESTAMP,
    })

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

        # B. Create PENDING transaction
        tx_ref = (
            db.collection("users").document(uid)
            .collection("transactions").document()
        )
        tx_data = {
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
            "createdAt":         SERVER_TIMESTAMP,
            "updatedAt":         SERVER_TIMESTAMP,
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
        }

        # C. Create notification doc
        notif_ref = (
            db.collection("users").document(uid)
            .collection("notifications").document()
        )
        notif_data = {
            "rawText":        user_message,
            "parsedAmount":   float(amount),
            "parsedCategory": category if not category_uncertain else None,
            "parsedType":     tx_type,
            "sourceApp":      source_app,
            "status":         "pending",
            "transactionId":  tx_ref.id,
            "createdAt":      SERVER_TIMESTAMP,
        }
        notif_ref.set(notif_data)
        print(f"[CHAT][NOTIF] Notification doc created: id={notif_ref.id}")

        notification_out = {
            "id":             notif_ref.id,
            "rawText":        user_message,
            "parsedAmount":   float(amount),
            "parsedCategory": category if not category_uncertain else None,
            "parsedType":     tx_type,
            "sourceApp":      source_app,
            "status":         "pending",
            "transactionId":  tx_ref.id,
        }

        # D. Build reply — different for certain vs uncertain category
        if category_uncertain:
            # Category unknown → ask the user
            cat_options = "/".join(c for c in EXPENSE_CATEGORIES if c != "Other")
            if tx_type == "expense":
                reply = (
                    f"{source_app} bata Rs {int(amount)} expense detect bhayo. "
                    f"Kun category ma halne? ({cat_options}/Other)"
                )
            else:
                reply = (
                    f"{source_app} bata Rs {int(amount)} income detect bhayo. "
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
            "role":                 "assistant",
            "content":              reply,
            "intent":               reply_intent,
            "extractedData":        [{
                "intent": reply_intent,
                "amount": float(amount),
                "category": category if not category_uncertain else None,
                "type": tx_type,
            }],
            "relatedTransactionId": tx_ref.id,
            "createdAt":            SERVER_TIMESTAMP,
        })

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

    # ── Call Gemini ──────────────────────────────────────────────────────
    gemini_result = await process_chat_message(user_message)
    gemini_reply = gemini_result["reply"]
    actions = gemini_result["actions"]

    print(f"[CHAT] uid={uid} actions={[a.get('intent') for a in actions]}")

    # ── Accumulators ─────────────────────────────────────────────────────
    last_transaction = None
    last_budget_update = None
    alerts_created = []
    reply_parts = []           # pieces like "Rs 150 Food", "Transport budget Rs 5000 set"
    primary_intent = actions[0].get("intent", "general_chat") if actions else "general_chat"

    # ── Process each action ──────────────────────────────────────────────
    for action in actions:
        intent = action.get("intent", "general_chat")
        month_key = action.get("monthKey") or get_current_month_key()

        # ── EXPENSE / INCOME ─────────────────────────────────────────────
        if intent in ("expense_log", "income_log") and action.get("amount"):
            txn, bud, alt, rp = _handle_expense_or_income(
                db, uid, action, source, month_key,
            )
            last_transaction = txn
            if bud:
                last_budget_update = bud
            if alt:
                alerts_created.append(alt)
            reply_parts.append(rp)

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
            reply_parts.append(f"Yo mahina total kharcha Rs {int(total)} cha")
            print(f"[CHAT] query_month_total: Rs {total}")

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

        # ── GENERAL CHAT / GREETING ──────────────────────────────────────
        else:
            print(f"[CHAT] General/greeting — no DB writes")

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
        "role": "assistant",
        "content": reply,
        "intent": primary_intent,
        "extractedData": extracted,
        "relatedTransactionId": last_transaction["id"] if last_transaction else None,
        "createdAt": SERVER_TIMESTAMP,
    })

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
# GET /messages
# ═══════════════════════════════════════════════════════════════════════════════

@router.get("/messages")
async def get_messages(
    monthKey: Optional[str] = Query(None),
    limit: int = Query(50),
    current_user: dict = Depends(get_current_user),
):
    """Get chat history/messages for current user."""
    uid = current_user["uid"]
    db = get_firestore()

    messages_ref = db.collection("users").document(uid).collection("messages")
    query = messages_ref.order_by("createdAt", direction="DESCENDING").limit(limit)
    docs = query.stream()

    messages = []
    for doc in docs:
        data = doc.to_dict()
        data["id"] = doc.id
        messages.append(serialize_doc(data))

    return {
        "success": True,
        "data": {
            "messages": messages,
            "count": len(messages),
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