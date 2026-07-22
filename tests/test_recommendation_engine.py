"""
test_recommendation_engine.py
=========================
Phase 4 acceptance scenarios for the Recommendation Engine — see
FINANCIAL_ENGINE_SPEC.md "Phase 4.0 — Recommendation Philosophy." Pure
rule evaluation, no Firestore needed — every case constructs a synthetic
Risk Flags list + Metrics Engine response and runs it through the
private pipeline stages directly (the same treatment test_health_engine.py
gives health_engine.py's private pipeline functions).

Run directly: python tests/test_recommendation_engine.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.recommendation_engine import (
    _validate_flags,
    _build_recommendation,
    _build_healthy_recommendation,
    _build_recommendation_trace,
    _RECOMMENDATION_MATRIX,
)

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def run_recommendations(flags, metrics):
    """Mirrors compute_recommendations()'s pipeline without Firestore."""
    flags = _validate_flags(flags)
    if not flags:
        primary = _build_healthy_recommendation()
        primary["priority"] = 1
        return primary, []

    recommendations = [_build_recommendation(f, metrics) for f in flags]
    recommendations = [r for r in recommendations if r is not None]
    for i, rec in enumerate(recommendations):
        rec["priority"] = i + 1
    return recommendations[0], recommendations[1:]


def run():
    print("Recommendation Engine — test matrix")

    # 1. Healthy account -> encouragement (KEEP_CURRENT_HABITS, type maintain)
    primary, alternatives = run_recommendations([], {})
    check(
        "Healthy account -> KEEP_CURRENT_HABITS, type maintain, no alternatives",
        primary["code"] == "KEEP_CURRENT_HABITS" and primary["type"] == "maintain" and alternatives == [],
        f"got {primary}, {alternatives}",
    )

    # 2. Recovery needed -> LIMIT_DAILY_SPENDING with correct actionValue/actionUnit
    flags = [{"code": "RECOVERY_NEEDED", "type": "recovery_risk", "severity": "medium", "confidence": "medium", "source": "recoveryPlan"}]
    metrics = {"recoveryPlan": {"dailyTarget": 150}}
    primary, alternatives = run_recommendations(flags, metrics)
    check(
        "Recovery needed -> LIMIT_DAILY_SPENDING, actionValue 150, actionUnit per_day",
        primary == {
            "code": "LIMIT_DAILY_SPENDING", "type": "recover", "confidence": "medium",
            "actionValue": 150, "actionUnit": "per_day", "category": None,
            "goalId": None, "goalName": None,
            "source": "recoveryPlan", "generatedFrom": "RECOVERY_NEEDED",
            "expiresWhen": "Recovery Plan is no longer needed", "priority": 1,
        },
        f"got {primary}",
    )

    # 3. Category exhausted -> STOP_CATEGORY_SPENDING, actionValue 0, correct category
    flags = [{"code": "CATEGORY_EXHAUSTED", "type": "budget_risk", "severity": "high", "confidence": "medium", "source": "categoryHealth", "category": "Food"}]
    primary, alternatives = run_recommendations(flags, {})
    check(
        "Category exhausted -> STOP_CATEGORY_SPENDING for Food, actionValue 0",
        primary["code"] == "STOP_CATEGORY_SPENDING"
        and primary["type"] == "stop"
        and primary["actionValue"] == 0
        and primary["category"] == "Food"
        and primary["expiresWhen"] == "Food is no longer exhausted",
        f"got {primary}",
    )

    # Category under high pressure (not exhausted) -> REDUCE_CATEGORY_SPENDING with real actionValue
    flags = [{"code": "CATEGORY_HIGH_PRESSURE", "type": "budget_risk", "severity": "medium", "confidence": "high", "source": "categoryHealth", "category": "Transport"}]
    metrics = {"categoryDailyTarget": {"Transport": {"value": 40.0, "confidence": "medium"}}}
    primary, alternatives = run_recommendations(flags, metrics)
    check(
        "Category high pressure -> REDUCE_CATEGORY_SPENDING for Transport, actionValue from categoryDailyTarget",
        primary["code"] == "REDUCE_CATEGORY_SPENDING" and primary["type"] == "reduce" and primary["actionValue"] == 40.0,
        f"got {primary}",
    )

    # 3b. Goal at risk -> INCREASE_GOAL_CONTRIBUTION, actionValue is the
    # flag's own shortfall (never recomputed), goalName threaded through
    # exactly like category is for other codes (spec: Phase 19 Design).
    flags = [{
        "code": "GOAL_AT_RISK", "type": "goal_risk", "severity": "medium",
        "confidence": "medium", "source": "goalRisk",
        "goalId": "g1", "goalName": "Laptop", "shortfall": 12000.0,
    }]
    primary, alternatives = run_recommendations(flags, {})
    check(
        "Goal at risk -> INCREASE_GOAL_CONTRIBUTION, type protect, actionValue is the shortfall",
        primary["code"] == "INCREASE_GOAL_CONTRIBUTION"
        and primary["type"] == "protect"
        and primary["actionValue"] == 12000.0
        and primary["goalId"] == "g1"
        and primary["goalName"] == "Laptop"
        and primary["category"] is None
        and primary["expiresWhen"] == "Laptop is no longer at risk",
        f"got {primary}",
    )

    # 4. Projected deficit -> strongest recommendation wins over lower-priority alternatives
    flags = [
        {"code": "PROJECTED_DEFICIT", "type": "projection_risk", "severity": "critical", "confidence": "medium", "source": "projectedSavings"},
        {"code": "SPENDING_TOO_FAST", "type": "spending_risk", "severity": "low", "confidence": "high", "source": "spendingPace"},
    ]
    primary, alternatives = run_recommendations(flags, {})
    check(
        "Projected deficit -> START_RECOVERY_PLAN wins as primary",
        primary["code"] == "START_RECOVERY_PLAN" and primary["priority"] == 1,
        f"got {primary}",
    )
    check(
        "Lower-priority SLOW_SPENDING_PACE demoted to alternatives, priority 2",
        len(alternatives) == 1 and alternatives[0]["code"] == "SLOW_SPENDING_PACE" and alternatives[0]["priority"] == 2,
        f"got {alternatives}",
    )

    # 5. Multiple issues -> correct priority order preserved end to end
    flags = [
        {"code": "CATEGORY_EXHAUSTED", "type": "budget_risk", "severity": "high", "confidence": "medium", "source": "categoryHealth", "category": "Food"},
        {"code": "RECOVERY_NEEDED", "type": "recovery_risk", "severity": "medium", "confidence": "medium", "source": "recoveryPlan"},
        {"code": "SPENDING_TOO_FAST", "type": "spending_risk", "severity": "low", "confidence": "high", "source": "spendingPace"},
    ]
    metrics = {"recoveryPlan": {"dailyTarget": 90}}
    primary, alternatives = run_recommendations(flags, metrics)
    check(
        "Multiple issues -> priority order preserved exactly (Food stop, then recover, then slow)",
        [primary["code"]] + [a["code"] for a in alternatives] == [
            "STOP_CATEGORY_SPENDING", "LIMIT_DAILY_SPENDING", "SLOW_SPENDING_PACE",
        ]
        and [primary["priority"]] + [a["priority"] for a in alternatives] == [1, 2, 3],
        f"got {[primary['code']] + [a['code'] for a in alternatives]}",
    )

    # 6. Confidence propagation — each recommendation carries its flag's own confidence
    check(
        "Confidence propagation: STOP_CATEGORY_SPENDING carries CATEGORY_EXHAUSTED's confidence (medium)",
        primary["confidence"] == "medium",
        f"got {primary}",
    )
    check(
        "Confidence propagation: SLOW_SPENDING_PACE carries SPENDING_TOO_FAST's confidence (high)",
        alternatives[1]["confidence"] == "high",
        f"got {alternatives[1]}",
    )

    # 7. Decision trace (recommendationTrace)
    trace = _build_recommendation_trace(flags, [primary] + alternatives)
    check(
        "recommendationTrace mentions every trigger and its Matrix lookup",
        "Risk: CATEGORY_EXHAUSTED (Food)" in trace and "Matrix lookup: STOP_CATEGORY_SPENDING" in trace,
        f"got {trace}",
    )

    # 8. No duplicate recommendations — every code in the Matrix maps to exactly one row
    codes = [v["code"] for v in _RECOMMENDATION_MATRIX.values()]
    check(
        "No duplicate recommendation codes in the Matrix",
        len(codes) == len(set(codes)),
        f"got {codes}",
    )

    # 9. Every Risk Flag severity code has a Matrix row (the gap found before coding)
    # GOAL_AT_RISK now has one too (Phase 19, Goal Protection) -- no
    # exceptions remain.
    from services.health_engine import _RISK_SEVERITY
    missing = [code for code in _RISK_SEVERITY if code not in _RECOMMENDATION_MATRIX]
    check(
        "Every Risk Flag code has a Recommendation Matrix row (MULTIPLE_CATEGORIES_PRESSURED, CATEGORY_RECOVERABLE, GOAL_AT_RISK included)",
        missing == [],
        f"missing: {missing}",
    )

    # 10. Recommendation Type taxonomy — every code's type matches the frozen table
    expected_types = {
        "START_RECOVERY_PLAN": "recover",
        "ACCEPT_REDUCED_SAVINGS": "recover",
        "LIMIT_DAILY_SPENDING": "recover",
        "STOP_CATEGORY_SPENDING": "stop",
        "REDUCE_CATEGORY_SPENDING": "reduce",
        "REVIEW_MULTIPLE_CATEGORIES": "reduce",
        "MONITOR_CATEGORY_SPENDING": "monitor",
        "SLOW_SPENDING_PACE": "reduce",
        "INCREASE_GOAL_CONTRIBUTION": "protect",
        "KEEP_CURRENT_HABITS": "maintain",
    }
    actual_types = {v["code"]: v["type"] for v in _RECOMMENDATION_MATRIX.values()}
    actual_types["KEEP_CURRENT_HABITS"] = "maintain"
    check(
        "Every recommendation code's type matches the frozen taxonomy",
        actual_types == expected_types,
        f"got {actual_types}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Recommendation Engine scenarios passed.")


if __name__ == "__main__":
    run()
