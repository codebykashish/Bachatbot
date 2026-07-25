"""
test_behavior_engine.py
========================
Phase 4.5.1 acceptance scenarios for Logging Behavior — see
FINANCIAL_ENGINE_SPEC.md's "4.5.1 — Logging Behavior," specifically the
"Required tests before freezing 4.5.1" list this file exists to satisfy.
Pure logic tests against a minimal fake Firestore client (no real
project needed) — mirrors the fake used in
test_behavior_state_repository.py.

Run directly: python tests/test_behavior_engine.py
"""

import sys
import os
from datetime import datetime, timezone, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import behavior_engine as engine
from services import behavior_state_repository as repo

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fake Firestore — same shape as test_behavior_state_repository.py ───

class FakeSnapshot:
    def __init__(self, data):
        self._data = data

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
        return FakeSnapshot(self._store.get(self._key))

    def set(self, data, merge=False):
        from google.cloud.firestore_v1 import ArrayUnion

        if merge:
            merged = dict(self._store.get(self._key, {}))
            for k, v in data.items():
                if isinstance(v, ArrayUnion):
                    merged[k] = merged.get(k, []) + [x for x in v.values if x not in merged.get(k, [])]
                else:
                    merged[k] = v
            self._store[self._key] = merged
        else:
            self._store[self._key] = dict(data)

    def update(self, patch):
        current = dict(self._store[self._key])
        for key, value in patch.items():
            head, _, tail = key.partition(".")
            if tail:
                current.setdefault(head, {})[tail] = value
            else:
                current[key] = value
        self._store[self._key] = current


class FakeCollectionRef:
    def __init__(self, store, prefix):
        self._store = store
        self._prefix = prefix

    def document(self, doc_id):
        return FakeDocRef(self._store, f"{self._prefix}/{doc_id}")


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


def utc(y, m, d, h=10, mi=0):
    return datetime(y, m, d, h, mi, tzinfo=timezone.utc)


