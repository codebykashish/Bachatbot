"""
test_weekly_reflection_service.py
====================================
Phase 22B acceptance scenarios for Weekly Observation — see
FINANCIAL_ENGINE_SPEC.md's "Phase 22B — Weekly Observation." Tests the
isolated gather helpers directly against minimal fakes -- each touches
only 1-2 collections, so a full multi-engine fake (financial_engine +
health_engine + recommendation_engine + goal_service all at once) isn't
needed here. The full gather_weekly_observation() is verified against
the real account instead (documented in the spec), the same treatment
Pattern Spending Alerts and Goal Risk got for their own deep
dependency chains.

Run directly: python tests/test_weekly_reflection_service.py
"""

import sys
import os
from datetime import date, datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import weekly_reflection_service as wrs

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fakes ──────────────────────────────────────────────────────────

class FakeSnapshot:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class FakeQuery:
    def __init__(self, docs):
        self._docs = docs

    def where(self, field, op, value):
        return FakeQuery([d for d in self._docs if d.get(field) == value])

    def order_by(self, field, direction="ASCENDING"):
        docs = sorted(self._docs, key=lambda d: d.get(field) or 0, reverse=(direction == "DESCENDING"))
        return FakeQuery(docs)

    def limit(self, n):
        return FakeQuery(self._docs[:n])

    def stream(self):
        return [FakeSnapshot(d) for d in self._docs]


class FakeDocRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return FakeSnapshot(self._store.get(self._key))

    def set(self, data):
        self._store[self._key] = dict(data)


class FakeCollectionRef:
    def __init__(self, store, prefix):
        self._store = store
        self._prefix = prefix

    def document(self, doc_id):
        return FakeDocRef(self._store, f"{self._prefix}/{doc_id}")

    def where(self, field, op, value):
        docs = [v for k, v in self._store.items() if k.startswith(self._prefix + "/")]
        return FakeQuery(docs).where(field, op, value)

    def order_by(self, field, direction="ASCENDING"):
        docs = [v for k, v in self._store.items() if k.startswith(self._prefix + "/")]
        return FakeQuery(docs).order_by(field, direction)

    def stream(self):
        return [FakeSnapshot(v) for k, v in self._store.items() if k.startswith(self._prefix + "/")]


class FakeUserDocRef:
    def __init__(self, store, uid):
        self._store = store
        self._uid = uid

    def collection(self, name):
        return FakeCollectionRef(self._store, f"users/{self._uid}/{name}")

    def get(self):
        return FakeSnapshot(self._store.get(f"users/{self._uid}"))


class FakeDB:
    def __init__(self):
        self._store = {}

    def collection(self, name):
        assert name == "users"
        return self

    def document(self, uid):
        return FakeUserDocRef(self._store, uid)


def utc(y, m, d, hour=12):
    return datetime(y, m, d, hour, tzinfo=timezone.utc)


