"""
notification_repository.py
============================
Notification Repository — Phase 5.7. See backend/FINANCIAL_ENGINE_SPEC.md,
"Phase 5.7 — Notification Repository," for the full contract this file
implements.

This module owns persistence only. It never generates wording, priority,
or timing (Rule 1 — those are services/notification_generator.py's
job), never delivers (Rule 2 — that's Delivery, Phase 5.8), and never
deletes history (Rule 3) — a dismissed notification's status changes,
the document itself never disappears. `status` is the only mutable
field after creation (Rule 4); everything else is written once, at
`save()`, and never touched again.

Public API:
    save(db, uid, notification) -> dict
    get(db, uid, notification_id) -> dict | None
    list_notifications(db, uid, limit=None) -> list[dict]
    list_unread(db, uid) -> list[dict]
    list_recent(db, uid, limit=20) -> list[dict]
    mark_read(db, uid, notification_id) -> dict
    mark_dismissed(db, uid, notification_id) -> dict
    mark_delivered(db, uid, notification_id) -> dict
    mark_expired(db, uid, notification_id) -> dict
    expire_stale_notifications(db, uid, max_age_days=14) -> list[dict]
"""

from datetime import datetime, timedelta, timezone

from google.cloud.firestore_v1 import SERVER_TIMESTAMP

_UNREAD_STATUSES = {"Created", "Delivered"}

# A notification's underlying condition may no longer be true by the
# time it's read (spec 5.0's Rule 5: "every notification expires") --
# but re-checking the actual live condition would mean this
# infrastructure layer reaching back into domain engines, exactly what
# it must never do. Time-based staleness is the honest, available
# alternative: named as such, not disguised as condition-awareness.
_DEFAULT_MAX_AGE_DAYS = 14

# Collection name deliberately NOT "notifications" -- that path is
# already in production use by the bank-SMS pending-transaction flow
# (routes/chat.py, routes/confirm.py: rawText/parsedAmount/transactionId/
# status: pending/confirmed), a completely different system with a
# completely different document shape. Verified free of any existing
# use (grepped the whole backend, firestore.rules, firestore.indexes.json)
# before choosing this name -- see spec 5.7's collision note.
_COLLECTION_NAME = "generatedNotifications"


def _notifications_collection(db, uid: str):
    return db.collection("users").document(uid).collection(_COLLECTION_NAME)


def _notification_ref(db, uid: str, notification_id: str):
    return _notifications_collection(db, uid).document(notification_id)


def save(db, uid: str, notification: dict) -> dict:
    """
    Persists a Notification Generator output (spec 5.6B) exactly once.
    `notificationId` is the same as the notification's own `eventId`
    (frozen in 5.7) — since one event produces at most one notification
    (5.6B), this makes save() naturally idempotent: calling it twice for
    the same event is a safe no-op, the existing document is returned
    unchanged, never overwritten.
    """
    notification_id = notification["eventId"]
    ref = _notification_ref(db, uid, notification_id)

    existing = ref.get()
    if existing.exists:
        return existing.to_dict()

    document = dict(notification)
    document["createdAt"] = SERVER_TIMESTAMP
    document["deliveredAt"] = None
    document["readAt"] = None
    document["dismissedAt"] = None
    ref.set(document)
    return ref.get().to_dict()


def get(db, uid: str, notification_id: str) -> dict:
    """Returns the notification, or None if it doesn't exist."""
    doc = _notification_ref(db, uid, notification_id).get()
    return doc.to_dict() if doc.exists else None


def list_notifications(db, uid: str, limit: int = None) -> list:
    """Every notification for this user, most recent first."""
    query = _notifications_collection(db, uid).order_by(
        "createdAt", direction="DESCENDING"
    )
    if limit is not None:
        query = query.limit(limit)
    return [doc.to_dict() for doc in query.stream()]