def run():
    print("Behavior Engine — Logging Behavior test matrix")

    # 1. First transaction ever -> initialization
    db = FakeDB()
    uid = "u1"
    result = engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 1))
    check(
        "First transaction ever initializes streak to 1",
        result["currentStreak"] == 1 and result["bestStreak"] == 1
        and result["streakStartedOn"] == "2026-07-01" and result["lastLoggedDate"] == "2026-07-01",
        f"got {result}",
    )

    # 2. Second transaction, same day -> no-op
    result2 = engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 1, 18))
    check(
        "Second transaction same day does not increment streak",
        result2["currentStreak"] == 1,
        f"got {result2}",
    )

    # 3. Consecutive days -> streak continues
    result3 = engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 2))
    check(
        "Consecutive day extends streak to 2",
        result3["currentStreak"] == 2 and result3["bestStreak"] == 2,
        f"got {result3}",
    )

    # 4. One missed day -> streak resets to 1 (July 3 missed, next action July 4)
    result4 = engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 4))
    check(
        "One missed day resets streak to 1, not 3",
        result4["currentStreak"] == 1,
        f"got {result4}",
    )
    check(
        "Best streak is preserved across a broken streak",
        result4["bestStreak"] == 2,
        f"got {result4}",
    )

    # 5. Two missed days -> streak still resets to 1, not further penalized
    result5 = engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 7))
    check(
        "Two missed days also resets streak to 1 (not negative, not extra-penalized)",
        result5["currentStreak"] == 1,
        f"got {result5}",
    )

    # 6. Edit transaction -> no effect
    before_edit = engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 8))
    after_edit = engine.record_logging_activity(db, uid, "TRANSACTION_EDITED", utc(2026, 7, 8, 12))
    check(
        "TRANSACTION_EDITED does not change logging state",
        after_edit == before_edit,
        f"got {after_edit} vs {before_edit}",
    )

    # 7. Delete transaction -> no effect
    after_delete = engine.record_logging_activity(db, uid, "TRANSACTION_DELETED", utc(2026, 7, 8, 13))
    check(
        "TRANSACTION_DELETED does not change logging state",
        after_delete == before_edit,
        f"got {after_delete}",
    )

    # 8. Undo transaction -> no dedicated reason code; covered by TRANSACTION_DELETED
    after_undo = engine.record_logging_activity(db, uid, "TRANSACTION_DELETED", utc(2026, 7, 8, 14))
    check(
        "\"Undo\" (modeled as TRANSACTION_DELETED, no separate reason exists) does not change logging state",
        after_undo == before_edit,
        f"got {after_undo}",
    )

    # 9. Notification confirmation -> counts
    db2 = FakeDB()
    r = engine.record_logging_activity(db2, "u2", "TRANSACTION_CONFIRMED", utc(2026, 7, 1))
    check(
        "TRANSACTION_CONFIRMED (notification confirmation) counts as logged",
        r["currentStreak"] == 1,
        f"got {r}",
    )

    # 10. Chat transaction -> counts (chat routes use TRANSACTION_CREATED)
    db3 = FakeDB()
    r = engine.record_logging_activity(db3, "u3", "TRANSACTION_CREATED", utc(2026, 7, 1))
    check(
        "Chat transaction (TRANSACTION_CREATED) counts as logged",
        r["currentStreak"] == 1,
        f"got {r}",
    )

    # 11. Manual transaction -> counts (same trigger, routes/transactions.py)
    db4 = FakeDB()
    r = engine.record_logging_activity(db4, "u4", "TRANSACTION_CREATED", utc(2026, 7, 1))
    check(
        "Manual transaction (TRANSACTION_CREATED) counts as logged",
        r["currentStreak"] == 1,
        f"got {r}",
    )

    # 12. Income transaction -> counts identically; the engine has no
    # expense/income distinction in its signature, by design (spec:
    # "does only income count? No").
    db5 = FakeDB()
    r = engine.record_logging_activity(db5, "u5", "TRANSACTION_CREATED", utc(2026, 7, 1))
    check(
        "Income transaction counts identically to expense (no type param exists to discriminate)",
        r["currentStreak"] == 1,
        f"got {r}",
    )

    # 13. Timezone boundary — LOGGING_TIMEZONE is UTC+5:45; a UTC timestamp
    # late in the UTC day can already be the *next* calendar day in Kathmandu.
    db6 = FakeDB()
    uid6 = "u6"
    r1 = engine.record_logging_activity(db6, uid6, "TRANSACTION_CREATED", utc(2026, 7, 19, 10, 0))
    # 2026-07-19T19:00:00Z -> Kathmandu 2026-07-20T00:45 -- next KTM day,
    # same UTC calendar day.
    r2 = engine.record_logging_activity(db6, uid6, "TRANSACTION_CREATED", utc(2026, 7, 19, 19, 0))
    check(
        "A late-UTC-day timestamp that is already the next Kathmandu day extends the streak",
        r1["currentStreak"] == 1 and r2["currentStreak"] == 2,
        f"got r1={r1}, r2={r2}",
    )

    # 14. Multiple transactions same day -> streak updates exactly once,
    # regardless of transaction count (Food 100, Food 50, Transport 40 example).
    db7 = FakeDB()
    uid7 = "u7"
    engine.record_logging_activity(db7, uid7, "TRANSACTION_CREATED", utc(2026, 7, 1, 9, 0))
    engine.record_logging_activity(db7, uid7, "TRANSACTION_CREATED", utc(2026, 7, 1, 9, 5))
    final = engine.record_logging_activity(db7, uid7, "TRANSACTION_CREATED", utc(2026, 7, 1, 9, 10))
    check(
        "Three qualifying transactions in one day update the streak exactly once",
        final["currentStreak"] == 1,
        f"got {final}",
    )


