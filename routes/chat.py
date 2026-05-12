from fastapi import APIRouter, Depends, HTTPException, Request, Query
from firebase_config import get_firestore
from auth import get_current_user
from gemini import process_chat_message
from utils import (
    get_current_month_key, serialize_doc,
    sum_month_expense, sum_category_expense, fetch_budget,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from typing import Optional

router = APIRouter()


@router.post("/chat")
async def chat(
    request: Request,
    current_user: dict = Depends(get_current_user)
):
    uid = current_user["uid"]
    db = get_firestore()

    # Parse request body
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
                "error": {
                    "code": "EMPTY_MESSAGE",
                    "message": "Message cannot be empty."
                }
            }
        )

    # Save user message to Firestore
    messages_ref = db.collection("users").document(uid).collection("messages")

    user_msg_ref = messages_ref.document()
    user_msg_ref.set({
        "role": "user",
        "content": user_message,
        "intent": None,
        "extractedData": None,
        "relatedTransactionId": None,
        "createdAt": SERVER_TIMESTAMP
    })

    # Send to Gemini and get structured response
    gemini_result = await process_chat_message(user_message)

    reply = gemini_result["reply"]
    intent = gemini_result["intent"]
    amount = gemini_result.get("amount")
    limit_val = gemini_result.get("limit")
    category = gemini_result.get("category")
    tx_type = gemini_result.get("type")
    description = gemini_result.get("description")
    parsed_month_key = gemini_result.get("monthKey")

    # Use parsed monthKey or fallback to current
    month_key = parsed_month_key or get_current_month_key()

    print(f"[CHAT] uid={uid} intent={intent} category={category} amount={amount} limit={limit_val} monthKey={month_key}")

    # Initialize response objects
    transaction_data = None
    budget_update = None
    alert_list = []

    # ── INTENT SWITCH ────────────────────────────────────────────────────────

    if intent in ["expense_log", "income_log"] and amount:
        # ── EXPENSE / INCOME LOG ─────────────────────────────────────────
        print(f"[CHAT] Saving transaction: {tx_type} {category or 'Income'} Rs {amount}")

        tx_ref = db.collection("users").document(uid).collection("transactions").document()

        tx_data = {
            "amount": float(amount),
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
            "updatedAt": SERVER_TIMESTAMP
        }

        tx_ref.set(tx_data)
        print(f"[CHAT] Transaction saved: id={tx_ref.id}")

        transaction_data = {
            "id": tx_ref.id,
            "amount": float(amount),
            "category": category,
            "type": tx_type,
            "status": "confirmed",
            "source": source,
            "description": description,
            "monthKey": month_key,
            "isDeleted": False,
            "deletedAt": None,
            "originalMessageId": None
        }

        # ── Budget spent increment (only for expenses) ───────────────────
        percent_used = 0.0
        if intent == "expense_log" and category:
            print(f"[CHAT] [BUDGET] Looking for budget: category='{category}', monthKey='{month_key}'")

            budgets_ref = (
                db.collection("users")
                .document(uid)
                .collection("budgets")
            )

            matching_docs = list(
                budgets_ref
                .where("category", "==", category)
                .where("monthKey", "==", month_key)
                .limit(1)
                .stream()
            )

            if matching_docs:
                budget_doc = matching_docs[0]
                budget_ref = budget_doc.reference
                old_spent = budget_doc.to_dict().get("spent", 0.0)
                print(f"[CHAT] [BUDGET] Found budget id={budget_doc.id}, old spent={old_spent}")

                # Atomic increment
                from google.cloud.firestore_v1 import Increment
                budget_ref.update({
                    "spent": Increment(float(amount)),
                    "updatedAt": SERVER_TIMESTAMP,
                })
                updated_budget = budget_ref.get().to_dict()
                new_spent = updated_budget.get("spent", 0.0)
                budget_limit = updated_budget.get("limit", 0.0)
                remaining = max(0.0, budget_limit - new_spent)
                percent_used = round((new_spent / budget_limit) * 100, 2) if budget_limit > 0 else 0.0
                budget_update = {
                    "id": budget_doc.id,
                    "category": updated_budget.get("category", category),
                    "limit": budget_limit,
                    "spent": new_spent,
                    "remaining": remaining,
                    "percentUsed": percent_used,
                    "monthKey": month_key,
                }
                print(f"[CHAT] [BUDGET] Updated: spent {old_spent} -> {new_spent} ({percent_used}%)")
            else:
                print(f"[CHAT] [BUDGET] No budget found for '{category}' in {month_key} -- skipping spent update")
        elif intent == "income_log":
            print(f"[CHAT] Income logged: Rs {amount} -- no budget update needed")

        # ── Save alert to alerts subcollection ───────────────────────────
        try:
            alert_type_label = "expense" if tx_type == "expense" else "income"
            cat_label = f"{category} " if category else ""
            alert_message = f"Rs {int(float(amount))} {cat_label}{alert_type_label} saved"

            # If > 80% used, append to message
            if intent == "expense_log" and budget_update and percent_used >= 80:
                alert_message = f"{category} Rs{int(float(amount))} saved, {int(percent_used)}% used"

            alert_ref = db.collection("users").document(uid).collection("alerts").document()
            alert_data = {
                "type": "transaction_saved",
                "message": alert_message,
                "category": category,
                "severity": "medium" if percent_used >= 80 else "low",
                "isRead": False,
                "isDeleted": False,
                "monthKey": month_key,
                "relatedTransactionId": tx_ref.id,
                "createdAt": SERVER_TIMESTAMP
            }
            alert_ref.set(alert_data)

            alert_list.append({
                "id": alert_ref.id,
                "type": alert_data["type"],
                "message": alert_message,
                "category": category,
                "severity": alert_data["severity"],
                "isRead": False,
                "monthKey": month_key,
                "relatedTransactionId": tx_ref.id
            })

            print(f"[CHAT] [ALERT] Saved: id={alert_ref.id}, message='{alert_message}'")
        except Exception as e:
            print(f"[CHAT] [ALERT] FAILED to save alert: {e}")

    elif intent == "set_budget" and limit_val is not None and category:
        # ── SET BUDGET ───────────────────────────────────────────────────
        print(f"[CHAT] Setting budget: {category} limit=Rs {limit_val} monthKey={month_key}")

        budgets_ref = db.collection("users").document(uid).collection("budgets")

        matching_docs = list(
            budgets_ref
            .where("category", "==", category)
            .where("monthKey", "==", month_key)
            .limit(1)
            .stream()
        )
        if matching_docs:
            budget_doc = matching_docs[0]
            budget_ref = budget_doc.reference
            budget_ref.update({"limit": float(limit_val), "updatedAt": SERVER_TIMESTAMP})
            budget_id = budget_doc.id
            spent = budget_doc.to_dict().get("spent", 0.0)
            print(f"[CHAT] [BUDGET] Updated existing budget id={budget_id}, kept spent={spent}")
        else:
            new_budget_ref = budgets_ref.document()
            new_budget_ref.set({
                "category": category,
                "limit": float(limit_val),
                "spent": 0.0,
                "monthKey": month_key,
                "alertThreshold": 80,
                "createdAt": SERVER_TIMESTAMP,
                "updatedAt": SERVER_TIMESTAMP
            })
            budget_id = new_budget_ref.id
            spent = 0.0
            print(f"[CHAT] [BUDGET] Created new budget id={budget_id}")

        percent_used = round((spent / float(limit_val)) * 100, 2) if float(limit_val) > 0 else 0.0
        remaining = max(0.0, float(limit_val) - spent)
        budget_update = {
            "id": budget_id,
            "category": category,
            "limit": float(limit_val),
            "spent": spent,
            "remaining": remaining,
            "percentUsed": percent_used,
            "monthKey": month_key
        }
        reply = f"{category} budget Rs {int(limit_val)} set gareko chu. Spent Rs {int(spent)} so far."

    elif intent == "query_month_total":
        # ── QUERY MONTH TOTAL ────────────────────────────────────────────
        total = sum_month_expense(db, uid, month_key)
        reply = f"Yo mahina total kharcha Rs {int(total)} cha."
        print(f"[CHAT] query_month_total: Rs {total}")

    elif intent == "query_category_spend" and category:
        # ── QUERY CATEGORY SPEND ─────────────────────────────────────────
        total = sum_category_expense(db, uid, category, month_key)
        reply = f"{category} ma Rs {int(total)} kharcha gareko chau yo mahina."
        print(f"[CHAT] query_category_spend: {category} -> Rs {total}")

    elif intent == "query_budget_status" and category:
        # ── QUERY BUDGET STATUS ──────────────────────────────────────────
        b_data = fetch_budget(db, uid, category, month_key)
        if b_data:
            b_limit = b_data.get("limit", 0)
            b_spent = b_data.get("spent", 0)
            b_remaining = max(0, b_limit - b_spent)
            b_pct = round((b_spent / b_limit * 100), 1) if b_limit > 0 else 0
            reply = f"{category} budget Rs {int(b_limit)}, spent Rs {int(b_spent)}, baki Rs {int(b_remaining)} ({b_pct}%)."
        else:
            reply = f"{category} ko lagi budget set gareko chaina yo mahina."
        print(f"[CHAT] query_budget_status: {category}")

    else:
        # ── GENERAL CHAT / GREETING ──────────────────────────────────────
        print(f"[CHAT] General chat / greeting — no DB writes")

    # ── Save assistant reply to messages ──────────────────────────────────
    assistant_msg_ref = messages_ref.document()
    assistant_msg_ref.set({
        "role": "assistant",
        "content": reply,
        "intent": intent,
        "extractedData": {
            "amount": amount,
            "limit": limit_val,
            "category": category,
            "type": tx_type,
            "monthKey": parsed_month_key
        } if intent in ["expense_log", "income_log", "set_budget", "query_month_total", "query_category_spend", "query_budget_status"] else None,
        "relatedTransactionId": transaction_data["id"] if transaction_data else None,
        "createdAt": SERVER_TIMESTAMP
    })

    print(f"[CHAT] DONE: intent={intent}, tx={'YES ' + transaction_data['id'] if transaction_data else 'NO'}, budget={'YES' if budget_update else 'NO'}, alerts={len(alert_list)}")
    print(f"{'='*60}\n")

    return {
        "success": True,
        "data": {
            "reply": reply,
            "intent": intent,
            "needsConfirmation": False,
            "transaction": transaction_data,
            "budgetUpdate": budget_update,
            "alerts": alert_list
        }
    }


@router.get("/messages")
async def get_messages(
    monthKey: Optional[str] = Query(None),
    limit: int = Query(50),
    current_user: dict = Depends(get_current_user)
):
    """
    Get chat history/messages for current user
    """
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
            "count": len(messages)
        }
    }


@router.delete("/messages/{message_id}")
async def delete_message(
    message_id: str,
    current_user: dict = Depends(get_current_user)
):
    """
    Delete a message from chat history
    """
    uid = current_user["uid"]
    db = get_firestore()
    
    msg_ref = db.collection("users").document(uid).collection("messages").document(message_id)
    
    doc = msg_ref.get()
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "MESSAGE_NOT_FOUND",
                    "message": "Message not found"
                }
            }
        )
    
    msg_ref.delete()
    
    return {
        "success": True,
        "message": "Message deleted"
    }