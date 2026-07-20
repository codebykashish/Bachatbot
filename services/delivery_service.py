"""
delivery_service.py
=====================
Delivery — Phase 5.8. See backend/FINANCIAL_ENGINE_SPEC.md, "Phase 5.8
— Delivery Philosophy" and "Phase 5.8 — Implementation Scope," for the
full contract this file implements.

Delivery consumes an already-created Notification (services/
notification_generator.py, services/notification_repository.py)
exactly as-is — it never changes or reinterprets any field the
Generator or Repository already froze. It owns exactly one new
capability: getting an already-created notification to FCM, retrying
transport on failure without ever regenerating or duplicating the
notification itself (the idempotency-boundary principle, spec 5.8).

`Delivered` means "successfully handed to FCM, confirmed accepted" —
never "displayed on device" or "opened" (spec 5.8's frozen definition).

Public API:
    save_device_token(db, uid, token) -> None
    deliver_notification(db, uid, notification, max_retries=3) -> dict
"""

import logging

from firebase_admin import messaging

from services import notification_repository as repo

logger = logging.getLogger(__name__)

MAX_RETRIES_DEFAULT = 3

_ALREADY_DELIVERED_STATUSES = {"Delivered", "Read", "Dismissed"}


def save_device_token(db, uid: str, token: str) -> None:
    """
    Stores this user's current FCM device token, overwriting any
    previous one. A token is the current delivery address, not history
    — a device re-registering replaces it, it doesn't accumulate a log
    of every token this user has ever had.
    """
    if not token:
        raise ValueError("fcmToken must be a non-empty string")
    db.collection("users").document(uid).set({"fcmToken": token}, merge=True)


def _get_device_token(db, uid: str):
    doc = db.collection("users").document(uid).get()
    data = doc.to_dict() or {}
    return data.get("fcmToken")


def _send_once(token: str, notification: dict) -> None:
    """One real attempt to hand this notification to FCM. Raises on
    failure — the caller (deliver_notification) decides whether to
    retry; this function never retries itself."""
    message = messaging.Message(
        notification=messaging.Notification(
            title=notification["title"],
            body=notification["body"],
        ),
        data={
            "eventCode": notification["eventCode"],
            "eventId": notification.get("eventId") or "",
        },
        token=token,
    )
    messaging.send(message)


def deliver_notification(db, uid: str, notification: dict, max_retries: int = MAX_RETRIES_DEFAULT) -> dict:
    """
    Attempts to hand an already-created Notification to FCM, retrying
    transport failures up to `max_retries` times — the notification
    itself is never regenerated or duplicated across those retries
    (spec 5.8's idempotency-boundary principle). Updates the
    Repository's status/deliveredAt exactly once, only on a confirmed
    successful hand-off — never speculatively, never more than once.

    Returns the notification's current Repository state. If delivery
    cannot succeed after all retries (or there is no registered device
    token at all), the notification is left as-is — still eligible for
    a future retry, e.g. from the next scheduler run — never marked
    Delivered on a guess.
    """
    if notification.get("status") in _ALREADY_DELIVERED_STATUSES:
        # Already delivered (or further along) -- delivering again would
        # violate "exactly once" on the status transition, even though
        # the transport retry loop itself is allowed to repeat.
        return notification

    token = _get_device_token(db, uid)
    if not token:
        logger.warning("[DELIVERY] uid=%s has no registered device token — cannot deliver", uid)
        return notification

    last_error = None
    for attempt in range(1, max_retries + 1):
        try:
            _send_once(token, notification)
            return repo.mark_delivered(db, uid, notification["eventId"])
        except Exception as exc:
            last_error = exc
            logger.warning(
                "[DELIVERY] uid=%s attempt=%d/%d failed: %s", uid, attempt, max_retries, exc
            )

    logger.error(
        "[DELIVERY] uid=%s exhausted %d retries, giving up this run: %s",
        uid, max_retries, last_error,
    )
    return notification