def run_spending():
    print("Behavior Engine — Spending Behavior test matrix")

    # 1. First evaluation ever, healthy -> streak becomes 1
    db = FakeDB()
    uid = "s1"
    r1 = engine.record_spending_activity(db, uid, "green", "2026-07-01")
    check(
        "First evaluation ever (healthy) initializes healthy streak to 1",
        r1["currentHealthyStreak"] == 1 and r1["bestHealthyStreak"] == 1
        and r1["currentOverspendingStreak"] == 0 and r1["lastHealthyDate"] == "2026-07-01",
        f"got {r1}",
    )

    # 2. Consecutive healthy days -> streak continues
    r2 = engine.record_spending_activity(db, uid, "amber", "2026-07-02")
    check(
        "Amber counts as healthy (only Red breaks it); consecutive day extends streak to 2",
        r2["currentHealthyStreak"] == 2 and r2["bestHealthyStreak"] == 2,
        f"got {r2}",
    )

    # 3. Red day breaks the healthy streak immediately, overspend streak starts at 1
    r3 = engine.record_spending_activity(db, uid, "red", "2026-07-03")
    check(
        "A Red day breaks the healthy streak to 0 and starts overspending streak at 1",
        r3["currentHealthyStreak"] == 0 and r3["currentOverspendingStreak"] == 1,
        f"got {r3}",
    )
    check(
        "Best healthy streak is preserved across the break",
        r3["bestHealthyStreak"] == 2,
        f"got {r3}",
    )
    check(
        "lastHealthyDate is not touched on an unhealthy day",
        r3["lastHealthyDate"] == "2026-07-02",
        f"got {r3}",
    )

    # 4. Consecutive Red days -> overspending streak continues
    r4 = engine.record_spending_activity(db, uid, "red", "2026-07-04")
    check(
        "Consecutive Red day extends overspending streak to 2",
        r4["currentOverspendingStreak"] == 2 and r4["currentHealthyStreak"] == 0,
        f"got {r4}",
    )

    # 5. Switching back to healthy the very next day restarts the healthy
    # streak at 1 -- it does not inherit anything from the overspending run.
    r5 = engine.record_spending_activity(db, uid, "green", "2026-07-05")
    check(
        "Switching from unhealthy to healthy restarts the healthy streak at 1, not carried over",
        r5["currentHealthyStreak"] == 1 and r5["currentOverspendingStreak"] == 0,
        f"got {r5}",
    )

    # 6. Gap in scheduler evaluation (missed 07-06, next eval is 07-08) ->
    # streak resets to 1 regardless of what it was before the gap.
    r6 = engine.record_spending_activity(db, uid, "green", "2026-07-08")
    check(
        "A scheduler gap (evaluation skips a day) resets the healthy streak to 1, not continued",
        r6["currentHealthyStreak"] == 1,
        f"got {r6}",
    )

    # 7. Idempotency -- evaluating the same snapshot_date twice is a no-op
    r7a = engine.record_spending_activity(db, uid, "green", "2026-07-09")
    r7b = engine.record_spending_activity(db, uid, "red", "2026-07-09")
    check(
        "Re-evaluating the same snapshot_date is a no-op, even with a different status passed",
        r7a == r7b,
        f"got r7a={r7a}, r7b={r7b}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Behavior Engine (Spending Behavior) scenarios passed.")


