from fastapi import APIRouter, Depends, HTTPException, Request, Query
from firebase_config import get_firestore
from auth import get_current_user
from gemini import process_chat_message, parse_notification_text
from schemas.categories import EXPENSE_CATEGORIES
from utils import (
    get_current_month_key, serialize_doc,
    sum_month_expense, sum_category_expense, fetch_budget,
    get_today_date_range, get_week_date_range,
    sum_month_income, is_today,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment
from typing import Optional

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
async def chat(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    body = await request.json()
    user_message = body.get("message", "").strip()
    source = body.get("source", "chat")
    idempotency_key = body.get("idempotencyKey") or None

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

    # ── Process each action ──────────────────────────────────────────────
    for action in actions:
        intent = action.get("intent", "general_chat")
        month_key = action.get("monthKey") or get_current_month_key()

        # ── EXPENSE / INCOME ─────────────────────────────────────────────
        if intent in ("expense_log", "income_log") and action.get("amount"):
            txn, bud, alt, rp = _handle_expense_or_income(
                db, uid, action, source, month_key,
                idempotency_key=idempotency_key,
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

                net_savings = r_income - r_expense
                cat_parts = ", ".join(f"{c}: Rs {int(v)}" for c, v in sorted(r_categories.items(), key=lambda x: -x[1]))
                if r_expense > 0 and cat_parts:
                    reply_parts.append(
                        f"Yo mahina ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. Net savings: Rs {int(net_savings)}. {cat_parts}"
                    )
                elif r_expense > 0:
                    reply_parts.append(
                        f"Yo mahina ko report: Rs {int(r_expense)} kharcha, Rs {int(r_income)} income. Net savings: Rs {int(net_savings)}"
                    )
                else:
                    reply_parts.append("Yo mahina ma kei kharcha bhayena")

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
                "content": user_message,
                "intent": None,
                "extractedData": None,
                "relatedTransactionId": None,
                "clientTimestamp": client_ts_str,
                "source": "offline_sync",
                "createdAt": SERVER_TIMESTAMP,
            })

            # ── Call Gemini ──────────────────────────────────────────────
            gemini_result = await process_chat_message(user_message)
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
                month_key = action.get("monthKey") or derived_month_key

                # ── EXPENSE / INCOME ─────────────────────────────────────
                if intent in ("expense_log", "income_log") and action.get("amount"):
                    txn, bud, alt, rp = _handle_expense_or_income(
                        db, uid, action, source, month_key,
                        idempotency_key=sync_idempotency_key,
                    )
                    last_transaction = txn
                    if bud:
                        last_budget_update = bud
                    if alt:
                        alerts_created.append(alt)
                    reply_parts.append(rp)

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
                        reply = ", ".join(reply_parts) + " ma save gareko chu ✅"
                    else:
                        reply = reply_parts[0] + " ma save gareko chu ✅"
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
                "role": "assistant",
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