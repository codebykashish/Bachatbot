"""
routes/notifications.py
=========================
The Notification Engine's own thin API surface — Phase 5.8. No
calculation happens here; this registers a device's FCM token so
services/delivery_service.py has something real to deliver to (spec
5.8's named prerequisite).
"""

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from firebase_config import get_firestore
from auth import get_current_user
from services.delivery_service import save_device_token

router = APIRouter()


class DeviceTokenRequest(BaseModel):
    fcmToken: str = Field(..., min_length=1)


@router.post("/notifications/device-token")
async def register_device_token(
    body: DeviceTokenRequest,
    current_user: dict = Depends(get_current_user),
):
    """
    Registers (or replaces) the calling user's current FCM device
    token. Overwrites any previous token — the current delivery
    address, not a history.
    """
    db = get_firestore()
    uid = current_user["uid"]
    save_device_token(db, uid, body.fcmToken)
    return {"success": True}