def run_saving():
    print("Behavior Engine — Saving Behavior test matrix")

    # 1. First month ever, positive Actual Savings -> streak becomes 1
    db = FakeDB()
    uid = "m1"
    r1 = engine.record_saving_activity(db, uid, "2026-05", 23000)
    check(
        "First month ever with positive Actual Savings initializes protection streak to 1",
        r1["currentProtectionStreak"] == 1 and r1["bestProtectionStreak"] == 1
        and r1["lastMonthKeyEvaluated"] == "2026-05",
        f"got {r1}",
    )

    # 2. Consecutive month, also positive -> streak continues
    r2 = engine.record_saving_activity(db, uid, "2026-06", 9000)
    check(
        "Consecutive successful month extends protection streak to 2 (9,000 still counts, not compared to 23,000)",
        r2["currentProtectionStreak"] == 2 and r2["bestProtectionStreak"] == 2,
        f"got {r2}",
    )

    # 3. Exactly zero Actual Savings -> NOT successful (frozen: strictly positive, not non-negative)
    r3 = engine.record_saving_activity(db, uid, "2026-07", 0)
    check(
        "Exactly zero Actual Savings breaks the streak -- the rule is strictly positive, not non-negative",
        r3["currentProtectionStreak"] == 0,
        f"got {r3}",
    )
    check(
        "Best protection streak is preserved across the break",
        r3["bestProtectionStreak"] == 2,
        f"got {r3}",
    )

    # 4. Negative Actual Savings -> also not successful
    r4 = engine.record_saving_activity(db, uid, "2026-08", -500)
    check(
        "Negative Actual Savings does not restart the streak",
        r4["currentProtectionStreak"] == 0,
        f"got {r4}",
    )

    # 5. Back to a successful month right after -> streak restarts at 1
    r5 = engine.record_saving_activity(db, uid, "2026-09", 100)
    check(
        "Returning to a successful month restarts the streak at 1, not carried over from before the break",
        r5["currentProtectionStreak"] == 1,
        f"got {r5}",
    )

    # 6. A skipped month (evaluation gap: last was 2026-09, next is 2026-11) ->
    # streak resets to 1 even though the skipped-over month was never marked unsuccessful.
    r6 = engine.record_saving_activity(db, uid, "2026-11", 5000)
    check(
        "A skipped month_key (rollover missed a month) resets the streak to 1, not continued",
        r6["currentProtectionStreak"] == 1,
        f"got {r6}",
    )

    # 7. Idempotency -- evaluating the same month_key twice is a no-op
    r7a = engine.record_saving_activity(db, uid, "2026-12", 1000)
    r7b = engine.record_saving_activity(db, uid, "2026-12", -1000)
    check(
        "Re-evaluating the same month_key is a no-op, even with a different amount passed",
        r7a == r7b,
        f"got r7a={r7a}, r7b={r7b}",
    )

    # 8. Year boundary -- December -> January must be treated as consecutive
    db2 = FakeDB()
    uid2 = "m2"
    engine.record_saving_activity(db2, uid2, "2026-12", 5000)
    jan = engine.record_saving_activity(db2, uid2, "2027-01", 3000)
    check(
        "December to January is treated as consecutive across the year boundary",
        jan["currentProtectionStreak"] == 2,
        f"got {jan}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Behavior Engine (Saving Behavior) scenarios passed.")


