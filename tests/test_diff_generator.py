"""
test_diff_generator.py
========================
Step 10.3 acceptance scenarios for the Diff Generator — see
FINANCIAL_ENGINE_SPEC.md's "Step 10.2 — Diff Matrix" and "Step 10.3 —
Generator Pipeline." Pure logic tests — no Firestore, no other engines,
just two synthetic snapshot dicts and a milestones list, exactly the
three inputs generate_events() is frozen to accept.

Run directly: python tests/test_diff_generator.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import diff_generator as diff

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def _snapshot(date, **overrides):
    base = {
        "snapshotDate": date,
        "generatedAt": f"{date}T23:59:00+00:00",
        "snapshotVersion": "1.0.0",
        "versions": {"financial": 1, "metrics": 1, "health": "1.0.0", "recommendation": "1.0.0", "behavior": "1.0.0"},
        "financial": {"income": 50000, "totalSpent": 27000, "remainingBudget": 8000, "savingsPool": 23000},
        "metrics": {
            "spendingPaceStatus": "on_track", "recommendedDailySpendValue": 500.0,
            "recoveryPlanPresent": False, "recoveryPossible": None,
        },
        "health": {"overallHealthStatus": "green", "categoryHealth": {"Food": "green", "Transport": "green"}},
        "recommendation": {"primaryRecommendationCode": "KEEP_CURRENT_HABITS"},
        "behavior": {
            "state": {
                "logging": {"currentStreak": 5, "bestStreak": 10},
                "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
                "saving": {"currentProtectionStreak": 1},
                "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
            },
            "summary": {"status": "good", "primaryReason": "CONSISTENT_LOGGING", "confidence": "high"},
        },
    }
    for key, value in overrides.items():
        base[key] = value
    return base


def run():
    print("Diff Generator — test matrix")

    # 1. No changes anywhere -> zero events (Rule 3)
    y = _snapshot("2026-07-18")
    t = _snapshot("2026-07-19")
    events = diff.generate_events("u1", y, t)
    check(
        "Identical snapshots produce zero events",
        events == [],
        f"got {events}",
    )

    # 2. Health worsened: green -> amber fires HEALTH_WORSENED, not HEALTH_IMPROVED
    t2 = _snapshot("2026-07-19", health={"overallHealthStatus": "amber", "categoryHealth": {"Food": "green", "Transport": "green"}})
    events2 = diff.generate_events("u1", y, t2)
    check(
        "Green -> Amber fires exactly one HEALTH_WORSENED event",
        [e["event"] for e in events2] == ["HEALTH_WORSENED"],
        f"got {events2}",
    )

    # 3. Health improved: amber -> green fires HEALTH_IMPROVED
    y3 = _snapshot("2026-07-18", health={"overallHealthStatus": "amber", "categoryHealth": {"Food": "green", "Transport": "green"}})
    t3 = _snapshot("2026-07-19")
    events3 = diff.generate_events("u1", y3, t3)
    check(
        "Amber -> Green fires exactly one HEALTH_IMPROVED event",
        [e["event"] for e in events3] == ["HEALTH_IMPROVED"],
        f"got {events3}",
    )

    # 4. Category becomes exhausted -> CATEGORY_BECAME_EXHAUSTED, correct payload
    t4 = _snapshot("2026-07-19", health={"overallHealthStatus": "amber", "categoryHealth": {"Food": "red", "Transport": "green"}})
    events4 = diff.generate_events("u1", y, t4)
    category_events = [e for e in events4 if e["event"] == "CATEGORY_BECAME_EXHAUSTED"]
    check(
        "A category newly at red fires CATEGORY_BECAME_EXHAUSTED with the category name in payload",
        len(category_events) == 1 and category_events[0]["payload"]["category"] == "Food",
        f"got {events4}",
    )

    # 5. A category already red yesterday does not re-fire today
    y5 = _snapshot("2026-07-18", health={"overallHealthStatus": "red", "categoryHealth": {"Food": "red", "Transport": "green"}})
    t5 = _snapshot("2026-07-19", health={"overallHealthStatus": "red", "categoryHealth": {"Food": "red", "Transport": "green"}})
    events5 = diff.generate_events("u1", y5, t5)
    check(
        "A category already red yesterday does not re-fire CATEGORY_BECAME_EXHAUSTED today",
        not any(e["event"] == "CATEGORY_BECAME_EXHAUSTED" for e in events5),
        f"got {events5}",
    )

    # 6. Recommendation change -> PRIMARY_RECOMMENDATION_CHANGED
    t6 = _snapshot("2026-07-19", recommendation={"primaryRecommendationCode": "STOP_CATEGORY_SPENDING"})
    events6 = diff.generate_events("u1", y, t6)
    check(
        "A changed primary recommendation fires PRIMARY_RECOMMENDATION_CHANGED",
        [e["event"] for e in events6] == ["PRIMARY_RECOMMENDATION_CHANGED"],
        f"got {events6}",
    )

    # 7. Logging streak extended (6 -> 7, the milestone-coexistence case) fires
    # LOGGING_STREAK_EXTENDED regardless of any milestone also unlocking
    y7 = _snapshot("2026-07-18", behavior={
        "state": {
            "logging": {"currentStreak": 6, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        "summary": {"status": "good", "primaryReason": "CONSISTENT_LOGGING", "confidence": "high"},
    })
    t7 = _snapshot("2026-07-19", behavior={
        "state": {
            "logging": {"currentStreak": 7, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        "summary": {"status": "excellent", "primaryReason": "CONSISTENT_LOGGING", "confidence": "high"},
    })
    events7 = diff.generate_events("u1", y7, t7)
    check(
        "Logging streak 6 -> 7 fires LOGGING_STREAK_EXTENDED",
        [e["event"] for e in events7] == ["LOGGING_STREAK_EXTENDED"],
        f"got {events7}",
    )

    # 8. Logging streak broken (5 -> 0) fires LOGGING_STREAK_BROKEN
    t8 = _snapshot("2026-07-19", behavior={
        "state": {
            "logging": {"currentStreak": 0, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        "summary": {"status": "building", "primaryReason": "BUILDING_HABITS", "confidence": "high"},
    })
    events8 = diff.generate_events("u1", y, t8)
    check(
        "Logging streak 5 -> 0 fires LOGGING_STREAK_BROKEN",
        [e["event"] for e in events8] == ["LOGGING_STREAK_BROKEN"],
        f"got {events8}",
    )

    # 9. Saving streak extended/broken -- the new rows found during Step 10.2
    t9 = _snapshot("2026-07-19", behavior={
        "state": {
            "logging": {"currentStreak": 5, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 2},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        "summary": {"status": "good", "primaryReason": "MONTHLY_SAVING_SUCCESS", "confidence": "high"},
    })
    events9 = diff.generate_events("u1", y, t9)
    check(
        "Saving protection streak 1 -> 2 fires SAVING_STREAK_EXTENDED",
        [e["event"] for e in events9] == ["SAVING_STREAK_EXTENDED"],
        f"got {events9}",
    )

    # 10. Recovery started (recoveryPlanPresent false -> true)
    t10 = _snapshot("2026-07-19", metrics={
        "spendingPaceStatus": "too_fast", "recommendedDailySpendValue": 100.0,
        "recoveryPlanPresent": True, "recoveryPossible": True,
    })
    events10 = diff.generate_events("u1", y, t10)
    check(
        "recoveryPlanPresent false -> true fires RECOVERY_STARTED",
        [e["event"] for e in events10] == ["RECOVERY_STARTED"],
        f"got {events10}",
    )

    # 11. Recovery became impossible (recoveryPossible true -> false)
    y11 = _snapshot("2026-07-18", metrics={
        "spendingPaceStatus": "too_fast", "recommendedDailySpendValue": 100.0,
        "recoveryPlanPresent": True, "recoveryPossible": True,
    })
    t11 = _snapshot("2026-07-19", metrics={
        "spendingPaceStatus": "too_fast", "recommendedDailySpendValue": 50.0,
        "recoveryPlanPresent": True, "recoveryPossible": False,
    })
    events11 = diff.generate_events("u1", y11, t11)
    check(
        "recoveryPossible true -> false fires RECOVERY_BECAME_IMPOSSIBLE, not RECOVERY_STARTED again",
        [e["event"] for e in events11] == ["RECOVERY_BECAME_IMPOSSIBLE"],
        f"got {events11}",
    )

    # 12. Recovery completed / failed via totalResolved / totalFailed
    t12 = _snapshot("2026-07-19", behavior={
        "state": {
            "logging": {"currentStreak": 5, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 1, "totalResolved": 3, "totalFailed": 1},
        },
        "summary": {"status": "good", "primaryReason": "RECOVERY_SUCCESS", "confidence": "medium"},
    })
    events12 = diff.generate_events("u1", y, t12)
    check(
        "totalResolved 2 -> 3 fires RECOVERY_COMPLETED",
        [e["event"] for e in events12] == ["RECOVERY_COMPLETED"],
        f"got {events12}",
    )

    # 13. Milestone unlocked today
    milestones = [
        {"code": "FIRST_HEALTHY_WEEK", "type": "HEALTHY_STREAK", "threshold": 7, "unlockedAt": "2026-07-19"},
        {"code": "FIRST_EXPENSE_LOGGED", "type": "LOGGING_FIRST", "threshold": None, "unlockedAt": "2026-06-01"},
    ]
    events13 = diff.generate_events("u1", y, t, milestones_today=milestones)
    check(
        "Only the milestone unlocked ON today's date fires MILESTONE_UNLOCKED, not the older one",
        [e["event"] for e in events13] == ["MILESTONE_UNLOCKED"] and events13[0]["payload"]["code"] == "FIRST_HEALTHY_WEEK",
        f"got {events13}",
    )

    # 14. Two milestones unlocked the same day -> two distinct events, distinct eventIds
    two_milestones = [
        {"code": "FIRST_HEALTHY_WEEK", "type": "HEALTHY_STREAK", "threshold": 7, "unlockedAt": "2026-07-19"},
        {"code": "LOGGING_STREAK_30_DAYS", "type": "LOGGING_STREAK", "threshold": 30, "unlockedAt": "2026-07-19"},
    ]
    events14 = diff.generate_events("u1", y, t, milestones_today=two_milestones)
    check(
        "Two milestones unlocked the same day produce two distinct MILESTONE_UNLOCKED events with distinct eventIds",
        len(events14) == 2 and events14[0]["eventId"] != events14[1]["eventId"],
        f"got {events14}",
    )

    # 15. Determinism: identical inputs -> identical output, including eventIds
    events_again = diff.generate_events("u1", y, t4)
    check(
        "Calling generate_events twice with identical inputs produces byte-identical output",
        events4 == events_again,
        f"got two different results",
    )

    # 16. No ordering beyond Diff Matrix row order: health fires before behavior
    t16 = _snapshot("2026-07-19", health={"overallHealthStatus": "amber", "categoryHealth": {"Food": "green", "Transport": "green"}}, behavior={
        "state": {
            "logging": {"currentStreak": 6, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        "summary": {"status": "good", "primaryReason": "CONSISTENT_LOGGING", "confidence": "high"},
    })
    y16 = _snapshot("2026-07-18", behavior={
        "state": {
            "logging": {"currentStreak": 5, "bestStreak": 10},
            "spending": {"currentHealthyStreak": 3, "currentOverspendingStreak": 0},
            "saving": {"currentProtectionStreak": 1},
            "recovery": {"currentStreak": 0, "totalResolved": 2, "totalFailed": 1},
        },
        "summary": {"status": "good", "primaryReason": "CONSISTENT_LOGGING", "confidence": "high"},
    })
    events16 = diff.generate_events("u1", y16, t16)
    check(
        "Events return in Diff Matrix row order (health before behavior), not sorted any other way",
        [e["event"] for e in events16] == ["HEALTH_WORSENED", "LOGGING_STREAK_EXTENDED"],
        f"got {events16}",
    )

    # 17. Unknown field (not in the Diff Matrix at all) never produces an event (Rule 10)
    t17 = _snapshot("2026-07-19")
    t17["financial"] = dict(t17["financial"])
    t17["financial"]["someBrandNewField"] = "changed value nobody wrote a rule for"
    events17 = diff.generate_events("u1", y, t17)
    check(
        "A field with no Diff Matrix row produces zero events, never a guess",
        events17 == [],
        f"got {events17}",
    )

    # 18. Validation: same date raises
    try:
        diff.generate_events("u1", y, y)
        check("Same-date snapshots raise ValueError", False, "did not raise")
    except ValueError:
        check("Same-date snapshots raise ValueError", True)

    # 19. Validation: reversed order raises
    try:
        diff.generate_events("u1", t, y)
        check("Reversed-order snapshots raise ValueError", False, "did not raise")
    except ValueError:
        check("Reversed-order snapshots raise ValueError", True)

    # 20. Validation: a multi-day gap does NOT raise -- only strict ordering is enforced
    y20 = _snapshot("2026-07-01")
    t20 = _snapshot("2026-07-10")
    try:
        diff.generate_events("u1", y20, t20)
        check("A multi-day gap between snapshots does not raise (only strict ordering is enforced)", True)
    except ValueError as e:
        check("A multi-day gap between snapshots does not raise (only strict ordering is enforced)", False, str(e))

    # 21. Validation: unsupported snapshotVersion raises
    t21 = _snapshot("2026-07-19", snapshotVersion="99.0.0")
    try:
        diff.generate_events("u1", y, t21)
        check("An unsupported snapshotVersion raises ValueError", False, "did not raise")
    except ValueError:
        check("An unsupported snapshotVersion raises ValueError", True)

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Diff Generator scenarios passed.")


if __name__ == "__main__":
    run()
