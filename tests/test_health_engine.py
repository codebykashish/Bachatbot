"""
test_health_engine.py
=========================
Phase 3.1 (Overall Health) and Phase 3.2 (Category Health) acceptance
scenarios for the Health Engine — see FINANCIAL_ENGINE_SPEC.md. Pure rule
evaluation, no Firestore needed — every case constructs a synthetic
Metrics Engine response and runs it through the private pipeline stages
directly (the same treatment test_financial_engine.py gives
financial_engine.py's private pipeline functions).

Run directly: python tests/test_health_engine.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.health_engine import (
    _evaluate_rules,
    _collect_reasons,
    _determine_status,
    _evaluate_category_rules,
    _determine_category_status,
    _build_category_decision_trace,
    _determine_confidence,
    _build_health,
    _build_risk_flags,
)

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def run_health(metrics):
    triggered = _evaluate_rules(metrics)
    reasons = _collect_reasons(triggered)
    status = _determine_status(triggered)
    confidence = _determine_confidence(triggered)
    return _build_health(status, confidence, reasons)


def category_pressure(entries, priority_order):
    return {"byCategory": entries, "priorityOrder": priority_order}


def run():
    print("Overall Health — test matrix")

    # 1. Everything healthy -> green
    healthy = {
        "spendingPace": {"status": "on_pace", "confidence": "high"},
        "recoveryPlan": None,
        "categoryPressure": category_pressure(
            {"Food": {"status": "normal", "material": True, "confidence": "high"}},
            ["Food"],
        ),
        "projectedSavings": {"value": 500, "confidence": "medium"},
    }
    result = run_health(healthy)
    check(
        "Everything healthy -> green, no reasons",
        result == {"status": "green", "confidence": "high", "primaryReason": None, "reasons": []},
        f"got {result}",
    )

    # 2. Spending too fast only -> amber
    too_fast = dict(healthy, spendingPace={"status": "too_fast", "confidence": "high"})
    result = run_health(too_fast)
    check(
        "Spending too fast only -> amber",
        result == {
            "status": "amber", "confidence": "high", "primaryReason": {"code": "SPENDING_TOO_FAST", "source": "spendingPace"},
            "reasons": [{"code": "SPENDING_TOO_FAST", "source": "spendingPace"}],
        },
        f"got {result}",
    )

    # 3. One pressured (material, high) category -> amber
    one_pressured = dict(healthy, categoryPressure=category_pressure(
        {"Food": {"status": "high", "material": True, "confidence": "high"}}, ["Food"],
    ))
    result = run_health(one_pressured)
    check(
        "One pressured material category -> amber, FOOD_HIGH_PRESSURE",
        result["status"] == "amber"
        and result["reasons"] == [{"code": "FOOD_HIGH_PRESSURE", "source": "categoryPressure"}],
        f"got {result}",
    )

    # 4. Multiple pressured categories -> amber, MULTIPLE_CATEGORIES_PRESSURED + per-category code
    multiple_pressured = dict(healthy, categoryPressure=category_pressure(
        {
            "Food": {"status": "high", "material": True, "confidence": "high"},
            "Transport": {"status": "medium", "material": True, "confidence": "high"},
        },
        ["Food", "Transport"],
    ))
    result = run_health(multiple_pressured)
    check(
        "Multiple pressured categories -> amber, MULTIPLE_CATEGORIES_PRESSURED before FOOD_HIGH_PRESSURE",
        result["status"] == "amber"
        and result["reasons"] == [
            {"code": "MULTIPLE_CATEGORIES_PRESSURED", "source": "categoryPressure"},
            {"code": "FOOD_HIGH_PRESSURE", "source": "categoryPressure"},
        ],
        f"got {result}",
    )

    # 5. Recovery needed (still possible) -> amber
    recovery_needed = dict(healthy, recoveryPlan={
        "needed": True, "recoveryPossible": True, "severity": "minor", "confidence": "medium",
    })
    result = run_health(recovery_needed)
    check(
        "Recovery needed (possible) -> amber, RECOVERY_NEEDED",
        result["status"] == "amber"
        and result["reasons"] == [{"code": "RECOVERY_NEEDED", "source": "recoveryPlan"}],
        f"got {result}",
    )

    # 6. Recovery impossible -> red
    recovery_impossible = dict(healthy, recoveryPlan={
        "needed": True, "recoveryPossible": False, "severity": "high", "confidence": "medium",
    })
    result = run_health(recovery_impossible)
    check(
        "Recovery impossible -> red, RECOVERY_IMPOSSIBLE",
        result["status"] == "red"
        and result["reasons"] == [{"code": "RECOVERY_IMPOSSIBLE", "source": "recoveryPlan"}],
        f"got {result}",
    )

    # 7. Projected deficit -> red
    deficit = dict(healthy, projectedSavings={"value": -200, "confidence": "low"})
    result = run_health(deficit)
    check(
        "Projected deficit -> red, PROJECTED_DEFICIT",
        result["status"] == "red"
        and result["reasons"] == [{"code": "PROJECTED_DEFICIT", "source": "projectedSavings"}],
        f"got {result}",
    )

    # 8. Multiple simultaneous reasons -> correct frozen priority order
    everything_wrong = {
        "spendingPace": {"status": "too_fast", "confidence": "high"},
        "recoveryPlan": {"needed": True, "recoveryPossible": True, "severity": "medium", "confidence": "medium"},
        "categoryPressure": category_pressure(
            {"Food": {"status": "high", "material": True, "confidence": "high"}}, ["Food"],
        ),
        "projectedSavings": {"value": -100, "confidence": "medium"},
    }
    result = run_health(everything_wrong)
    check(
        "Multiple simultaneous reasons -> red, frozen priority order",
        result["status"] == "red"
        and [r["code"] for r in result["reasons"]] == [
            "PROJECTED_DEFICIT", "RECOVERY_NEEDED", "FOOD_HIGH_PRESSURE", "SPENDING_TOO_FAST",
        ],
        f"got {[r['code'] for r in result['reasons']]}",
    )
    check(
        "primaryReason always equals reasons[0]",
        result["primaryReason"] == result["reasons"][0],
        f"got {result['primaryReason']} vs {result['reasons'][0]}",
    )

    # 9. Confidence mix -> lowest confidence wins
    mixed_confidence = dict(healthy,
        spendingPace={"status": "too_fast", "confidence": "high"},
        categoryPressure=category_pressure(
            {"Food": {"status": "high", "material": True, "confidence": "high"}}, ["Food"],
        ),
        recoveryPlan={"needed": True, "recoveryPossible": True, "severity": "minor", "confidence": "medium"},
    )
    result = run_health(mixed_confidence)
    check(
        "Confidence mix (high, high, medium) -> overall confidence is medium, the lowest",
        result["confidence"] == "medium",
        f"got {result['confidence']}",
    )

    # 10. Materiality threshold -> a non-material high-pressure category is ignored entirely
    tiny_category_high = dict(healthy, categoryPressure=category_pressure(
        {
            "Food": {"status": "high", "material": False, "confidence": "high"},
            "Transport": {"status": "normal", "material": True, "confidence": "high"},
        },
        ["Food", "Transport"],
    ))
    result = run_health(tiny_category_high)
    check(
        "Materiality threshold: non-material high-pressure category -> green, no reasons",
        result == {"status": "green", "confidence": "high", "primaryReason": None, "reasons": []},
        f"got {result}",
    )

    # Phase 3.1 Review, check 3 — contradictory outputs should never
    # happen. Scanned across every scenario above rather than asserted
    # once, since a contradiction could in principle only show up for
    # some input combinations.
    print()
    print("Contradiction scan (Phase 3.1 Review, check 3)")

    all_scenarios = [
        healthy, too_fast, one_pressured, multiple_pressured, recovery_needed,
        recovery_impossible, deficit, everything_wrong, mixed_confidence, tiny_category_high,
    ]
    for i, scenario_metrics in enumerate(all_scenarios):
        r = run_health(scenario_metrics)
        codes = [reason["code"] for reason in r["reasons"]]

        check(
            f"Scenario {i}: green implies zero reasons and no primaryReason",
            not (r["status"] == "green" and (r["reasons"] or r["primaryReason"] is not None)),
            f"got {r}",
        )
        check(
            f"Scenario {i}: non-green always carries at least one reason",
            not (r["status"] != "green" and not r["reasons"]),
            f"got {r}",
        )
        check(
            f"Scenario {i}: PROJECTED_DEFICIT or RECOVERY_IMPOSSIBLE present implies status is red",
            not (("PROJECTED_DEFICIT" in codes or "RECOVERY_IMPOSSIBLE" in codes) and r["status"] != "red"),
            f"got {r}",
        )
        check(
            f"Scenario {i}: red always has PROJECTED_DEFICIT or RECOVERY_IMPOSSIBLE among its reasons",
            not (r["status"] == "red" and "PROJECTED_DEFICIT" not in codes and "RECOVERY_IMPOSSIBLE" not in codes),
            f"got {r}",
        )
        check(
            f"Scenario {i}: primaryReason always equals reasons[0] when reasons is non-empty",
            r["primaryReason"] == (r["reasons"][0] if r["reasons"] else None),
            f"got {r}",
        )

    print()
    print("Category Health — test matrix")

    def run_category(pressure_entry, exhausted, cat="Food"):
        code, source, confidence = _evaluate_category_rules(cat, pressure_entry, exhausted)
        status = _determine_category_status(code)
        trace = _build_category_decision_trace(
            pressure_entry.get("material", False), cat in exhausted, pressure_entry.get("status")
        )
        return code, source, confidence, status, trace

    # 1. Normal category -> Green, CATEGORY_NORMAL
    code, source, confidence, status, trace = run_category(
        {"status": "normal", "material": True, "confidence": "high"}, {}
    )
    check(
        "Normal category -> green, CATEGORY_NORMAL",
        (code, status) == ("CATEGORY_NORMAL", "green"),
        f"got {(code, status)}",
    )

    # 2. High pressure -> Amber, CATEGORY_HIGH_PRESSURE
    code, source, confidence, status, trace = run_category(
        {"status": "high", "material": True, "confidence": "high"}, {}
    )
    check(
        "High pressure -> amber, CATEGORY_HIGH_PRESSURE",
        (code, status) == ("CATEGORY_HIGH_PRESSURE", "amber"),
        f"got {(code, status)}",
    )

    # Medium pressure -> Amber, CATEGORY_RECOVERABLE
    code, source, confidence, status, trace = run_category(
        {"status": "medium", "material": True, "confidence": "high"}, {}
    )
    check(
        "Medium pressure -> amber, CATEGORY_RECOVERABLE",
        (code, status) == ("CATEGORY_RECOVERABLE", "amber"),
        f"got {(code, status)}",
    )

    # Low pressure -> Green, LOW_ACTIVITY
    code, source, confidence, status, trace = run_category(
        {"status": "low", "material": True, "confidence": "high"}, {}
    )
    check(
        "Low pressure -> green, LOW_ACTIVITY",
        (code, status) == ("LOW_ACTIVITY", "green"),
        f"got {(code, status)}",
    )

    # 3. Exhausted category -> Red, CATEGORY_EXHAUSTED, confidence propagates from recoveryPlan
    code, source, confidence, status, trace = run_category(
        {"status": "high", "material": True, "confidence": "high"}, {"Food": "medium"}
    )
    check(
        "Exhausted category -> red, CATEGORY_EXHAUSTED, confidence from recoveryPlan (medium)",
        (code, source, confidence, status) == ("CATEGORY_EXHAUSTED", "recoveryPlan", "medium", "red"),
        f"got {(code, source, confidence, status)}",
    )

    # 4. Tiny (non-material) category never escalates, even if also exhausted
    code, source, confidence, status, trace = run_category(
        {"status": "high", "material": False, "confidence": "high"}, {"Food": "medium"}
    )
    check(
        "Non-material category -> green, LOW_MATERIALITY, materiality gates before exhaustion",
        (code, status) == ("LOW_MATERIALITY", "green"),
        f"got {(code, status)}",
    )

    # 5. Multiple categories -> independent results
    food_result = run_category({"status": "high", "material": True, "confidence": "high"}, {}, cat="Food")
    transport_result = run_category({"status": "low", "material": True, "confidence": "high"}, {}, cat="Transport")
    check(
        "Multiple categories: independent results",
        food_result[0] == "CATEGORY_HIGH_PRESSURE" and transport_result[0] == "LOW_ACTIVITY",
        f"got Food={food_result[0]}, Transport={transport_result[0]}",
    )

    # 7. Decision trace matches the triggered rule
    _, _, _, _, trace_exhausted = run_category(
        {"status": "high", "material": True, "confidence": "high"}, {"Food": "medium"}
    )
    check(
        "Decision trace for exhausted category stops after exhaustion check",
        trace_exhausted == ["Materiality checked — material", "Exhaustion checked — exhausted"],
        f"got {trace_exhausted}",
    )
    _, _, _, _, trace_normal = run_category(
        {"status": "normal", "material": True, "confidence": "high"}, {}
    )
    check(
        "Decision trace for normal category includes all three checks",
        trace_normal == [
            "Materiality checked — material",
            "Exhaustion checked — not exhausted",
            "Category Pressure checked — normal",
        ],
        f"got {trace_normal}",
    )
    _, _, _, _, trace_tiny = run_category(
        {"status": "high", "material": False, "confidence": "high"}, {}
    )
    check(
        "Decision trace for non-material category stops after materiality check",
        trace_tiny == ["Materiality checked — not material"],
        f"got {trace_tiny}",
    )

    print()
    print("Risk Flags — test matrix")

    # 1. Healthy account -> no risk flags
    flags = _build_risk_flags(healthy)
    check("Healthy account -> no risk flags", flags == [], f"got {flags}")

    # 2. One exhausted category -> one Budget Risk (CATEGORY_EXHAUSTED)
    exhausted_metrics = {
        "spendingPace": {"status": "on_pace", "confidence": "high"},
        "recoveryPlan": {
            "needed": True, "recoveryPossible": False, "severity": "high",
            "confidence": "medium", "affectedCategories": ["Food"],
        },
        "categoryPressure": category_pressure(
            {"Food": {"status": "high", "material": True, "confidence": "high"}}, ["Food"],
        ),
        "projectedSavings": {"value": 500, "confidence": "medium"},
    }
    flags = _build_risk_flags(exhausted_metrics)
    # Note: an exhausted category also legitimately triggers a global
    # RECOVERY_IMPOSSIBLE/RECOVERY_NEEDED flag (Recovery Plan itself is
    # partly driven by category exhaustion) — that's correct, not a
    # duplicate. The real invariant is no "FOOD_HIGH_PRESSURE" duplicate.
    check(
        "One exhausted category -> a Budget Risk (CATEGORY_EXHAUSTED) for Food exists",
        any(f["code"] == "CATEGORY_EXHAUSTED" and f.get("category") == "Food" for f in flags),
        f"got {flags}",
    )
    check(
        "One exhausted category -> no duplicate FOOD_HIGH_PRESSURE flag",
        not any(f["code"] == "FOOD_HIGH_PRESSURE" for f in flags),
        f"got {flags}",
    )

    # 3. Projected deficit -> Projection Risk
    flags = _build_risk_flags(deficit)
    check(
        "Projected deficit -> Projection Risk, critical",
        flags == [{
            "code": "PROJECTED_DEFICIT", "type": "projection_risk", "severity": "critical",
            "confidence": "low", "source": "projectedSavings",
        }],
        f"got {flags}",
    )

    # 4. Goal at risk -> Goal Risk — intentionally NOT tested: no engine
    # through Phase 3.2 computes goal risk yet (spec: Phase 3.3 Design,
    # "Goal Risk — explicitly deferred, not built").

    # 5. Multiple risks -> correct severity ordering (critical, then medium, then low)
    multi_risk_metrics = {
        "spendingPace": {"status": "too_fast", "confidence": "high"},
        "recoveryPlan": {
            "needed": True, "recoveryPossible": True, "severity": "medium",
            "confidence": "medium", "affectedCategories": [],
        },
        "categoryPressure": category_pressure(
            {"Food": {"status": "high", "material": True, "confidence": "high"}}, ["Food"],
        ),
        "projectedSavings": {"value": -100, "confidence": "medium"},
    }
    flags = _build_risk_flags(multi_risk_metrics)
    check(
        "Multiple risks -> correct severity ordering (critical, medium x2, low)",
        [f["severity"] for f in flags] == ["critical", "medium", "medium", "low"],
        f"got {[(f['code'], f['severity']) for f in flags]}",
    )
    check(
        "Multiple risks -> highest-severity flag is PROJECTED_DEFICIT",
        flags[0]["code"] == "PROJECTED_DEFICIT",
        f"got {flags[0]}",
    )

    # 6. Confidence propagation — each flag carries its own source's confidence
    check(
        "Confidence propagation: RECOVERY_NEEDED carries recoveryPlan's confidence (medium)",
        next(f["confidence"] for f in flags if f["code"] == "RECOVERY_NEEDED") == "medium",
        f"got {flags}",
    )
    check(
        "Confidence propagation: CATEGORY_HIGH_PRESSURE carries categoryPressure's confidence (high)",
        next(f["confidence"] for f in flags if f["code"] == "CATEGORY_HIGH_PRESSURE") == "high",
        f"got {flags}",
    )

    # 7. No duplicate per-category flags — Overall Health's own
    # "<CATEGORY>_HIGH_PRESSURE" code must never also appear as a flag
    codes = [f["code"] for f in flags]
    check(
        "No duplicate per-category flags: FOOD_HIGH_PRESSURE (Overall Health's own code) never appears",
        "FOOD_HIGH_PRESSURE" not in codes,
        f"got {codes}",
    )
    check(
        "No duplicate per-category flags: exactly one Food-related flag",
        sum(1 for f in flags if f.get("category") == "Food") == 1,
        f"got {flags}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Overall Health, Category Health, and Risk Flags scenarios passed.")


if __name__ == "__main__":
    run()
