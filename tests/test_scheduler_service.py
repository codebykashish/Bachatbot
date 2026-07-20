"""
test_scheduler_service.py
===========================
Step 11.3 acceptance scenarios for the Daily Snapshot Scheduler — see
FINANCIAL_ENGINE_SPEC.md's "Step 11.0" through "Step 11.2" for the
frozen contract. Pure orchestration tests: process_day() is monkey-
patched to canned results so these tests exercise catch-up range
determination, per-user/per-day isolation, aggregation, and the
skip-not-truncate policy — not the full five-engine gather path, which
is verified separately against the real account.

Run directly: python tests/test_scheduler_service.py
"""

import sys
import os
from datetime import date, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import scheduler_service as sched
from services import diff_generator
from services import eligibility_engine

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fake Firestore -- just enough for get_active_users() and
# _get_last_snapshot_date()'s order_by/limit query ─────────────────────

class FakeSnapshot:
    def __init__(self, data, doc_id=None):
        self._data = data
        self.id = doc_id

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class FakeDocRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return FakeSnapshot(self._store.get(self._key), doc_id=self._key.split("/")[-1])

    def set(self, data, merge=False):
        if merge and self._key in self._store:
            merged = dict(self._store[self._key])
            merged.update(data)
            self._store[self._key] = merged
        else:
            self._store[self._key] = dict(data)


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
            FakeSnapshot(v, doc_id=k.split("/")[-1])
            for k, v in self._store.items()
            if k.startswith(self._prefix + "/") and k.count("/") == self._prefix.count("/") + 1
        ]
        if self._order_field:
            docs.sort(key=lambda d: d.to_dict()[self._order_field], reverse=self._descending)
        if self._limit_n is not None:
            docs = docs[: self._limit_n]
        return docs


class FakeCollectionRef:
    def __init__(self, store, prefix):
        self._store = store
        self._prefix = prefix

    def document(self, doc_id):
        return FakeDocRef(self._store, f"{self._prefix}/{doc_id}")

    def order_by(self, field, direction="ASCENDING"):
        return FakeQuery(self._store, self._prefix, field, direction == "DESCENDING")

    def stream(self):
        return FakeQuery(self._store, self._prefix).stream()


class FakeUserDocRef:
    def __init__(self, store, uid):
        self._store = store
        self._uid = uid

    def collection(self, name):
        return FakeCollectionRef(self._store, f"users/{self._uid}/{name}")


class FakeDB:
    def __init__(self):
        self._store = {}

    def collection(self, name):
        assert name == "users"
        return _UsersCollection(self._store)


class _UsersCollection:
    def __init__(self, store):
        self._store = store

    def document(self, uid):
        return FakeUserDocRef(self._store, uid)

    def stream(self):
        # Users live as bare keys "users/{uid}" with any placeholder value.
        return [
            FakeSnapshot(v, doc_id=k.split("/")[-1])
            for k, v in self._store.items()
            if k.startswith("users/") and k.count("/") == 1
        ]


def _seed_user(db, uid):
    db._store[f"users/{uid}"] = {"placeholder": True}


def _seed_snapshot(db, uid, snapshot_date):
    db._store[f"users/{uid}/dailySnapshots/{snapshot_date}"] = {"snapshotDate": snapshot_date}


