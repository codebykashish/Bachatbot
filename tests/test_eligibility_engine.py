"""
test_eligibility_engine.py
============================
Phase 5.9 acceptance scenarios for the Eligibility Waterfall — see
FINANCIAL_ENGINE_SPEC.md's "Eligibility Waterfall — Implementation."
Pure logic tests against a minimal fake Firestore — no real FCM needed,
since with no device token registered, delivery is always a no-op.

Run directly: python tests/test_eligibility_engine.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import eligibility_engine as elig
from services import notification_repository as repo

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fake Firestore (mirrors test_notification_repository.py) ─────

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


def run():
    print("Eligibility Engine — test matrix")
    db = FakeDB()

    # 1. A plain ALWAYS event with no history is eligible
    event1 = {"eventId": "u1:2026-07-19:health_worsened", "event": "HEALTH_WORSENED", "payload": {"from": "green", "to": "amber"}}
    decision1 = elig.check_eligibility(db, "u1", event1)
    check(
        "An ALWAYS event with no prior history is eligible",
        decision1 == {"eligible": True, "reason": None},
        f"got {decision1}",
    )

    # 2. An unknown event code is never eligible, with a named reason
    decision2 = elig.check_eligibility(db, "u1", {"eventId": "x", "event": "SOME_UNKNOWN_EVENT", "payload": {}})
    check(
        "An unknown event code is ineligible with a named reason",
        decision2["eligible"] is False and "no Eligibility Matrix row" in decision2["reason"],
        f"got {decision2}",
    )

    # 3. LOGGING_STREAK_EXTENDED at a non-checkpoint length is ineligible
    decision3 = elig.check_eligibility(db, "u1", {"eventId": "x2", "event": "LOGGING_STREAK_EXTENDED", "payload": {"from": 4, "to": 5}})
    check(
        "LOGGING_STREAK_EXTENDED at a non-checkpoint length (5) is ineligible",
        decision3["eligible"] is False,
        f"got {decision3}",
    )

    # 4. LOGGING_STREAK_EXTENDED at a checkpoint length (7) is eligible
    decision4 = elig.check_eligibility(db, "u1", {"eventId": "x3", "event": "LOGGING_STREAK_EXTENDED", "payload": {"from": 6, "to": 7}})
    check(
        "LOGGING_STREAK_EXTENDED at a checkpoint length (7) is eligible",
        decision4["eligible"] is True,
        f"got {decision4}",
    )

    # 5. LOGGING_STREAK_BROKEN below the minimum mourned length is ineligible
    decision5 = elig.check_eligibility(db, "u1", {"eventId": "x4", "event": "LOGGING_STREAK_BROKEN", "payload": {"from": 1, "to": 0}})
    check(
        "LOGGING_STREAK_BROKEN for a 1-day streak is ineligible (too short to mourn)",
        decision5["eligible"] is False,
        f"got {decision5}",
    )
    decision5b = elig.check_eligibility(db, "u1", {"eventId": "x5", "event": "LOGGING_STREAK_BROKEN", "payload": {"from": 5, "to": 0}})
    check(
        "LOGGING_STREAK_BROKEN for a 5-day streak is eligible",
        decision5b["eligible"] is True,
        f"got {decision5b}",
    )

    # 6. Already Informed: an event whose eventId already has a notification is ineligible
    repo.save(db, "u1", {
        "eventId": "u1:2026-07-19:health_worsened", "eventCode": "HEALTH_WORSENED", "priority": "High",
        "frequency": "DAILY", "timing": "IMMEDIATE", "interruptionLevel": None, "templateId": "T",
        "title": "t", "body": "b", "cta": "c", "payload": {}, "deepLink": None, "status": "Created",
    })
    decision6 = elig.check_eligibility(db, "u1", event1)
    check(
        "An event whose notification already exists is ineligible (Already Informed)",
        decision6["eligible"] is False and "already informed" in decision6["reason"],
        f"got {decision6}",
    )

    # 7. Frequency (ONCE): a second RECOVERY_STARTED for the same user is ineligible,
    # even with a brand-new eventId, because the policy is ONCE per user
    repo.save(db, "u2", {
        "eventId": "u2:2026-07-01:recovery_started", "eventCode": "RECOVERY_STARTED", "priority": "High",
        "frequency": "ONCE", "timing": "IMMEDIATE", "interruptionLevel": None, "templateId": "T",
        "title": "t", "body": "b", "cta": "c", "payload": {}, "deepLink": None, "status": "Created",
    })
    decision7 = elig.check_eligibility(db, "u2", {"eventId": "u2:2026-08-01:recovery_started", "event": "RECOVERY_STARTED", "payload": {}})
    check(
        "A second RECOVERY_STARTED (ONCE policy) is ineligible even with a new eventId",
        decision7["eligible"] is False and "frequency policy" in decision7["reason"],
        f"got {decision7}",
    )

    # 8. process_event on an eligible event creates and returns a real notification
    result8 = elig.process_event(db, "u3", {"eventId": "u3:2026-07-19:milestone_unlocked:FIRST_HEALTHY_WEEK", "event": "MILESTONE_UNLOCKED", "payload": {"code": "FIRST_HEALTHY_WEEK"}})
    check(
        "process_event on an eligible event creates and returns a real notification",
        result8 is not None and result8.get("eventCode") == "MILESTONE_UNLOCKED" and result8.get("status") == "Created",
        f"got {result8}",
    )
    check(
        "The notification created by process_event is actually persisted in the Repository",
        repo.get(db, "u3", "u3:2026-07-19:milestone_unlocked:FIRST_HEALTHY_WEEK") is not None,
    )

    # 9. process_event on an ineligible event returns the rejection, creates nothing
    result9 = elig.process_event(db, "u3", {"eventId": "u3:2026-07-19:logging_streak_extended", "event": "LOGGING_STREAK_EXTENDED", "payload": {"from": 4, "to": 5}})
    check(
        "process_event on an ineligible event returns the rejection reason",
        result9 == {"eligible": False, "reason": result9.get("reason")} and result9["eligible"] is False,
        f"got {result9}",
    )
    check(
        "No notification is created in the Repository for a rejected event",
        repo.get(db, "u3", "u3:2026-07-19:logging_streak_extended") is None,
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Eligibility Engine scenarios passed.")


if __name__ == "__main__":
    run()
