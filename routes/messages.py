from fastapi import APIRouter, Depends, HTTPException
from firebase_config import get_firestore
from auth import get_current_user

router = APIRouter()

# NOTE: GET /messages and POST /messages are defined in routes/chat.py
# to keep all message logic in one place. This file only has the DELETE route.


@router.delete("/messages/{message_id}")
async def delete_message(
    message_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Soft-delete a specific chat message by ID."""
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
    return {"success": True, "message": "Message deleted."}