def run():
    print("Scheduler Service — test matrix")

    # 1. get_active_users returns every seeded user
    db = FakeDB()
    _seed_user(db, "u1")
    _seed_user(db, "u2")
    check(
        "get_active_users returns every user in the users collection",
        set(sched.get_active_users(db)) == {"u1", "u2"},
        f"got {sched.get_active_users(db)}",
    )

    # 2. No prior snapshot -> catch-up range collapses to just today
    db2 = FakeDB()
    today = date(2026, 7, 19)
    dates, reason = sched._catch_up_range(db2, "u1", today)
    check(
        "A user with no prior snapshot has a catch-up range of exactly [today]",
        dates == [today] and reason is None,
        f"got dates={dates}, reason={reason}",
    )

    # 3. Last snapshot exists -> range starts from that day itself, not the day after
    db3 = FakeDB()
    _seed_snapshot(db3, "u1", "2026-07-17")
    dates3, reason3 = sched._catch_up_range(db3, "u1", date(2026, 7, 19))
    check(
        "Catch-up range starts from the last snapshot's own date (re-verified), through today",
        dates3 == [date(2026, 7, 17), date(2026, 7, 18), date(2026, 7, 19)] and reason3 is None,
        f"got dates={dates3}, reason={reason3}",
    )

    # 4. Gap exceeding MAX_CATCHUP_DAYS -> skipped, not truncated
    db4 = FakeDB()
    old_date = (date(2026, 7, 19) - timedelta(days=sched.MAX_CATCHUP_DAYS + 5)).isoformat()
    _seed_snapshot(db4, "u1", old_date)
    dates4, reason4 = sched._catch_up_range(db4, "u1", date(2026, 7, 19))
    check(
        "A gap exceeding MAX_CATCHUP_DAYS returns an empty range with a reason, never a partial catch-up",
        dates4 == [] and reason4 is not None,
        f"got dates={dates4}, reason={reason4}",
    )

    # 5. process_user aggregates per-day stats correctly (process_day monkeypatched)
    db5 = FakeDB()
    _seed_snapshot(db5, "u1", "2026-07-17")

    call_log = []

    def fake_process_day(db, uid, d, dry_run=False):
        call_log.append(d)
        return {"date": d.isoformat(), "snapshotCreated": True, "eventsGenerated": 2, "notificationsCreated": 0, "success": True, "error": None}

    original = sched.process_day
    sched.process_day = fake_process_day
    try:
        result = sched.process_user(db5, "u1", date(2026, 7, 19))
    finally:
        sched.process_day = original

    check(
        "process_user calls process_day once per day in the catch-up range, in order",
        call_log == [date(2026, 7, 17), date(2026, 7, 18), date(2026, 7, 19)],
        f"got {call_log}",
    )
    check(
        "process_user aggregates snapshotsCreated/eventsGenerated across all days",
        result["snapshotsCreated"] == 3 and result["eventsGenerated"] == 6 and result["success"] is True,
        f"got {result}",
    )

    # 6. A skipped user (gap too large) never calls process_day at all
    db6 = FakeDB()
    _seed_snapshot(db6, "u1", old_date)
    call_log6 = []
    sched.process_day = lambda *a, **k: call_log6.append(1) or {}
    try:
        result6 = sched.process_user(db6, "u1", date(2026, 7, 19))
    finally:
        sched.process_day = original
    check(
        "A skipped user (gap too large) never calls process_day",
        call_log6 == [] and result6["skipped"] is True and result6["success"] is False,
        f"got {result6}, calls={call_log6}",
    )

    # 7. One failing day does not stop later days for the same user
    def flaky_process_day(db, uid, d, dry_run=False):
        if d == date(2026, 7, 18):
            return {"date": d.isoformat(), "snapshotCreated": False, "eventsGenerated": 0, "notificationsCreated": 0, "success": False, "error": "boom"}
        return {"date": d.isoformat(), "snapshotCreated": True, "eventsGenerated": 1, "notificationsCreated": 0, "success": True, "error": None}

    db7 = FakeDB()
    _seed_snapshot(db7, "u1", "2026-07-17")
    sched.process_day = flaky_process_day
    try:
        result7 = sched.process_user(db7, "u1", date(2026, 7, 19))
    finally:
        sched.process_day = original
    check(
        "A failing day is recorded but does not prevent later days for the same user from being attempted",
        result7["daysProcessed"] == 3 and result7["success"] is False
        and result7["days"][2]["success"] is True,
        f"got {result7}",
    )

    # 8. run_daily_snapshot_job: one user failing entirely never stops another user
    def failing_process_user(db, uid, today, dry_run=False):
        if uid == "bad_user":
            raise RuntimeError("simulated total failure")
        return {"uid": uid, "success": True, "skipped": False, "reason": None,
                "daysProcessed": 1, "snapshotsCreated": 1, "eventsGenerated": 0, "notificationsCreated": 0, "days": []}

    db8 = FakeDB()
    _seed_user(db8, "bad_user")
    _seed_user(db8, "good_user")
    original_process_user = sched.process_user
    sched.process_user = failing_process_user
    try:
        summary = sched.run_daily_snapshot_job(db8, today=date(2026, 7, 19))
    finally:
        sched.process_user = original_process_user
    check(
        "run_daily_snapshot_job isolates one user's total failure from another user",
        summary["usersProcessed"] == 2 and summary["usersSucceeded"] == 1 and summary["usersFailed"] == 1,
        f"got {summary}",
    )

    # 9. persist_events upserts by eventId
    db9 = FakeDB()
    events = [{"eventId": "u1:2026-07-19:health_worsened", "event": "HEALTH_WORSENED", "payload": {}}]
    sched.persist_events(db9, "u1", events)
    stored = db9._store.get("users/u1/events/u1:2026-07-19:health_worsened")
    check(
        "persist_events writes each event under its own eventId as the document ID",
        stored == events[0],
        f"got {stored}",
    )
    # Calling again with the same event is a safe no-op overwrite, not a duplicate
    sched.persist_events(db9, "u1", events)
    check(
        "Persisting the same event twice does not create a duplicate document",
        len([k for k in db9._store if k.startswith("users/u1/events/")]) == 1,
        f"got {[k for k in db9._store if k.startswith('users/u1/events/')]}",
    )

    # 10. process_day's own notification-pipeline wiring (spec 5.9's review
    # found this missing entirely): each generated event is offered to
    # eligibility_engine.process_event, and notificationsCreated reflects
    # exactly the eligible ones -- both snapshots pre-seeded as already
    # existing so process_day skips the five-engine gather step entirely
    # and goes straight to the diff/notification step being tested here.
    db10 = FakeDB()
    _seed_snapshot(db10, "u1", "2026-07-18")
    _seed_snapshot(db10, "u1", "2026-07-19")

    original_generate_events = diff_generator.generate_events
    original_process_event = eligibility_engine.process_event
    diff_generator.generate_events = lambda uid, prev, curr, milestones: [
        {"eventId": "e1", "event": "HEALTH_WORSENED", "payload": {}},
        {"eventId": "e2", "event": "LOGGING_STREAK_EXTENDED", "payload": {"to": 5}},
    ]
    eligibility_engine.process_event = lambda db, uid, event: (
        {"eventCode": event["event"], "status": "Created"} if event["eventId"] == "e1"
        else {"eligible": False, "reason": "not a checkpoint"}
    )
    try:
        day_result = sched.process_day(db10, "u1", date(2026, 7, 19))
    finally:
        diff_generator.generate_events = original_generate_events
        eligibility_engine.process_event = original_process_event
    check(
        "process_day counts notificationsCreated only for events eligibility_engine actually turned into notifications",
        day_result["eventsGenerated"] == 2 and day_result["notificationsCreated"] == 1 and day_result["success"] is True,
        f"got {day_result}",
    )

    # 11. A single event's notification-pipeline failure is isolated -- it
    # never fails the whole day, and other events are still processed
    db11 = FakeDB()
    _seed_snapshot(db11, "u1", "2026-07-18")
    _seed_snapshot(db11, "u1", "2026-07-19")

    calls11 = []

    def flaky_process_event(db, uid, event):
        calls11.append(event["eventId"])
        if event["eventId"] == "e1":
            raise RuntimeError("simulated notification pipeline failure")
        return {"eventCode": event["event"], "status": "Created"}

    diff_generator.generate_events = lambda uid, prev, curr, milestones: [
        {"eventId": "e1", "event": "HEALTH_WORSENED", "payload": {}},
        {"eventId": "e2", "event": "MILESTONE_UNLOCKED", "payload": {"code": "X"}},
    ]
    eligibility_engine.process_event = flaky_process_event
    try:
        day_result11 = sched.process_day(db11, "u1", date(2026, 7, 19))
    finally:
        diff_generator.generate_events = original_generate_events
        eligibility_engine.process_event = original_process_event
    check(
        "A notification-pipeline exception for one event never fails process_day's overall success",
        day_result11["success"] is True and day_result11["eventsGenerated"] == 2,
        f"got {day_result11}",
    )
    check(
        "A notification-pipeline exception for one event does not stop the next event from being attempted",
        calls11 == ["e1", "e2"],
        f"got {calls11}",
    )
    check(
        "Only the successfully-processed event counts toward notificationsCreated, despite the other's exception",
        day_result11["notificationsCreated"] == 1,
        f"got {day_result11}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Scheduler Service scenarios passed.")


if __name__ == "__main__":
    run()