def run_recovery():
    print("Behavior Engine — Recovery Behavior test matrix")

    # 1. No recovery, plan absent -> no-op
    db = FakeDB()
    uid = "r1"
    r1 = engine.record_recovery_activity(db, uid, False, True, "2026-07-01")
    check(
        "No open recovery and no plan today is a no-op",
        r1 == repo._default_state()["recovery"],
        f"got {r1}",
    )

    # 2. Plan appears -> a new recovery attempt opens
    r2 = engine.record_recovery_activity(db, uid, True, True, "2026-07-05")
    check(
        "Recovery Plan appearing opens a new attempt",
        r2["openRecoveryStartedOn"] == "2026-07-05" and r2["totalAttempts"] == 1
        and r2["openRecoveryEverImpossible"] is False,
        f"got {r2}",
    )

    # 3. Same day called twice -> does not double-open (idempotent)
    r2b = engine.record_recovery_activity(db, uid, True, True, "2026-07-05")
    check(
        "Calling again the same day the attempt opened does not double-count totalAttempts",
        r2b["totalAttempts"] == 1,
        f"got {r2b}",
    )

    # 4. Plan stays present, still possible -> nothing else changes
    r3 = engine.record_recovery_activity(db, uid, True, True, "2026-07-06")
    check(
        "Plan still present and still possible leaves everImpossible false",
        r3["openRecoveryEverImpossible"] is False and r3["totalAttempts"] == 1,
        f"got {r3}",
    )

    # 5. recoveryPossible flips to false -> everImpossible becomes true, no counters touched yet
    r4 = engine.record_recovery_activity(db, uid, True, False, "2026-07-07")
    check(
        "recoveryPossible flipping false sets openRecoveryEverImpossible, without touching totalFailed yet",
        r4["openRecoveryEverImpossible"] is True and r4["totalFailed"] == 0,
        f"got {r4}",
    )

    # 6. It becomes possible again, but everImpossible must remain true (sticky for the whole attempt)
    r5 = engine.record_recovery_activity(db, uid, True, True, "2026-07-08")
    check(
        "openRecoveryEverImpossible stays true even after recoveryPossible recovers mid-attempt",
        r5["openRecoveryEverImpossible"] is True,
        f"got {r5}",
    )

    # 7. Plan disappears -> attempt closes as RECOVERY_FAILED (it was impossible at some point)
    r6 = engine.record_recovery_activity(db, uid, False, True, "2026-07-10")
    check(
        "Attempt that was ever impossible closes as failed: totalFailed +1, streak resets to 0",
        r6["totalFailed"] == 1 and r6["currentStreak"] == 0 and r6["totalResolved"] == 0,
        f"got {r6}",
    )
    check(
        "Closing resets openRecoveryStartedOn and openRecoveryEverImpossible for the next attempt",
        r6["openRecoveryStartedOn"] is None and r6["openRecoveryEverImpossible"] is False,
        f"got {r6}",
    )
    history = repo.load_history(db, uid)
    check(
        "The closed attempt is appended to behaviorHistory.recoveryAttempts with outcome 'failed'",
        history["recoveryAttempts"][-1] == {"startedOn": "2026-07-05", "resolvedOn": "2026-07-10", "outcome": "failed"},
        f"got {history['recoveryAttempts']}",
    )

    # 8. A second attempt opens and resolves cleanly (never impossible) -> RECOVERY_COMPLETED
    engine.record_recovery_activity(db, uid, True, True, "2026-07-15")
    r7 = engine.record_recovery_activity(db, uid, False, True, "2026-07-16")
    check(
        "A clean attempt (never impossible) closes as resolved: totalResolved +1, streak becomes 1",
        r7["totalResolved"] == 1 and r7["currentStreak"] == 1,
        f"got {r7}",
    )

    # 9. A third, also-clean attempt -> streak continues to 2
    engine.record_recovery_activity(db, uid, True, True, "2026-07-20")
    r8 = engine.record_recovery_activity(db, uid, False, True, "2026-07-21")
    check(
        "Consecutive clean recoveries extend the streak to 2",
        r8["currentStreak"] == 2 and r8["bestStreak"] == 2,
        f"got {r8}",
    )

    # 10. Same-day idempotency when closing -- calling again the day it closed is a no-op
    r8b = engine.record_recovery_activity(db, uid, False, True, "2026-07-21")
    check(
        "Calling again the same day an attempt closed is a no-op (no recovery open, none present)",
        r8b["totalResolved"] == 2 and r8b["currentStreak"] == 2,
        f"got {r8b}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Behavior Engine (Recovery Behavior) scenarios passed.")