def list_unread(db, uid: str) -> list:
    """Notifications not yet Read or Dismissed — Created or Delivered
    only. A filtering operation the Repository owns so Flutter never
    has to duplicate this logic (spec 5.7's own frozen reasoning)."""
    return [
        n for n in list_notifications(db, uid)
        if n.get("status") in _UNREAD_STATUSES
    ]


def list_recent(db, uid: str, limit: int = 20) -> list:
    """The most recent `limit` notifications, regardless of status —
    the Notification Center's own read operation (spec 5.7)."""
    return list_notifications(db, uid, limit=limit)


def mark_delivered(db, uid: str, notification_id: str) -> dict:
    """
    Sets status to Delivered and stamps deliveredAt — the only fields
    this touches (Rule 4). Called by Delivery (spec 5.8) exactly once,
    only on a confirmed successful hand-off to the push provider —
    never speculatively, never more than once. Idempotent: if the
    notification has already moved past Delivered (Read/Dismissed),
    this is a no-op rather than moving the status backward.
    """
    ref = _notification_ref(db, uid, notification_id)
    current = ref.get().to_dict()
    if current is None:
        raise ValueError(f"No notification {notification_id} for uid {uid}")
    if current["status"] in ("Delivered", "Read", "Dismissed"):
        return current
    ref.update({"status": "Delivered", "deliveredAt": SERVER_TIMESTAMP})
    return ref.get().to_dict()


def mark_read(db, uid: str, notification_id: str) -> dict:
    """
    Sets status to Read and stamps readAt — the only fields this
    touches (Rule 4). Idempotent: marking an already-Read or Dismissed
    notification read again leaves it unchanged rather than resetting
    its state or its timestamp.
    """
    ref = _notification_ref(db, uid, notification_id)
    current = ref.get().to_dict()
    if current is None:
        raise ValueError(f"No notification {notification_id} for uid {uid}")
    if current["status"] in ("Read", "Dismissed"):
        return current
    ref.update({"status": "Read", "readAt": SERVER_TIMESTAMP})
    return ref.get().to_dict()


def mark_dismissed(db, uid: str, notification_id: str) -> dict:
    """Sets status to Dismissed and stamps dismissedAt — the only fields
    this touches (Rule 4). The document is never deleted (Rule 3)."""
    ref = _notification_ref(db, uid, notification_id)
    current = ref.get().to_dict()
    if current is None:
        raise ValueError(f"No notification {notification_id} for uid {uid}")
    if current["status"] == "Dismissed":
        return current
    ref.update({"status": "Dismissed", "dismissedAt": SERVER_TIMESTAMP})
    return ref.get().to_dict()


def mark_expired(db, uid: str, notification_id: str) -> dict:
    """
    Sets status to Expired — the only field this touches beyond the
    status itself (Rule 4); no separate `expiredAt` was frozen, since
    Expired is a terminal classification, not an event with its own
    meaningful timestamp the way delivery/read/dismissal are. A no-op
    if the notification has already moved past Created/Delivered
    (Read/Dismissed/already Expired) — Expired never overrides a real
    user action.
    """
    ref = _notification_ref(db, uid, notification_id)
    current = ref.get().to_dict()
    if current is None:
        raise ValueError(f"No notification {notification_id} for uid {uid}")
    if current["status"] not in _UNREAD_STATUSES:
        return current
    ref.update({"status": "Expired"})
    return ref.get().to_dict()


def expire_stale_notifications(db, uid: str, max_age_days: int = _DEFAULT_MAX_AGE_DAYS) -> list:
    """
    Marks Expired every still-unread (Created/Delivered) notification
    older than `max_age_days`. Time-based staleness, not condition-based
    (see the module-level note on why) — a first cut, tunable, named
    honestly as a limitation rather than a full re-evaluation of whether
    each notification's underlying fact is still true.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
    expired = []
    for notification in list_unread(db, uid):
        created_at = notification.get("createdAt")
        is_stale = hasattr(created_at, "tzinfo") and created_at.tzinfo is not None and created_at < cutoff
        if is_stale:
            expired.append(mark_expired(db, uid, notification["eventId"]))
    return expired
