"""
test_delivery_service.py
==========================
Phase 5.8 acceptance scenarios for Delivery — see
FINANCIAL_ENGINE_SPEC.md's "Phase 5.8 — Delivery Philosophy." Pure
logic tests against a minimal fake Firestore and a mocked
`messaging.send` — no real FCM call, no real device needed. Verifies
the idempotency-boundary principle (retries never duplicate the
notification, only the transport attempt) and that `Delivered` is only
ever set on a confirmed successful hand-off.

Run directly: python tests/test_delivery_service.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import delivery_service as delivery
from services import notification_repository as repo

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fake Firestore (same shape as test_notification_repository.py) ───

_SERVER_TIMESTAMP_SENTINEL = object()
repo.SERVER_TIMESTAMP = _SERVER_TIMESTAMP_SENTINEL


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

    def set(self, data, merge=False):
        if merge and self._key in self._store:
            merged = dict(self._store[self._key])
            merged.update(data)
            self._store[self._key] = merged
        else:
            record = dict(data)
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


class FakeCollectionRef:
    def __init__(self, store, prefix, seq):
        self._store = store
        self._prefix = prefix
        self._seq = seq

    def document(self, doc_id):
        return FakeDocRef(self._store, f"{self._prefix}/{doc_id}", self._seq)


class FakeUserDocRef:
    def __init__(self, store, uid, seq):
        self._store = store
        self._uid = uid
        self._seq = seq

    def collection(self, name):
        return FakeCollectionRef(self._store, f"users/{self._uid}/{name}", self._seq)

    def get(self):
        return FakeSnapshot(self._store.get(f"users/{self._uid}"))

    def set(self, data, merge=False):
        key = f"users/{self._uid}"
        if merge and key in self._store:
            merged = dict(self._store[key])
            merged.update(data)
            self._store[key] = merged
        else:
            self._store[key] = dict(data)


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


def _sample_notification(**overrides):
    n = {
        "eventId": "u1:2026-07-19:health_worsened", "eventCode": "HEALTH_WORSENED",
        "priority": "High", "frequency": "DAILY", "timing": "IMMEDIATE",
        "interruptionLevel": None, "templateId": "TITLE_HEALTH_WORSENED",
        "title": "Spending pace increased", "body": "You're spending faster than your monthly plan",
        "cta": "Review your spending", "payload": {"from": "green", "to": "amber"},
        "deepLink": None, "status": "Created",
    }
    n.update(overrides)
    return n


def run():
    print("Delivery Service — test matrix")

    # 1. No registered device token -> no-op, no crash, status unchanged
    db1 = FakeDB()
    n1 = repo.save(db1, "u1", _sample_notification())
    result1 = delivery.deliver_notification(db1, "u1", n1)
    check(
        "No device token -> delivery is a no-op, status stays Created",
        result1["status"] == "Created",
        f"got {result1}",
    )

    # 2. A registered token + successful send -> marks Delivered exactly once
    db2 = FakeDB()
    delivery.save_device_token(db2, "u2", "fake-token-abc")
    n2 = repo.save(db2, "u2", _sample_notification())
    delivery.messaging.send = lambda message: "message-id-123"
    result2 = delivery.deliver_notification(db2, "u2", n2)
    check(
        "A successful send marks the notification Delivered",
        result2["status"] == "Delivered" and result2["deliveredAt"] is not None,
        f"got {result2}",
    )

    # 3. A send that fails every retry leaves the notification untouched (still Created)
    db3 = FakeDB()
    delivery.save_device_token(db3, "u3", "fake-token-xyz")
    n3 = repo.save(db3, "u3", _sample_notification(eventId="u3:2026-07-19:health_worsened"))

    def _always_fails(message):
        raise RuntimeError("simulated FCM failure")

    delivery.messaging.send = _always_fails
    result3 = delivery.deliver_notification(db3, "u3", n3, max_retries=3)
    check(
        "Exhausting all retries leaves the notification as Created, not Delivered",
        result3["status"] == "Created",
        f"got {result3}",
    )

    # 4. Retries happen the correct number of times -- exactly max_retries attempts,
    # never regenerating a second notification document
    attempt_count = {"n": 0}

    def _counting_fail(message):
        attempt_count["n"] += 1
        raise RuntimeError("still failing")

    delivery.messaging.send = _counting_fail
    delivery.deliver_notification(db3, "u3", n3, max_retries=3)
    check(
        "deliver_notification attempts exactly max_retries times, never more",
        attempt_count["n"] == 3,
        f"got {attempt_count['n']}",
    )
    check(
        "Retrying never creates a second notification document for the same event",
        len([k for k in db3._store if k.startswith("users/u3/generatedNotifications/")]) == 1,
        f"got {[k for k in db3._store if 'generatedNotifications' in k]}",
    )

    # 5. Succeeding on a later attempt (not the first) still only marks Delivered once
    db5 = FakeDB()
    delivery.save_device_token(db5, "u5", "fake-token-retry")
    n5 = repo.save(db5, "u5", _sample_notification(eventId="u5:2026-07-19:health_worsened"))
    calls = {"n": 0}

    def _fails_then_succeeds(message):
        calls["n"] += 1
        if calls["n"] < 2:
            raise RuntimeError("transient failure")
        return "message-id-456"

    delivery.messaging.send = _fails_then_succeeds
    result5 = delivery.deliver_notification(db5, "u5", n5, max_retries=3)
    check(
        "Succeeding on the second attempt marks Delivered, after exactly one prior failure",
        result5["status"] == "Delivered" and calls["n"] == 2,
        f"got {result5}, calls={calls['n']}",
    )

    # 6. An already-Delivered notification is never re-sent
    send_called = {"n": 0}
    delivery.messaging.send = lambda message: send_called.update(n=send_called["n"] + 1)
    already_delivered = repo.save(db5, "u6", _sample_notification(eventId="u6:already", status="Delivered"))
    result6 = delivery.deliver_notification(db5, "u6", already_delivered)
    check(
        "An already-Delivered notification is never re-sent",
        send_called["n"] == 0 and result6["status"] == "Delivered",
        f"got {result6}, sends={send_called['n']}",
    )

    # 7. save_device_token rejects an empty token
    try:
        delivery.save_device_token(db5, "u7", "")
        check("save_device_token rejects an empty token", False, "did not raise")
    except ValueError:
        check("save_device_token rejects an empty token", True)

    # 8. save_device_token overwrites, not accumulates
    db8 = FakeDB()
    delivery.save_device_token(db8, "u8", "token-1")
    delivery.save_device_token(db8, "u8", "token-2")
    check(
        "save_device_token overwrites the previous token, doesn't accumulate a history",
        db8._store["users/u8"] == {"fcmToken": "token-2"},
        f"got {db8._store['users/u8']}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Delivery Service scenarios passed.")


if __name__ == "__main__":
    run()
