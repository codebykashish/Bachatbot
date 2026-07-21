"""
routes/notifications.py
=========================
The Notification Engine's own thin API surface — Phase 5.8 (device
token registration) and the Notification Center's mutation endpoints
(read/dismiss). No calculation happens here; every route is a direct
pass-through to services/delivery_service.py or
services/notification_repository.py, both already frozen and tested.

The notification LIST is read directly from Firestore by the client
(users/{uid}/generatedNotifications, same real-time-listener pattern
already used for the legacy alerts system) — no list route exists here
by design, since a read-only fan-out has no business logic to own.
Mutating a notification's status, however, goes through the Repository
here rather than a direct client write, so its idempotency guarantees
(mark_read/mark_dismissed never move status backward) stay the single,
server-owned source of truth rather than being re-implemented in Flutter.
"""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from firebase_config import get_firestore
from auth import get_current_user
from services.delivery_service import save_device_token
from services import notification_repository as repo

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


def _not_found(event_id: str):
    return HTTPException(
        status_code=404,
        detail={
            "success": False,
            "error": {
                "code": "NOTIFICATION_NOT_FOUND",
                "message": f"No notification '{event_id}' for this user.",
            },
        },
    )


@router.post("/notifications/{event_id}/read")
async def mark_notification_read(
    event_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Marks a notification Read. Idempotent — see notification_repository.mark_read()."""
    db = get_firestore()
    uid = current_user["uid"]
    try:
        notification = repo.mark_read(db, uid, event_id)
    except ValueError:
        raise _not_found(event_id)
    return {"success": True, "notification": notification}


@router.post("/notifications/{event_id}/dismiss")
async def dismiss_notification(
    event_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Marks a notification Dismissed. Idempotent — see notification_repository.mark_dismissed()."""
    db = get_firestore()
    uid = current_user["uid"]
    try:
        notification = repo.mark_dismissed(db, uid, event_id)
    except ValueError:
        raise _not_found(event_id)
    return {"success": True, "notification": notification}
