"""
test_snapshot_service.py
=========================
Step 9.3 acceptance scenarios for the Snapshot Builder — see
FINANCIAL_ENGINE_SPEC.md's "Step 9.2 — How a Snapshot Comes Into
Existence" for the frozen contract. Pure logic tests against synthetic
gathered data (no Firestore, no other engines needed) for
_is_complete()/_build_snapshot() — these are the parts that don't touch
Firestore at all. The full create_daily_snapshot() end-to-end path
(actually calling all five engines) is verified separately against the
real test account, not mocked here.

Run directly: python tests/test_snapshot_service.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import snapshot_service as svc

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def _synthetic_gathered(**overrides):
    gathered = {
        "financial": {
            "income": 50000, "totalSpent": 27000, "remainingBudget": 8000, "savingsPool": 23000,
            "metadata": {"engineVersion": 1},
        },
        "metrics": {
            "spendingPace": {"status": "on_track"},
            "recommendedDailySpend": {"value": 500.0},
            "recoveryPlan": None,
            "metadata": {"metricsEngineVersion": "1.0.0"},
        },
        "health": {
            "overallHealth": {"status": "green"},
            "metadata": {"healthEngineVersion": "1.0.0"},
        },
        "categoryHealth": {
            "categoryHealth": {"Food": {"status": "amber"}, "Transport": {"status": "green"}},
        },
        "recommendation": {
            "primaryRecommendation": {"code": "KEEP_CURRENT_HABITS"},
            "metadata": {"recommendationEngineVersion": "1.0.0"},
        },
        "behaviorState": {
            "logging": {"currentStreak": 5, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        "behaviorSummary": {
            "status": "good", "primaryReason": "CONSISTENT_LOGGING", "confidence": "high",
            "summaryVersion": "1.0.0",
        },
    }
    gathered.update(overrides)
    return gathered


def run():
    print("Snapshot Service — test matrix")

    # 1. Complete gathered data passes the invariant check
    complete = _synthetic_gathered()
    check(
        "A fully gathered dict passes _is_complete()",
        svc._is_complete(complete),
        f"got {complete}",
    )

    # 2. Any missing required key fails completeness -- even with no exception involved
    for key in svc._REQUIRED_GATHERED_KEYS:
        incomplete = _synthetic_gathered(**{key: None})
        check(
            f"Missing '{key}' (returned None, no exception) fails _is_complete()",
            not svc._is_complete(incomplete),
            f"got True for missing {key}",
        )

    # 3. categoryHealth being present but internally empty/None does not itself
    # break completeness -- it's a legitimate empty state (no budgets yet),
    # not evidence Health Engine failed.
    no_categories = _synthetic_gathered(categoryHealth={"categoryHealth": None})
    check(
        "categoryHealth's inner value being None (no budgets yet) does not fail completeness",
        svc._is_complete(no_categories),
        f"got {no_categories}",
    )

    # 4. _build_snapshot assembles the frozen schema shape exactly
    snapshot = svc._build_snapshot(complete, __import__("datetime").date(2026, 7, 19), "2026-07-19T23:59:00+00:00")
    check(
        "Built snapshot has the frozen top-level keys",
        set(snapshot.keys()) == {
            "snapshotDate", "generatedAt", "snapshotVersion", "versions",
            "financial", "metrics", "health", "recommendation", "behavior",
        },
        f"got {list(snapshot.keys())}",
    )
    check(
        "snapshotDate and generatedAt are exactly what was passed in",
        snapshot["snapshotDate"] == "2026-07-19" and snapshot["generatedAt"] == "2026-07-19T23:59:00+00:00",
        f"got {snapshot['snapshotDate']}, {snapshot['generatedAt']}",
    )
    check(
        "versions block pulls each engine's own version from its own metadata, not invented",
        snapshot["versions"] == {
            "financial": 1, "metrics": "1.0.0", "health": "1.0.0",
            "recommendation": "1.0.0", "behavior": "1.0.0",
        },
        f"got {snapshot['versions']}",
    )
    check(
        "financial section carries exactly the four frozen fields, nothing else",
        snapshot["financial"] == {
            "income": 50000, "totalSpent": 27000, "remainingBudget": 8000, "savingsPool": 23000,
        },
        f"got {snapshot['financial']}",
    )
    check(
        "metrics section reflects an absent recoveryPlan correctly",
        snapshot["metrics"] == {
            "spendingPaceStatus": "on_track", "recommendedDailySpendValue": 500.0,
            "recoveryPlanPresent": False, "recoveryPossible": None,
        },
        f"got {snapshot['metrics']}",
    )
    check(
        "health section flattens categoryHealth to a plain cat -> status map",
        snapshot["health"] == {
            "overallHealthStatus": "green",
            "categoryHealth": {"Food": "amber", "Transport": "green"},
        },
        f"got {snapshot['health']}",
    )
    check(
        "recommendation section carries only the primary recommendation's code",
        snapshot["recommendation"] == {"primaryRecommendationCode": "KEEP_CURRENT_HABITS"},
        f"got {snapshot['recommendation']}",
    )
    check(
        "behavior.state carries only the frozen raw counters, not the full behaviorState",
        snapshot["behavior"]["state"] == {
            "logging": {"currentStreak": 5, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        f"got {snapshot['behavior']['state']}",
    )
    check(
        "behavior.summary carries only status/primaryReason/confidence, not events or a trace",
        snapshot["behavior"]["summary"] == {
            "status": "good", "primaryReason": "CONSISTENT_LOGGING", "confidence": "high",
        },
        f"got {snapshot['behavior']['summary']}",
    )
    check(
        "No milestone data anywhere in the snapshot -- Option C, resolved in Step 9.1",
        "milestones" not in snapshot["behavior"] and "milestoneCount" not in snapshot["behavior"],
        f"got {snapshot['behavior']}",
    )

    # 5. Determinism (Rule 9): same gathered data + same date + same
    # generated_at -> byte-identical snapshot, every time.
    snapshot_again = svc._build_snapshot(complete, __import__("datetime").date(2026, 7, 19), "2026-07-19T23:59:00+00:00")
    check(
        "Building the same snapshot twice from the same inputs is byte-identical (Rule 9)",
        snapshot == snapshot_again,
        f"got two different results",
    )

    # 6. A recoveryPlan present with recoveryPossible=False is captured correctly
    with_recovery = _synthetic_gathered(metrics={
        "spendingPace": {"status": "too_fast"},
        "recommendedDailySpend": {"value": 100.0},
        "recoveryPlan": {"recoveryPossible": False},
        "metadata": {"metricsEngineVersion": "1.0.0"},
    })
    snapshot3 = svc._build_snapshot(with_recovery, __import__("datetime").date(2026, 7, 19), "2026-07-19T23:59:00+00:00")
    check(
        "A present, impossible recovery plan is captured as recoveryPlanPresent=True, recoveryPossible=False",
        snapshot3["metrics"]["recoveryPlanPresent"] is True and snapshot3["metrics"]["recoveryPossible"] is False,
        f"got {snapshot3['metrics']}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Snapshot Service scenarios passed.")


if __name__ == "__main__":
    run()
