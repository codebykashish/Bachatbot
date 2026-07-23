"""
test_weekly_interpretation.py
================================
Phase 22C acceptance scenarios for Weekly Interpretation — see
FINANCIAL_ENGINE_SPEC.md's "Phase 22C — Weekly Interpretation."
interpret_weekly_observation() is a pure function (no Firestore), so
every scenario here is a plain synthetic observation dict -- no fakes
needed, unlike Phase B's gather helpers.

Run directly: python tests/test_weekly_interpretation.py
"""

import sys
import os
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import weekly_reflection_service as wrs

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def utc(y, m, d, hour=12):
    return datetime(y, m, d, hour, tzinfo=timezone.utc)


def base_observation(**overrides):
    obs = {
        "transactions": {"totalSpent": 0, "totalIncome": 0, "transactionCount": 0, "categorySpending": {}},
        "budgets": {"monthKeysInvolved": ["2026-07"], "categoryLimits": {}},
        "health": {"snapshotsFound": 0, "first": None, "last": None},
        "behavior": {"loggingStreak": 0, "healthySpendingStreak": 0, "overspendingStreak": 0, "savingProtectionStreak": 0},
        "goalRisk": {},
        "recommendation": {"code": "KEEP_CURRENT_HABITS"},
        "patternAlerts": [],
    }
    obs.update(overrides)
    return obs


