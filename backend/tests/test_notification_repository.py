"""
test_notification_repository.py
=================================
Phase 5.7 acceptance scenarios for the Notification Repository — see
FINANCIAL_ENGINE_SPEC.md's "Phase 5.7 — Notification Repository."
Pure data-access tests against a minimal fake Firestore client (no real
project needed) — this module has no business logic to exercise, only
save/get/list/mark semantics.

Run directly: python tests/test_notification_repository.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import notification_repository as repo

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fake Firestore — supports order_by/limit/stream for lists ────

class FakeSnapshot:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class FakeDocRef:
    def __init__(self, store, key, seq):
        self._store = store
        self._key = key
        self._seq = seq

    def get(self):
        return FakeSnapshot(self._store.get(self._key))

    def set(self, data):
        record = dict(data)
        # Fake SERVER_TIMESTAMP as a monotonically increasing counter so
        # order_by("createdAt") is meaningfully testable without real time.
        for k, v in record.items():
            if v is _SERVER_TIMESTAMP_SENTINEL:
                record[k] = self._seq["n"]
                self._seq["n"] += 1
        self._store[self._key] = record

    def update(self, patch):
        current = dict(self._store[self._key])
        for k, v in patch.items():
            current[k] = self._seq["n"] if v is _SERVER_TIMESTAMP_SENTINEL else v
            if v is _SERVER_TIMESTAMP_SENTINEL:
                self._seq["n"] += 1
        self._store[self._key] = current


class FakeQuery:
    def __init__(self, store, prefix, order_field=None, descending=False, limit_n=None):
        self._store = store
        self._prefix = prefix
        self._order_field = order_field
        self._descending = descending
        self._limit_n = limit_n

    def order_by(self, field, direction="ASCENDING"):
        return FakeQuery(self._store, self._prefix, field, direction == "DESCENDING", self._limit_n)

    def limit(self, n):
        return FakeQuery(self._store, self._prefix, self._order_field, self._descending, n)

    def stream(self):
        docs = [
            FakeSnapshot(v) for k, v in self._store.items()
            if k.startswith(self._prefix + "/") and k.count("/") == self._prefix.count("/") + 1
        ]
        if self._order_field:
            docs.sort(key=lambda d: d.to_dict()[self._order_field], reverse=self._descending)
        if self._limit_n is not None:
            docs = docs[: self._limit_n]
        return docs


class FakeCollectionRef:
    def __init__(self, store, prefix, seq):
        self._store = store
        self._prefix = prefix
        self._seq = seq

    def document(self, doc_id):
        return FakeDocRef(self._store, f"{self._prefix}/{doc_id}", self._seq)

    def order_by(self, field, direction="ASCENDING"):
        return FakeQuery(self._store, self._prefix, field, direction == "DESCENDING")


class FakeUserDocRef:
    def __init__(self, store, uid, seq):
        self._store = store
        self._uid = uid
        self._seq = seq

    def collection(self, name):
        return FakeCollectionRef(self._store, f"users/{self._uid}/{name}", self._seq)


class FakeDB:
    def __init__(self):
        self._store = {}
        self._seq = {"n": 0}

    def collection(self, name):
        assert name == "users"
        return _UsersCollection(self._store, self._seq)


class _UsersCollection:
    def __init__(self, store, seq):
        self._store = store
        self._seq = seq

    def document(self, uid):
        return FakeUserDocRef(self._store, uid, self._seq)


_SERVER_TIMESTAMP_SENTINEL = object()


def _patch_server_timestamp():
    """Swap repo's SERVER_TIMESTAMP for our fake sentinel so createdAt/
    readAt/etc. become orderable integers in the fake store, without
    needing real Firestore or real wall-clock time."""
    repo.SERVER_TIMESTAMP = _SERVER_TIMESTAMP_SENTINEL


_patch_server_timestamp()


def _sample_notification(event_id="u1:2026-07-19:health_worsened", **overrides):
    n = {
        "eventId": event_id, "eventCode": "HEALTH_WORSENED", "priority": "High",
        "frequency": "DAILY", "timing": "IMMEDIATE", "interruptionLevel": None,
        "templateId": "TITLE_HEALTH_WORSENED", "title": "Spending pace increased",
        "body": "You're spending faster than your monthly plan", "cta": "Review your spending",
        "payload": {"from": "green", "to": "amber"}, "deepLink": None, "status": "Created",
    }
    n.update(overrides)
    return n


def run():
    print("Notification Repository — test matrix")
    db = FakeDB()
    uid = "u1"

    # 1. save() persists a new notification, initializing lifecycle fields
    n1 = repo.save(db, uid, _sample_notification())
    check(
        "save() writes the notification and initializes createdAt/deliveredAt/readAt/dismissedAt",
        n1["createdAt"] is not None and n1["deliveredAt"] is None
        and n1["readAt"] is None and n1["dismissedAt"] is None,
        f"got {n1}",
    )
    check(
        "notificationId equals eventId (frozen in 5.7)",
        repo.get(db, uid, n1["eventId"]) == n1,
        f"got {repo.get(db, uid, n1['eventId'])}",
    )

    # 2. save() is idempotent -- calling twice for the same eventId is a no-op
    n1_again = repo.save(db, uid, _sample_notification(title="A DIFFERENT TITLE"))
    check(
        "save() called twice for the same eventId returns the original, unmodified",
        n1_again == n1,
        f"got {n1_again}",
    )

    # 3. get() returns None for a notification that doesn't exist
    check(
        "get() returns None for a nonexistent notification",
        repo.get(db, uid, "does-not-exist") is None,
    )

    # 4. Save a second, later notification and confirm list ordering
    n2 = repo.save(db, uid, _sample_notification(event_id="u1:2026-07-20:logging_streak_extended", eventCode="LOGGING_STREAK_EXTENDED", status="Created"))
    all_notifications = repo.list_notifications(db, uid)
    check(
        "list_notifications returns all notifications, most recent first",
        [n["eventId"] for n in all_notifications] == [n2["eventId"], n1["eventId"]],
        f"got {[n['eventId'] for n in all_notifications]}",
    )

    # 5. list_unread only returns Created/Delivered notifications
    check(
        "list_unread returns both notifications while both are still Created",
        len(repo.list_unread(db, uid)) == 2,
        f"got {repo.list_unread(db, uid)}",
    )

    # 6. mark_read sets status and readAt, touches nothing else
    read_n1 = repo.mark_read(db, uid, n1["eventId"])
    check(
        "mark_read sets status to Read and stamps readAt",
        read_n1["status"] == "Read" and read_n1["readAt"] is not None,
        f"got {read_n1}",
    )
    check(
        "mark_read never touches title/body/priority/eventCode (Rule 4)",
        read_n1["title"] == n1["title"] and read_n1["body"] == n1["body"]
        and read_n1["priority"] == n1["priority"] and read_n1["eventCode"] == n1["eventCode"],
        f"got {read_n1}",
    )

    # 7. list_unread now excludes the Read notification
    unread_after_read = repo.list_unread(db, uid)
    check(
        "list_unread excludes a notification once it's been marked Read",
        [n["eventId"] for n in unread_after_read] == [n2["eventId"]],
        f"got {[n['eventId'] for n in unread_after_read]}",
    )

    # 8. mark_read is idempotent -- marking an already-Read notification again is a no-op
    read_n1_again = repo.mark_read(db, uid, n1["eventId"])
    check(
        "mark_read on an already-Read notification returns it unchanged (same readAt)",
        read_n1_again == read_n1,
        f"got {read_n1_again}",
    )

    # 9. mark_dismissed sets status and dismissedAt, never deletes the document (Rule 3)
    dismissed_n2 = repo.mark_dismissed(db, uid, n2["eventId"])
    check(
        "mark_dismissed sets status to Dismissed and stamps dismissedAt",
        dismissed_n2["status"] == "Dismissed" and dismissed_n2["dismissedAt"] is not None,
        f"got {dismissed_n2}",
    )
    check(
        "The dismissed notification's document still exists -- history is never deleted",
        repo.get(db, uid, n2["eventId"]) is not None,
    )
    check(
        "list_unread is now empty -- both notifications resolved (Read, Dismissed)",
        repo.list_unread(db, uid) == [],
        f"got {repo.list_unread(db, uid)}",
    )

    # 10. list_recent respects its limit
    for i in range(5):
        repo.save(db, uid, _sample_notification(event_id=f"u1:2026-08-{i:02d}:milestone_unlocked:X{i}", eventCode="MILESTONE_UNLOCKED"))
    recent = repo.list_recent(db, uid, limit=3)
    check(
        "list_recent respects its limit argument",
        len(recent) == 3,
        f"got {len(recent)}",
    )

    # 11. mark_read/mark_dismissed on a nonexistent notification raises
    try:
        repo.mark_read(db, uid, "does-not-exist")
        check("mark_read on a nonexistent notification raises ValueError", False, "did not raise")
    except ValueError:
        check("mark_read on a nonexistent notification raises ValueError", True)

    # 12. mark_delivered sets status and deliveredAt, is idempotent past Delivered
    n3 = repo.save(db, uid, _sample_notification(event_id="u1:2026-09-01:health_worsened"))
    delivered_n3 = repo.mark_delivered(db, uid, n3["eventId"])
    check(
        "mark_delivered sets status to Delivered and stamps deliveredAt",
        delivered_n3["status"] == "Delivered" and delivered_n3["deliveredAt"] is not None,
        f"got {delivered_n3}",
    )
    read_n3 = repo.mark_read(db, uid, n3["eventId"])
    delivered_n3_again = repo.mark_delivered(db, uid, n3["eventId"])
    check(
        "mark_delivered on a notification already past Delivered (Read) is a no-op",
        delivered_n3_again == read_n3,
        f"got {delivered_n3_again}",
    )

    # 13. mark_expired sets status to Expired, is a no-op past Created/Delivered
    n4 = repo.save(db, uid, _sample_notification(event_id="u1:2026-09-02:health_worsened"))
    expired_n4 = repo.mark_expired(db, uid, n4["eventId"])
    check(
        "mark_expired sets status to Expired for a still-unread (Created) notification",
        expired_n4["status"] == "Expired",
        f"got {expired_n4}",
    )
    n5 = repo.save(db, uid, _sample_notification(event_id="u1:2026-09-03:health_worsened"))
    dismissed_n5 = repo.mark_dismissed(db, uid, n5["eventId"])
    expired_n5 = repo.mark_expired(db, uid, n5["eventId"])
    check(
        "mark_expired never overrides a real user action (Dismissed stays Dismissed)",
        expired_n5 == dismissed_n5,
        f"got {expired_n5}",
    )

    # 14. expire_stale_notifications marks Expired only notifications older
    # than max_age_days, leaving fresh ones and already-resolved ones alone
    from datetime import datetime, timedelta, timezone
    db2 = FakeDB()
    uid2 = "u2"
    # Built directly with explicit real datetimes (not via save()'s fake
    # counter sentinel) so all three documents' createdAt values are of a
    # uniform, mutually-comparable type -- exercising the actual
    # datetime-vs-cutoff staleness comparison in expire_stale_notifications.
    now = datetime.now(timezone.utc)

    def _seed(event_id, created_at, status="Created"):
        n = _sample_notification(event_id=event_id, status=status)
        n["createdAt"] = created_at
        n["deliveredAt"] = None
        n["readAt"] = now if status == "Read" else None
        n["dismissedAt"] = None
        db2._store[f"users/{uid2}/generatedNotifications/{event_id}"] = n
        return n

    old = _seed("u2:old:health_worsened", now - timedelta(days=30))
    fresh = _seed("u2:fresh:health_worsened", now - timedelta(days=1))
    resolved = _seed("u2:resolved:health_worsened", now - timedelta(days=30), status="Read")
    expired = repo.expire_stale_notifications(db2, uid2, max_age_days=14)
    check(
        "expire_stale_notifications expires only the notification older than max_age_days",
        [n["eventId"] for n in expired] == [old["eventId"]],
        f"got {[n['eventId'] for n in expired]}",
    )
    check(
        "expire_stale_notifications leaves a fresh unread notification untouched",
        repo.get(db2, uid2, fresh["eventId"])["status"] == "Created",
    )
    check(
        "expire_stale_notifications leaves an already-resolved (Read) notification untouched",
        repo.get(db2, uid2, resolved["eventId"])["status"] == "Read",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Notification Repository scenarios passed.")


if __name__ == "__main__":
    run()