def run_milestones():
    print("Behavior Engine — Milestones test matrix")

    # 1. FIRST_EXPENSE_LOGGED unlocks on the very first qualifying logging activity
    db = FakeDB()
    uid = "ms1"
    engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 1))
    history = repo.load_history(db, uid)
    check(
        "FIRST_EXPENSE_LOGGED unlocks on the first-ever logging activity",
        any(m["code"] == "FIRST_EXPENSE_LOGGED" for m in history["milestones"]),
        f"got {history['milestones']}",
    )
    check(
        "FIRST_EXPENSE_LOGGED milestone entry carries the extensible {code, type, threshold, unlockedAt} shape",
        history["milestones"][0] == {
            "code": "FIRST_EXPENSE_LOGGED", "type": "LOGGING_FIRST",
            "threshold": None, "unlockedAt": "2026-07-01",
        },
        f"got {history['milestones'][0]}",
    )

    # 2. It never unlocks a second time, even across many more days of activity
    engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 2))
    engine.record_logging_activity(db, uid, "TRANSACTION_CREATED", utc(2026, 7, 3))
    history2 = repo.load_history(db, uid)
    check(
        "FIRST_EXPENSE_LOGGED never re-unlocks on later days",
        len([m for m in history2["milestones"] if m["code"] == "FIRST_EXPENSE_LOGGED"]) == 1,
        f"got {history2['milestones']}",
    )

    # 3. LOGGING_STREAK_30_DAYS unlocks the day the streak reaches 30, not before
    db2 = FakeDB()
    uid2 = "ms2"
    for day in range(1, 30):
        engine.record_logging_activity(db2, uid2, "TRANSACTION_CREATED", utc(2026, 7, day if day <= 31 else day - 31, 10))
    history3 = repo.load_history(db2, uid2)
    check(
        "LOGGING_STREAK_30_DAYS has not unlocked at a 29-day streak",
        not any(m["code"] == "LOGGING_STREAK_30_DAYS" for m in history3["milestones"]),
        f"got {history3['milestones']}",
    )
    engine.record_logging_activity(db2, uid2, "TRANSACTION_CREATED", utc(2026, 7, 30, 10))
    history4 = repo.load_history(db2, uid2)
    check(
        "LOGGING_STREAK_30_DAYS unlocks exactly when the streak reaches 30",
        any(m["code"] == "LOGGING_STREAK_30_DAYS" for m in history4["milestones"]),
        f"got {history4['milestones']}",
    )

    # 4. FIRST_HEALTHY_WEEK unlocks the day the healthy streak reaches 7, not before
    db3 = FakeDB()
    uid3 = "ms3"
    for day in range(1, 7):
        engine.record_spending_activity(db3, uid3, "green", f"2026-07-{day:02d}")
    history5 = repo.load_history(db3, uid3)
    check(
        "FIRST_HEALTHY_WEEK has not unlocked at a 6-day healthy streak",
        not any(m["code"] == "FIRST_HEALTHY_WEEK" for m in history5["milestones"]),
        f"got {history5['milestones']}",
    )
    engine.record_spending_activity(db3, uid3, "green", "2026-07-07")
    history6 = repo.load_history(db3, uid3)
    check(
        "FIRST_HEALTHY_WEEK unlocks exactly when the healthy streak reaches 7",
        any(m["code"] == "FIRST_HEALTHY_WEEK" for m in history6["milestones"]),
        f"got {history6['milestones']}",
    )

    # 5. check_goal_milestones: no completed goal -> no unlock
    db4 = FakeDB()
    uid4 = "ms4"
    engine.check_goal_milestones(db4, uid4, [
        {"goalId": "g1", "savedSoFar": 5000, "targetAmount": 10000},
    ], "2026-07-01")
    history7 = repo.load_history(db4, uid4)
    check(
        "FIRST_GOAL_COMPLETED does not unlock while every goal is below its target",
        history7["milestones"] == [],
        f"got {history7['milestones']}",
    )

    # 6. A goal reaching its target unlocks FIRST_GOAL_COMPLETED
    engine.check_goal_milestones(db4, uid4, [
        {"goalId": "g1", "savedSoFar": 10000, "targetAmount": 10000},
    ], "2026-07-15")
    history8 = repo.load_history(db4, uid4)
    check(
        "FIRST_GOAL_COMPLETED unlocks once a goal's savedSoFar reaches its targetAmount",
        any(m["code"] == "FIRST_GOAL_COMPLETED" for m in history8["milestones"]),
        f"got {history8['milestones']}",
    )

    # 7. A second completed goal afterward does not unlock it again
    engine.check_goal_milestones(db4, uid4, [
        {"goalId": "g1", "savedSoFar": 10000, "targetAmount": 10000},
        {"goalId": "g2", "savedSoFar": 3000, "targetAmount": 3000},
    ], "2026-08-01")
    history9 = repo.load_history(db4, uid4)
    check(
        "FIRST_GOAL_COMPLETED never re-unlocks for a second completed goal",
        len([m for m in history9["milestones"] if m["code"] == "FIRST_GOAL_COMPLETED"]) == 1,
        f"got {history9['milestones']}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Behavior Engine (Milestones) scenarios passed.")