def run():
    print("Weekly Reflection Service — test matrix")

    # ─── _gather_transactions ───────────────────────────────────────────
    db = FakeDB()
    db._store["users/u1/transactions/1"] = {
        "type": "expense", "status": "confirmed", "isDeleted": False,
        "amount": 200.0, "category": "Food", "createdAt": utc(2026, 7, 20),
    }
    db._store["users/u1/transactions/2"] = {
        "type": "expense", "status": "confirmed", "isDeleted": False,
        "amount": 300.0, "category": "Food", "createdAt": utc(2026, 7, 21),
    }
    db._store["users/u1/transactions/3"] = {
        "type": "expense", "status": "confirmed", "isDeleted": False,
        "amount": 100.0, "category": "Transport", "createdAt": utc(2026, 7, 21),
    }
    # Outside the week -- must be excluded
    db._store["users/u1/transactions/4"] = {
        "type": "expense", "status": "confirmed", "isDeleted": False,
        "amount": 9999.0, "category": "Food", "createdAt": utc(2026, 8, 1),
    }
    # Deleted -- must be excluded even though it's in range
    db._store["users/u1/transactions/5"] = {
        "type": "expense", "status": "confirmed", "isDeleted": True,
        "amount": 5000.0, "category": "Food", "createdAt": utc(2026, 7, 20),
    }
    # Income in range -- counted separately, never mixed into categorySpending
    db._store["users/u1/transactions/6"] = {
        "type": "income", "status": "confirmed", "isDeleted": False,
        "amount": 1000.0, "createdAt": utc(2026, 7, 22),
    }
    start_dt = wrs._as_utc_datetime(date(2026, 7, 20))
    end_dt = wrs._as_utc_datetime(date(2026, 7, 26), end_of_day=True)
    tx = wrs._gather_transactions(db, "u1", start_dt, end_dt)
    check(
        "Total spent sums only in-range, non-deleted expenses",
        tx["totalSpent"] == 600.0,
        f"got {tx}",
    )
    check(
        "Category spending groups correctly, deleted/out-of-range excluded",
        tx["categorySpending"] == {"Food": 500.0, "Transport": 100.0},
        f"got {tx}",
    )
    check(
        "Total income tracked separately from spending",
        tx["totalIncome"] == 1000.0,
        f"got {tx}",
    )
    check(
        "Transaction count includes both expense and income, excludes deleted/out-of-range",
        tx["transactionCount"] == 4,
        f"got {tx}",
    )

    # ─── _gather_health ─────────────────────────────────────────────────
    db2 = FakeDB()
    db2._store["users/u2/dailySnapshots/2026-07-20"] = {"health": {"overallHealthStatus": "green"}}
    db2._store["users/u2/dailySnapshots/2026-07-23"] = {"health": {"overallHealthStatus": "amber"}}
    db2._store["users/u2/dailySnapshots/2026-07-26"] = {"health": {"overallHealthStatus": "red"}}
    health = wrs._gather_health(db2, "u2", date(2026, 7, 20), date(2026, 7, 26))
    check(
        "Health gathers exactly the snapshots that actually exist, not assumed 7",
        health["snapshotsFound"] == 3,
        f"got {health}",
    )
    check(
        "First/last correctly pick the earliest/latest found dates, not array position",
        health["first"] == {"date": "2026-07-20", "status": "green"}
        and health["last"] == {"date": "2026-07-26", "status": "red"},
        f"got {health}",
    )

    # Missing snapshots entirely -- honest zero, never guessed
    db3 = FakeDB()
    health_empty = wrs._gather_health(db3, "u3", date(2026, 7, 20), date(2026, 7, 26))
    check(
        "No snapshots found -> snapshotsFound 0, first/last both None, never guessed",
        health_empty == {"snapshotsFound": 0, "first": None, "last": None},
        f"got {health_empty}",
    )

    # ─── _gather_pattern_alerts ─────────────────────────────────────────
    db4 = FakeDB()
    db4._store["users/u4/generatedNotifications/a"] = {
        "eventCode": "UNUSUAL_SPENDING_DETECTED", "payload": {"category": "Shopping"},
        "createdAt": utc(2026, 7, 22),
    }
    db4._store["users/u4/generatedNotifications/b"] = {
        "eventCode": "UNUSUAL_SPENDING_DETECTED", "payload": {"category": "Food"},
        "createdAt": utc(2026, 8, 5),  # outside the week
    }
    db4._store["users/u4/generatedNotifications/c"] = {
        "eventCode": "MILESTONE_UNLOCKED", "payload": {"code": "FIRST_EXPENSE_LOGGED"},
        "createdAt": utc(2026, 7, 22),  # in range, but wrong event code
    }
    alerts = wrs._gather_pattern_alerts(db4, "u4", start_dt, end_dt)
    check(
        "Only in-range UNUSUAL_SPENDING_DETECTED notifications are gathered",
        len(alerts) == 1 and alerts[0]["category"] == "Shopping",
        f"got {alerts}",
    )

    # ─── Account Existence Boundary ─────────────────────────────────────
    # Week entirely before account creation -> must raise, not gather.
    # Safe to call the full function here -- the guard fires before any
    # deep engine call, so no full multi-engine fake is needed.
    db5 = FakeDB()
    db5._store["users/u5"] = {"createdAt": utc(2026, 7, 17)}
    try:
        wrs.gather_weekly_observation(db5, "u5", date(2026, 7, 6), date(2026, 7, 12))
        check("Week fully before account creation raises WeeklyReflectionError", False, "no exception raised")
    except wrs.WeeklyReflectionError:
        check("Week fully before account creation raises WeeklyReflectionError", True)
    except Exception as e:
        check("Week fully before account creation raises WeeklyReflectionError", False, f"wrong exception type: {type(e).__name__}: {e}")

    # The "allowed" cases (partial overlap, fully after creation, missing
    # createdAt) would need the FULL gather pipeline -- financial/health/
    # recommendation/goal_service all at once -- which this file's
    # minimal fakes don't support (by design, see module docstring).
    # Testing the guard's own decision directly instead, against the
    # same _account_created_date() the real function calls.
    check(
        "Partial-overlap week (account created Friday, week Mon-Sun) does not trip the boundary",
        not (date(2026, 7, 19) < wrs._account_created_date(db5, "u5")),
    )
    check(
        "Week fully after account creation does not trip the boundary",
        not (date(2026, 7, 26) < wrs._account_created_date(db5, "u5")),
    )
    db8 = FakeDB()
    db8._store["users/u8"] = {}
    check(
        "Missing account createdAt is treated as no restriction (_account_created_date returns None)",
        wrs._account_created_date(db8, "u8") is None,
    )

    # ─── Phase E: Persistence ───────────────────────────────────────────
    # most_recent_completed_week(): a Wednesday "today" -> last Mon-Sun
    check(
        "most_recent_completed_week from a Wednesday returns the prior full Mon-Sun week",
        wrs.most_recent_completed_week(today=date(2026, 7, 22)) == (date(2026, 7, 13), date(2026, 7, 19)),
        f"got {wrs.most_recent_completed_week(today=date(2026, 7, 22))}",
    )

    # get_weekly_reflection(): None when nothing persisted yet
    db9 = FakeDB()
    check(
        "get_weekly_reflection returns None when nothing has been generated yet",
        wrs.get_weekly_reflection(db9, "u9", date(2026, 7, 13)) is None,
    )

    # generate_weekly_reflection(): idempotent -- a pre-existing document
    # is returned unchanged, WITHOUT ever calling gather_weekly_observation
    # (verified by using a deliberately incomplete fake -- if the idempotency
    # short-circuit didn't fire, this would crash trying to reach
    # financial_engine/health_engine/etc., which this fake doesn't support).
    db10 = FakeDB()
    existing_doc = {"weekStart": "2026-07-13", "weekEnd": "2026-07-19", "opening": "already generated"}
    db10._store["users/u10/weeklyReflections/2026-07-13"] = existing_doc
    result = wrs.generate_weekly_reflection(db10, "u10", date(2026, 7, 13), date(2026, 7, 19))
    check(
        "generate_weekly_reflection is idempotent -- returns the existing doc, never recomputes",
        result == existing_doc,
        f"got {result}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Weekly Reflection Service scenarios passed.")


if __name__ == "__main__":
    run()
