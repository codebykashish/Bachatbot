from fastapi import APIRouter, Depends, HTTPException, Request, Query
from firebase_config import get_firestore
from auth import get_current_user
from gemini import process_chat_message
from utils import get_current_month_key, serialize_doc
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
    source_app = body.get("sourceApp", "Unknown")
    original_message_id = body.get("originalMessageId")

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
    amount = gemini_result["amount"]
    category = gemini_result["category"]
    tx_type = gemini_result["type"]
    description = gemini_result["description"]

    # Initialize
    transaction_data = None
    notification_data = None
    budget_update = None
    month_key = get_current_month_key()
    needs_confirmation = False

    # Check if this is a notification source
    if source == "notification":
        needs_confirmation = True
        if intent == "notification_parse" or (intent in ["expense_log", "income_log"] and amount and category):
            # Create a PENDING transaction
            tx_ref = db.collection("users").document(uid).collection("transactions").document()
            
            tx_data = {
                "amount": float(amount),
                "category": category,
                "type": tx_type or "expense",
                "status": "pending",
                "source": "notification",
                "description": user_message,
                "monthKey": month_key,
                "isDeleted": False,
                "deletedAt": None,
                "originalMessageId": original_message_id,
                "createdAt": SERVER_TIMESTAMP,
                "updatedAt": SERVER_TIMESTAMP
            }
            tx_ref.set(tx_data)

            transaction_data = {
                "id": tx_ref.id,
                "amount": float(amount),
                "category": category,
                "type": tx_type or "expense",
                "status": "pending",
                "source": "notification",
                "description": user_message,
                "monthKey": month_key,
                "isDeleted": False,
                "deletedAt": None,
                "originalMessageId": original_message_id
            }

            # Create a notification document
            notif_ref = db.collection("users").document(uid).collection("notifications").document()
            notif_data = {
                "rawText": user_message,
                "parsedAmount": float(amount),
                "parsedCategory": category,
                "parsedType": tx_type or "expense",
                "sourceApp": source_app,
                "status": "pending",
                "transactionId": tx_ref.id,
                "createdAt": SERVER_TIMESTAMP
            }
            notif_ref.set(notif_data)

            notification_data = {
                "id": notif_ref.id,
                "rawText": user_message,
                "parsedAmount": float(amount),
                "parsedCategory": category,
                "parsedType": tx_type or "expense",
                "sourceApp": source_app,
                "status": "pending",
                "transactionId": tx_ref.id
            }
            
            print(f"[CHAT][NOTIF] uid={uid} amount={amount} category={category} type={tx_type}")

    # For source == "chat" (existing behavior)
    elif intent in ["expense_log", "income_log"] and amount and category:

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

        # ── Budget spent increment (only for expenses) ──────────────────────
        if intent == "expense_log":
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
                # Atomic increment — safe under concurrent writes
                from google.cloud.firestore_v1 import Increment
                budget_ref.update({
                    "spent": Increment(float(amount)),
                    "updatedAt": SERVER_TIMESTAMP,
                })
                updated_budget = budget_ref.get().to_dict()
                new_spent = updated_budget.get("spent", 0.0)
                budget_limit = updated_budget.get("limit", 0.0)
                percent_used = round((new_spent / budget_limit) * 100, 2) if budget_limit > 0 else 0.0
                budget_update = {
                    "id": budget_doc.id,
                    "category": category,
                    "limit": budget_limit,
                    "spent": new_spent,
                    "percentUsed": percent_used,
                    "monthKey": month_key,
                }

    # Save assistant reply to messages
    assistant_msg_ref = messages_ref.document()
    assistant_msg_ref.set({
        "role": "assistant",
        "content": reply,
        "intent": intent,
        "extractedData": {
            "amount": amount,
            "category": category,
            "type": tx_type
        } if intent in ["expense_log", "income_log", "notification_parse"] else None,
        "relatedTransactionId": transaction_data["id"] if transaction_data else None,
        "createdAt": SERVER_TIMESTAMP
    })

    response_data = {
        "reply": reply,
        "intent": intent,
        "needsConfirmation": needs_confirmation,
        "transaction": transaction_data,
        "budgetUpdate": budget_update,
        "alerts": []
    }

    if notification_data:
        response_data["notification"] = notification_data

    return {
        "success": True,
        "data": response_data
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