def _state_with(**overrides):
    state = repo._default_state()
    for section, fields in overrides.items():
        state[section].update(fields)
    return state


def run_summary():
    print("Behavior Engine — Behavior Summary test matrix")

    # 1. Brand new user -> Inactive, NEW_USER, high confidence
    db = FakeDB()
    uid = "sum1"
    summary = engine.compute_behavior_summary(db, uid)
    check(
        "Brand new user is Inactive with NEW_USER as primaryReason",
        summary["status"] == "inactive" and summary["primaryReason"] == "NEW_USER"
        and summary["confidence"] == "high",
        f"got {summary}",
    )
    check(
        "behaviorTrace is a non-empty list of strings",
        isinstance(summary["behaviorTrace"], list) and len(summary["behaviorTrace"]) > 0,
        f"got {summary['behaviorTrace']}",
    )

    # 2. All three positives at once -> Excellent
    db2 = FakeDB()
    uid2 = "sum2"
    repo.save_state(db2, uid2, _state_with(
        logging={"currentStreak": 10, "bestStreak": 10},
        spending={"currentHealthyStreak": 8},
        saving={"currentProtectionStreak": 2},
    ))
    summary2 = engine.compute_behavior_summary(db2, uid2)
    check(
        "All three positive signals at once -> Excellent",
        summary2["status"] == "excellent" and summary2["primaryReason"] == "CONSISTENT_LOGGING",
        f"got {summary2}",
    )
    check(
        "Excellent reasons include all three positive codes",
        set(summary2["reasons"]) == {"CONSISTENT_LOGGING", "HEALTHY_SPENDING", "MONTHLY_SAVING_SUCCESS"},
        f"got {summary2['reasons']}",
    )

    # 3. Only one positive (healthy spending) -> Good, broadened per the review (no logging requirement)
    db3 = FakeDB()
    uid3 = "sum3"
    repo.save_state(db3, uid3, _state_with(
        logging={"currentStreak": 2, "bestStreak": 2},
        spending={"currentHealthyStreak": 9},
    ))
    summary3 = engine.compute_behavior_summary(db3, uid3)
    check(
        "A single strong signal (healthy spending only) is enough for Good, not requiring logging",
        summary3["status"] == "good" and summary3["primaryReason"] == "HEALTHY_SPENDING",
        f"got {summary3}",
    )

    # 4. Recovery success alone -> Good
    db4 = FakeDB()
    uid4 = "sum4"
    repo.save_state(db4, uid4, _state_with(logging={"currentStreak": 3, "bestStreak": 3}))
    repo._history_ref(db4, uid4).set({
        "milestones": [],
        "recoveryAttempts": [{"startedOn": "2026-06-01", "resolvedOn": "2026-06-05", "outcome": "resolved"}],
    })
    summary4 = engine.compute_behavior_summary(db4, uid4)
    check(
        "A recent successful recovery alone is enough for Good",
        summary4["status"] == "good" and summary4["primaryReason"] == "RECOVERY_SUCCESS",
        f"got {summary4}",
    )

    # 5. Unhealthy spending pattern, no positives -> Needs Improvement
    db5 = FakeDB()
    uid5 = "sum5"
    repo.save_state(db5, uid5, _state_with(
        logging={"currentStreak": 2, "bestStreak": 2},
        spending={"currentOverspendingStreak": 9},
    ))
    summary5 = engine.compute_behavior_summary(db5, uid5)
    check(
        "A sustained overspending pattern with no positives -> Needs Improvement",
        summary5["status"] == "needs_improvement" and summary5["primaryReason"] == "UNHEALTHY_SPENDING_PATTERN",
        f"got {summary5}",
    )

    # 6. Repeated recovery failure, no positives -> Needs Improvement
    db6 = FakeDB()
    uid6 = "sum6"
    repo.save_state(db6, uid6, _state_with(
        logging={"currentStreak": 1, "bestStreak": 1},
        recovery={"totalFailed": 2},
    ))
    summary6 = engine.compute_behavior_summary(db6, uid6)
    check(
        "Two or more failed recoveries, no positives -> Needs Improvement",
        summary6["status"] == "needs_improvement" and summary6["primaryReason"] == "REPEATED_RECOVERY_FAILURE",
        f"got {summary6}",
    )

    # 7. Some history, nothing strong either way -> Building fallback
    db7 = FakeDB()
    uid7 = "sum7"
    repo.save_state(db7, uid7, _state_with(logging={"currentStreak": 3, "bestStreak": 5}))
    summary7 = engine.compute_behavior_summary(db7, uid7)
    check(
        "Some history but nothing strong in either direction -> Building",
        summary7["status"] == "building" and summary7["primaryReason"] == "BUILDING_HABITS",
        f"got {summary7}",
    )

    # 8. A single broken streak (currentStreak 0, bestStreak > 0) does NOT drop
    # status to Needs Improvement by itself -- it's neutral (Building), per the
    # slow-change principle.
    db8 = FakeDB()
    uid8 = "sum8"
    repo.save_state(db8, uid8, _state_with(logging={"currentStreak": 0, "bestStreak": 180}))
    summary8 = engine.compute_behavior_summary(db8, uid8)
    check(
        "A single broken streak alone is Building, not Needs Improvement (slow-change principle)",
        summary8["status"] == "building",
        f"got {summary8}",
    )

    # 9. Excellent is NOT overridden by a simultaneous negative pattern -- a
    # sustained positive pattern survives, per the hospital-bill principle.
    db9 = FakeDB()
    uid9 = "sum9"
    repo.save_state(db9, uid9, _state_with(
        logging={"currentStreak": 10, "bestStreak": 10},
        spending={"currentHealthyStreak": 8},
        saving={"currentProtectionStreak": 1},
        recovery={"totalFailed": 3},
    ))
    summary9 = engine.compute_behavior_summary(db9, uid9)
    check(
        "Excellent (sustained positive) is not overridden by a simultaneous negative pattern",
        summary9["status"] == "excellent",
        f"got {summary9}",
    )
    check(
        "The negative reason still appears in reasons[], even though it didn't decide status",
        "REPEATED_RECOVERY_FAILURE" in summary9["reasons"],
        f"got {summary9['reasons']}",
    )

    # 10. Recovery being currently open (RECOVERY_IN_PROGRESS) never appears as
    # a reason at all -- recovery is a situation, not a behavior.
    db10 = FakeDB()
    uid10 = "sum10"
    repo.save_state(db10, uid10, _state_with(
        logging={"currentStreak": 10, "bestStreak": 10},
        recovery={"openRecoveryStartedOn": "2026-07-10"},
    ))
    summary10 = engine.compute_behavior_summary(db10, uid10)
    check(
        "An open recovery contributes no reason at all -- only CONSISTENT_LOGGING drives status",
        summary10["reasons"] == ["CONSISTENT_LOGGING"],
        f"got {summary10}",
    )

    # 11. Confidence is the weakest link across whichever reasons triggered
    db11 = FakeDB()
    uid11 = "sum11"
    repo.save_state(db11, uid11, _state_with(
        logging={"currentStreak": 10, "bestStreak": 10},   # high confidence
        spending={"currentHealthyStreak": 8},               # medium confidence
    ))
    summary11 = engine.compute_behavior_summary(db11, uid11)
    check(
        "Confidence is the weakest link (medium) across logging=high and spending=medium",
        summary11["confidence"] == "medium",
        f"got {summary11}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Behavior Engine (Behavior Summary) scenarios passed.")


if __name__ == "__main__":
    run()
    run_spending()
    run_saving()
    run_recovery()
    run_milestones()
    run_summary()
