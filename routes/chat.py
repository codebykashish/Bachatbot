from fastapi import APIRouter, Depends, HTTPException, Request
from firebase_config import get_firestore
from auth import get_current_user
from gemini import process_chat_message
from utils import get_current_month_key
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

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
    month_key = get_current_month_key()

    # If expense or income detected, save transaction
    if intent in ["expense_log", "income_log"] and amount and category:

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
        } if intent in ["expense_log", "income_log"] else None,
        "relatedTransactionId": transaction_data["id"] if transaction_data else None,
        "createdAt": SERVER_TIMESTAMP
    })

    return {
        "success": True,
        "data": {
            "reply": reply,
            "intent": intent,
            "needsConfirmation": False,
            "transaction": transaction_data,
            "budgetUpdate": None,
            "alerts": []
        }
    }