def run():
    print("Weekly Interpretation — test matrix")

    # 1. Health improved -> highlight
    obs = base_observation(health={"snapshotsFound": 2, "first": {"date": "d1", "status": "amber"}, "last": {"date": "d2", "status": "green"}})
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Health improved (amber->green) -> HEALTH_IMPROVED highlight",
        any(h["type"] == "HEALTH_IMPROVED" for h in result["highlights"]),
        f"got {result['highlights']}",
    )
    check(
        "No HEALTH_WORSENED concern when health improved",
        not any(c["type"] == "HEALTH_WORSENED" for c in result["concerns"]),
        f"got {result['concerns']}",
    )

    # 2. Health worsened -> concern
    obs = base_observation(health={"snapshotsFound": 2, "first": {"date": "d1", "status": "green"}, "last": {"date": "d2", "status": "amber"}})
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Health worsened (green->amber) -> HEALTH_WORSENED concern",
        any(c["type"] == "HEALTH_WORSENED" for c in result["concerns"]),
        f"got {result['concerns']}",
    )

    # 3. Fewer than 2 snapshots -> no health claim either way
    obs = base_observation(health={"snapshotsFound": 1, "first": {"date": "d1", "status": "green"}, "last": {"date": "d1", "status": "green"}})
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Fewer than 2 snapshots -> no HEALTH_IMPROVED/WORSENED claim",
        not any(h["type"] == "HEALTH_IMPROVED" for h in result["highlights"])
        and not any(c["type"] == "HEALTH_WORSENED" for c in result["concerns"]),
        f"got {result}",
    )

    # 4. Streak tie-break: logging=5, saving=5 -> saving wins (priority order)
    obs = base_observation(behavior={"loggingStreak": 5, "healthySpendingStreak": 0, "overspendingStreak": 0, "savingProtectionStreak": 5})
    result = wrs.interpret_weekly_observation(obs)
    streak_highlight = next((h for h in result["highlights"] if h["type"] == "MEANINGFUL_STREAK"), None)
    check(
        "Tied streaks -> savingProtectionStreak wins the tie-break, not loggingStreak",
        streak_highlight is not None and streak_highlight["streakType"] == "savingProtectionStreak",
        f"got {streak_highlight}",
    )

    # 5. Streak below minimum -> not selected
    obs = base_observation(behavior={"loggingStreak": 2, "healthySpendingStreak": 0, "overspendingStreak": 0, "savingProtectionStreak": 0})
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Streak below the meaningful minimum (2 < 3) -> no MEANINGFUL_STREAK highlight",
        not any(h["type"] == "MEANINGFUL_STREAK" for h in result["highlights"]),
        f"got {result['highlights']}",
    )

    # 6. Category within budget: highest-spending qualifying category wins
    obs = base_observation(
        transactions={"totalSpent": 0, "totalIncome": 0, "transactionCount": 0,
                       "categorySpending": {"Food": 4000, "Transport": 500}},
        budgets={"monthKeysInvolved": ["2026-07"], "categoryLimits": {"Food": 6600, "Transport": 2910}},
    )
    result = wrs.interpret_weekly_observation(obs)
    within_budget = next((h for h in result["highlights"] if h["type"] == "CATEGORY_WITHIN_BUDGET"), None)
    check(
        "Category within budget picks the highest-spending qualifying category (Food over Transport)",
        within_budget is not None and within_budget["category"] == "Food",
        f"got {within_budget}",
    )

    # 7. 80% shared boundary: exactly at 80% usage -> concern, NOT highlight (no overlap)
    obs = base_observation(
        transactions={"totalSpent": 0, "totalIncome": 0, "transactionCount": 0, "categorySpending": {"Food": 5280}},
        budgets={"monthKeysInvolved": ["2026-07"], "categoryLimits": {"Food": 6600}},  # 5280/6600 = exactly 0.80
    )
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Exactly 80% usage -> CATEGORY_HIGH_USAGE concern, never CATEGORY_WITHIN_BUDGET highlight",
        any(c["type"] == "CATEGORY_HIGH_USAGE" and c["category"] == "Food" for c in result["concerns"])
        and not any(h["type"] == "CATEGORY_WITHIN_BUDGET" for h in result["highlights"]),
        f"got highlights={result['highlights']} concerns={result['concerns']}",
    )

    # 8. High usage: highest-ratio qualifying category wins among multiple
    obs = base_observation(
        transactions={"totalSpent": 0, "totalIncome": 0, "transactionCount": 0,
                       "categorySpending": {"Food": 6000, "Transport": 2900}},  # Food 91%, Transport 99.6%
        budgets={"monthKeysInvolved": ["2026-07"], "categoryLimits": {"Food": 6600, "Transport": 2910}},
    )
    result = wrs.interpret_weekly_observation(obs)
    high_usage = next((c for c in result["concerns"] if c["type"] == "CATEGORY_HIGH_USAGE"), None)
    check(
        "High usage concern picks the highest-ratio category (Transport ~99.6% over Food ~91%)",
        high_usage is not None and high_usage["category"] == "Transport",
        f"got {high_usage}",
    )

    # 9. Month-boundary week -> no category highlight/concern at all
    obs = base_observation(
        transactions={"totalSpent": 0, "totalIncome": 0, "transactionCount": 0, "categorySpending": {"Food": 100}},
        budgets={"monthKeysInvolved": ["2026-07", "2026-08"], "categoryLimits": {}},
    )
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Month-boundary week produces no category-based highlight or concern",
        not any(h["type"] == "CATEGORY_WITHIN_BUDGET" for h in result["highlights"])
        and not any(c["type"] == "CATEGORY_HIGH_USAGE" for c in result["concerns"]),
        f"got {result}",
    )

    # 10. Low activity: zero transactions AND zero logging streak
    obs = base_observation(
        transactions={"totalSpent": 0, "totalIncome": 0, "transactionCount": 0, "categorySpending": {}},
        behavior={"loggingStreak": 0, "healthySpendingStreak": 0, "overspendingStreak": 0, "savingProtectionStreak": 0},
    )
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Zero transactions and zero logging streak -> LOW_ACTIVITY concern",
        any(c["type"] == "LOW_ACTIVITY" for c in result["concerns"]),
        f"got {result['concerns']}",
    )
    # Not triggered if EITHER is non-zero
    obs2 = base_observation(
        transactions={"totalSpent": 0, "totalIncome": 0, "transactionCount": 0, "categorySpending": {}},
        behavior={"loggingStreak": 1, "healthySpendingStreak": 0, "overspendingStreak": 0, "savingProtectionStreak": 0},
    )
    result2 = wrs.interpret_weekly_observation(obs2)
    check(
        "A nonzero logging streak alone prevents LOW_ACTIVITY, even with zero transactions",
        not any(c["type"] == "LOW_ACTIVITY" for c in result2["concerns"]),
        f"got {result2['concerns']}",
    )

    # 11. Pattern: most recent alert wins among multiple
    obs = base_observation(patternAlerts=[
        {"category": "Food", "createdAt": utc(2026, 7, 20)},
        {"category": "Shopping", "createdAt": utc(2026, 7, 24)},
    ])
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Most recent pattern alert wins (Shopping on Jul 24 over Food on Jul 20)",
        result["pattern"] is not None and result["pattern"]["category"] == "Shopping",
        f"got {result['pattern']}",
    )

    # 12. No pattern alerts -> None
    obs = base_observation()
    result = wrs.interpret_weekly_observation(obs)
    check("No pattern alerts -> pattern is None", result["pattern"] is None)

    # 13. Goal context: multiple at-risk goals -> largest shortfall wins
    obs = base_observation(goalRisk={
        "g1": {"atRisk": True, "shortfall": 5000, "goalName": "Trip", "confidence": "medium"},
        "g2": {"atRisk": True, "shortfall": 12000, "goalName": "Laptop", "confidence": "medium"},
    })
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Goal context picks the largest shortfall (Laptop 12000 over Trip 5000)",
        result["goalContext"] == {"type": "GOAL_AT_RISK", "goalId": "g2", "goalName": "Laptop", "shortfall": 12000},
        f"got {result['goalContext']}",
    )

    # 14. No at-risk goals, some healthy -> GOAL_ON_TRACK
    obs = base_observation(goalRisk={
        "g3": {"atRisk": False, "goalName": "Emergency Fund", "confidence": "high"},
    })
    result = wrs.interpret_weekly_observation(obs)
    check(
        "No at-risk goals -> GOAL_ON_TRACK naming the healthy goal",
        result["goalContext"] == {"type": "GOAL_ON_TRACK", "goalId": "g3", "goalName": "Emergency Fund"},
        f"got {result['goalContext']}",
    )

    # 15. No goals at all -> None
    obs = base_observation(goalRisk={})
    result = wrs.interpret_weekly_observation(obs)
    check("No goals at all -> goalContext is None", result["goalContext"] is None)

    # 16. Next step: pass-through, but KEEP_CURRENT_HABITS omitted
    obs = base_observation(recommendation={"code": "INCREASE_GOAL_CONTRIBUTION"})
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Real recommendation code passes through as the next step",
        result["nextStep"] == {"recommendationCode": "INCREASE_GOAL_CONTRIBUTION"},
        f"got {result['nextStep']}",
    )
    obs2 = base_observation(recommendation={"code": "KEEP_CURRENT_HABITS"})
    result2 = wrs.interpret_weekly_observation(obs2)
    check(
        "KEEP_CURRENT_HABITS is omitted -- not worth occupying the one next-step slot",
        result2["nextStep"] is None,
        f"got {result2['nextStep']}",
    )

    # 17. Hard cap: 3 qualifying highlights -> exactly 2 returned, priority order preserved
    obs = base_observation(
        health={"snapshotsFound": 2, "first": {"date": "d1", "status": "red"}, "last": {"date": "d2", "status": "green"}},
        behavior={"loggingStreak": 10, "healthySpendingStreak": 0, "overspendingStreak": 0, "savingProtectionStreak": 0},
        transactions={"totalSpent": 0, "totalIncome": 0, "transactionCount": 0, "categorySpending": {"Food": 1000}},
        budgets={"monthKeysInvolved": ["2026-07"], "categoryLimits": {"Food": 6600}},
    )
    result = wrs.interpret_weekly_observation(obs)
    check(
        "Three qualifying highlights capped to exactly 2, in frozen priority order",
        [h["type"] for h in result["highlights"]] == ["HEALTH_IMPROVED", "MEANINGFUL_STREAK"],
        f"got {[h['type'] for h in result['highlights']]}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Weekly Interpretation scenarios passed.")


if __name__ == "__main__":
    run()
