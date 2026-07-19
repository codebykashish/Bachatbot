"""
services/health_engine.py
=============================
The Health Engine — Phase 3.1 (Overall Health), Phase 3.2 (Category
Health), and Phase 3.3 (Risk Flags). Judgment layer on top of the
Metrics Engine. See FINANCIAL_ENGINE_SPEC.md "Phase 3.0 — Health
Philosophy," "Phase 3.1 — Overall Health," "Phase 3.2 — Category
Health," and "Phase 3.3 — Risk Flags."

Four frozen rules (spec: Phase 3.0), apply to all three:
  1. Health never computes financial values — it only reads already-
     classified Metrics Engine outputs (plus Category Pressure's
     Fact-derived `material` flag; the arithmetic behind that flag lives
     in metrics_engine.py, never here).
  2. Health is an interpretation, not a recommendation — it never
     suggests an action, that's Phase 4's job.
  3. Health must always be able to explain itself — every non-green
     status carries reason codes, never a bare score.
  4. No hidden weights — status is decided by a rule-based waterfall,
     never a weighted sum.

Three public functions:
  compute_overall_health()   Pipeline: _load_metrics -> _validate_metrics
                              -> _evaluate_rules -> _collect_reasons ->
                              _determine_status -> _determine_confidence
                              -> _build_decision_trace -> _build_health
  compute_category_health()  Per category, reuses _determine_confidence
                              and _build_health unchanged (spec: Phase
                              3.2 Design — reuse the pipeline pieces,
                              don't build a second engine from scratch);
                              only the per-category waterfall and trace
                              are new.
  compute_risk_flags()       Reuses _evaluate_rules and
                              _evaluate_category_rules directly (their
                              per-condition confidence, not the public,
                              already-aggregated reason arrays), maps
                              each already-true condition to a
                              (type, severity) pair via a frozen lookup
                              table — never a new calculation (spec:
                              Phase 3.3 Design).

Every pipeline stage is private; each public function returns exactly
one object. Nothing here is persisted — every call recomputes fresh
from the Metrics Engine (spec: Phase 3.3, "computed on demand").
"""

import time
from datetime import datetime, timezone

from services.metrics_engine import get_metrics, METRICS_ENGINE_VERSION

HEALTH_ENGINE_VERSION = "1.0.0"

# Frozen priority order (spec: Phase 3.1 Design) — `reasons` is always
# emitted in this order, never evaluation order, so two calls with
# identical inputs always produce an identical reasons array. Per-
# category codes ("FOOD_HIGH_PRESSURE") sort at the CATEGORY_HIGH_PRESSURE
# slot, in Category Pressure's own priorityOrder among themselves.
_REASON_PRIORITY = [
    "PROJECTED_DEFICIT",
    "RECOVERY_IMPOSSIBLE",
    "RECOVERY_NEEDED",
    "MULTIPLE_CATEGORIES_PRESSURED",
    "CATEGORY_HIGH_PRESSURE",
    "SPENDING_TOO_FAST",
]

_CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}


def _load_metrics(db, uid: str, month_key: str = None) -> dict:
    return get_metrics(db, uid, month_key)


def _validate_metrics(metrics: dict) -> dict:
    """
    Defensive only — every field here already comes from a Phase 2
    metric with its own null-handling; this just guards against a
    completely malformed input, never re-derives anything.
    """
    return metrics or {}


def _evaluate_rules(metrics: dict) -> list:
    """
    Returns every TRUE condition as (code, source, confidence) — not
    just the one that ends up deciding `status`. See spec: "Status vs.
    reasons — first-match-wins decides the color, but every true
    condition is reported."
    """
    triggered = []

    projected_savings = metrics.get("projectedSavings")
    if projected_savings is not None and projected_savings.get("value", 0) < 0:
        triggered.append((
            "PROJECTED_DEFICIT", "projectedSavings",
            projected_savings.get("confidence", "low"),
        ))

    recovery_plan = metrics.get("recoveryPlan")
    if recovery_plan is not None:
        if recovery_plan.get("recoveryPossible") is False:
            triggered.append((
                "RECOVERY_IMPOSSIBLE", "recoveryPlan",
                recovery_plan.get("confidence", "medium"),
            ))
        else:
            triggered.append((
                "RECOVERY_NEEDED", "recoveryPlan",
                recovery_plan.get("confidence", "medium"),
            ))

    category_pressure = metrics.get("categoryPressure")
    if category_pressure is not None:
        by_category = category_pressure.get("byCategory", {}) or {}
        priority_order = category_pressure.get("priorityOrder", []) or []
        material = {
            cat: data for cat, data in by_category.items() if data.get("material")
        }

        # "Multiple" means more than one — a single material category,
        # however pressured, is never MULTIPLE_CATEGORIES_PRESSURED on
        # its own (spec: Phase 3.0, Q5).
        if len(material) >= 2 and all(
            data.get("status") in ("medium", "high") for data in material.values()
        ):
            triggered.append(("MULTIPLE_CATEGORIES_PRESSURED", "categoryPressure", "high"))

        for cat in priority_order:
            data = material.get(cat)
            if data and data.get("status") == "high":
                triggered.append((
                    f"{cat.upper()}_HIGH_PRESSURE", "categoryPressure",
                    data.get("confidence", "high"),
                ))

    spending_pace = metrics.get("spendingPace")
    if spending_pace is not None and spending_pace.get("status") == "too_fast":
        triggered.append((
            "SPENDING_TOO_FAST", "spendingPace",
            spending_pace.get("confidence", "high"),
        ))

    return triggered


def _reason_sort_key(reason: tuple, index: dict) -> tuple:
    code = reason[0]
    if code in _REASON_PRIORITY:
        return (_REASON_PRIORITY.index(code), 0)
    # Per-category codes sort at the CATEGORY_HIGH_PRESSURE slot, in the
    # relative order _evaluate_rules already appended them (Category
    # Pressure's own priorityOrder) — Python's sort is stable, so this
    # tiebreak only matters against other priority tiers, not among
    # per-category codes themselves.
    return (_REASON_PRIORITY.index("CATEGORY_HIGH_PRESSURE"), index.get(code, 0))


def _collect_reasons(triggered: list) -> list:
    index = {code: i for i, (code, _s, _c) in enumerate(triggered)}
    ordered = sorted(triggered, key=lambda r: _reason_sort_key(r, index))
    return [{"code": code, "source": source} for code, source, _confidence in ordered]


def _determine_status(triggered: list) -> str:
    codes = {code for code, _source, _confidence in triggered}
    if "PROJECTED_DEFICIT" in codes or "RECOVERY_IMPOSSIBLE" in codes:
        return "red"
    if codes:
        return "amber"
    return "green"


def _determine_confidence(triggered: list) -> str:
    """
    "Weakest link" — the lowest confidence among whichever metrics
    actually triggered a reason, never a new judgment (spec: Phase 3.1
    Design). Green (nothing triggered) defaults to high: nothing found a
    problem, and Category Pressure/Spending Pace (the metrics that would
    have caught one) are themselves always high confidence.
    """
    if not triggered:
        return "high"
    return min(
        (confidence for _code, _source, confidence in triggered),
        key=lambda c: _CONFIDENCE_RANK.get(c, 1),
    )


def _build_decision_trace(metrics: dict, triggered: list) -> list:
    """
    Phase 1's decisionLog, for interpretation instead of money — an
    ordered record of what was checked and what was found, in the same
    order as the frozen reason priority. Debug-only, never shown to the
    user (spec: Phase 3.1 Design).
    """
    codes = {code for code, _s, _c in triggered}
    trace = []

    projected_savings = metrics.get("projectedSavings")
    if projected_savings is None:
        trace.append("Projected Savings checked — no budgets, skipped")
    elif "PROJECTED_DEFICIT" in codes:
        trace.append("Projected Savings checked — deficit projected")
    else:
        trace.append("Projected Savings checked — no deficit")

    recovery_plan = metrics.get("recoveryPlan")
    if recovery_plan is None:
        trace.append("Recovery Plan checked — not needed")
    elif "RECOVERY_IMPOSSIBLE" in codes:
        trace.append("Recovery Plan checked — recovery impossible")
    else:
        trace.append("Recovery Plan checked — recovery needed but possible")

    category_pressure = metrics.get("categoryPressure")
    if category_pressure is None:
        trace.append("Category Pressure checked — no budgets, skipped")
    else:
        pressured = sorted(code for code in codes if code.endswith("_HIGH_PRESSURE"))
        if "MULTIPLE_CATEGORIES_PRESSURED" in codes:
            trace.append("Category Pressure checked — multiple material categories pressured")
        elif pressured:
            trace.append(f"Category Pressure checked — {', '.join(pressured)}")
        else:
            trace.append("Category Pressure checked — no material category under high pressure")

    spending_pace = metrics.get("spendingPace")
    if spending_pace is None:
        trace.append("Spending Pace checked — no budgets, skipped")
    elif "SPENDING_TOO_FAST" in codes:
        trace.append("Spending Pace checked — too fast")
    else:
        trace.append(f"Spending Pace checked — {spending_pace.get('status')}")

    return trace


def _build_health(status: str, confidence: str, reasons: list) -> dict:
    primary_reason = reasons[0] if reasons else None
    return {
        "status": status,
        "confidence": confidence,
        "primaryReason": primary_reason,
        "reasons": reasons,
    }


def compute_overall_health(db, uid: str, month_key: str = None) -> dict:
    """
    Public API — the only function anything outside this module calls.
    Returns exactly one object: {overallHealth, decisionTrace, metadata}.
    No intermediate pipeline stage is ever exposed.
    """
    start = time.perf_counter()

    metrics = _load_metrics(db, uid, month_key)
    metrics = _validate_metrics(metrics)

    triggered = _evaluate_rules(metrics)
    reasons = _collect_reasons(triggered)
    status = _determine_status(triggered)
    confidence = _determine_confidence(triggered)
    trace = _build_decision_trace(metrics, triggered)

    overall_health = _build_health(status, confidence, reasons)

    generation_ms = round((time.perf_counter() - start) * 1000, 2)

    return {
        "overallHealth": overall_health,
        "decisionTrace": trace,
        "metadata": {
            "healthEngineVersion": HEALTH_ENGINE_VERSION,
            "metricsEngineVersion": METRICS_ENGINE_VERSION,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "generationMs": generation_ms,
        },
    }


def _evaluate_category_rules(cat: str, pressure_entry: dict, exhausted: dict) -> tuple:
    """
    Waterfall for one category (spec: Phase 3.2 Design). Materiality
    gates first (a non-material category never escalates); exhaustion
    (sourced from Recovery Plan's affectedCategories) overrides pressure;
    otherwise a direct mapping from Category Pressure's own four
    statuses. Returns exactly one (code, source, confidence) — unlike
    Overall Health, exhaustion and high pressure are nearly the same
    fact wearing two names within a single category, so collecting both
    would be near-redundant, not informative.
    """
    if not pressure_entry.get("material"):
        return ("LOW_MATERIALITY", "categoryPressure", pressure_entry.get("confidence", "high"))

    if cat in exhausted:
        # Sourced from Recovery Plan, not Category Pressure — carries
        # Recovery Plan's own confidence for this call.
        return ("CATEGORY_EXHAUSTED", "recoveryPlan", exhausted[cat])

    status = pressure_entry.get("status")
    confidence = pressure_entry.get("confidence", "high")
    if status == "high":
        return ("CATEGORY_HIGH_PRESSURE", "categoryPressure", confidence)
    if status == "medium":
        return ("CATEGORY_RECOVERABLE", "categoryPressure", confidence)
    if status == "low":
        return ("LOW_ACTIVITY", "categoryPressure", confidence)
    return ("CATEGORY_NORMAL", "categoryPressure", confidence)


def _determine_category_status(code: str) -> str:
    if code == "CATEGORY_EXHAUSTED":
        return "red"
    if code in ("CATEGORY_HIGH_PRESSURE", "CATEGORY_RECOVERABLE"):
        return "amber"
    return "green"


def _build_category_decision_trace(material: bool, exhausted: bool, status: str) -> list:
    """
    Same treatment as _build_decision_trace, scoped to one category —
    debug-only, never shown to the user.
    """
    trace = [f"Materiality checked — {'material' if material else 'not material'}"]
    if not material:
        return trace
    trace.append(f"Exhaustion checked — {'exhausted' if exhausted else 'not exhausted'}")
    if exhausted:
        return trace
    trace.append(f"Category Pressure checked — {status}")
    return trace


def compute_category_health(db, uid: str, month_key: str = None) -> dict:
    """
    Public API — the per-category counterpart to compute_overall_health.
    Reuses _determine_confidence and _build_health unchanged; only the
    per-category waterfall and trace are new (spec: Phase 3.2 Design).

    Returns {"categoryHealth": None, ...} if there's no Category
    Pressure at all (no budgets) — nothing to report per category either.
    """
    start = time.perf_counter()

    metrics = _load_metrics(db, uid, month_key)
    metrics = _validate_metrics(metrics)

    category_pressure = metrics.get("categoryPressure")
    category_health = None

    if category_pressure is not None:
        by_category = category_pressure.get("byCategory", {}) or {}

        recovery_plan = metrics.get("recoveryPlan")
        exhausted = {}
        if recovery_plan is not None:
            confidence = recovery_plan.get("confidence", "medium")
            for cat in recovery_plan.get("affectedCategories", []) or []:
                exhausted[cat] = confidence

        category_health = {}
        for cat, pressure_entry in by_category.items():
            code, source, confidence = _evaluate_category_rules(cat, pressure_entry, exhausted)
            status = _determine_category_status(code)
            reasons = [{"code": code, "source": source}]
            # Reused unchanged — trivially "weakest of one" here, since
            # the waterfall is mutually exclusive (exactly one source
            # contributes per category), but the same function Overall
            # Health uses, not a re-derivation of the same rule.
            confidence = _determine_confidence([(code, source, confidence)])
            health = _build_health(status, confidence, reasons)
            health["decisionTrace"] = _build_category_decision_trace(
                pressure_entry.get("material", False), cat in exhausted, pressure_entry.get("status")
            )
            category_health[cat] = health

    generation_ms = round((time.perf_counter() - start) * 1000, 2)

    return {
        "categoryHealth": category_health,
        "metadata": {
            "healthEngineVersion": HEALTH_ENGINE_VERSION,
            "metricsEngineVersion": METRICS_ENGINE_VERSION,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "generationMs": generation_ms,
        },
    }


# Frozen lookup (spec: Phase 3.3 Design) — an already-computed reason
# code maps directly to a risk type + severity. Never a weighted score.
# Codes not listed here (CATEGORY_NORMAL, LOW_ACTIVITY, LOW_MATERIALITY)
# are reassuring, not risks, and never become a flag.
_RISK_SEVERITY = {
    "PROJECTED_DEFICIT": ("projection_risk", "critical"),
    "RECOVERY_IMPOSSIBLE": ("recovery_risk", "critical"),
    "CATEGORY_EXHAUSTED": ("budget_risk", "high"),
    "RECOVERY_NEEDED": ("recovery_risk", "medium"),
    "MULTIPLE_CATEGORIES_PRESSURED": ("budget_risk", "medium"),
    "CATEGORY_HIGH_PRESSURE": ("budget_risk", "medium"),
    "SPENDING_TOO_FAST": ("spending_risk", "low"),
    "CATEGORY_RECOVERABLE": ("budget_risk", "info"),
}

_SEVERITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}


def _build_risk_flags(metrics: dict) -> list:
    """
    Pure — takes an already-loaded Metrics Engine response and returns
    the risk flags list. Separated from compute_risk_flags() so it can
    be tested directly against synthetic metrics, the same treatment
    _evaluate_rules() gets (no Firestore needed to test the rules).

    Reuses _evaluate_rules()/_evaluate_category_rules() directly (their
    per-condition confidence, not the public reasons arrays, which
    compress confidence to one aggregate) — no new calculation, per
    Rule 1. Per-category risks are sourced from
    _evaluate_category_rules() only, never duplicated from Overall
    Health's own "<CATEGORY>_HIGH_PRESSURE" codes — those are excluded
    here so an exhausted category doesn't produce two near-duplicate
    flags from two different sources describing the same fact.
    """
    flags = []

    overall_triggered = _evaluate_rules(metrics)
    for code, source, confidence in overall_triggered:
        if code.endswith("_HIGH_PRESSURE"):
            continue  # superseded by Category Health's per-category evaluation below
        if code not in _RISK_SEVERITY:
            continue
        risk_type, severity = _RISK_SEVERITY[code]
        flags.append({
            "code": code, "type": risk_type, "severity": severity,
            "confidence": confidence, "source": source,
        })

    category_pressure = metrics.get("categoryPressure")
    if category_pressure is not None:
        by_category = category_pressure.get("byCategory", {}) or {}
        priority_order = category_pressure.get("priorityOrder", []) or []

        recovery_plan = metrics.get("recoveryPlan")
        exhausted = {}
        if recovery_plan is not None:
            recovery_confidence = recovery_plan.get("confidence", "medium")
            for cat in recovery_plan.get("affectedCategories", []) or []:
                exhausted[cat] = recovery_confidence

        for cat in priority_order:
            pressure_entry = by_category.get(cat)
            if pressure_entry is None:
                continue
            code, source, confidence = _evaluate_category_rules(cat, pressure_entry, exhausted)
            if code not in _RISK_SEVERITY:
                continue
            risk_type, severity = _RISK_SEVERITY[code]
            flags.append({
                "code": code, "type": risk_type, "severity": severity,
                "confidence": confidence, "source": "categoryHealth", "category": cat,
            })

    # Stable sort — ties (same severity) keep the order already built
    # above: global risks first (in _evaluate_rules' fixed order), then
    # categories in Category Pressure's own priorityOrder.
    flags.sort(key=lambda f: _SEVERITY_RANK.get(f["severity"], 5))
    return flags


def compute_risk_flags(db, uid: str, month_key: str = None) -> dict:
    """
    Public API — "is there something worth noticing?" See
    _build_risk_flags() for the actual rule logic; this function only
    loads metrics and wraps the result with metadata (spec: Phase 3.3
    Design — computed on demand, nothing persisted).
    """
    start = time.perf_counter()

    metrics = _load_metrics(db, uid, month_key)
    metrics = _validate_metrics(metrics)

    flags = _build_risk_flags(metrics)

    generation_ms = round((time.perf_counter() - start) * 1000, 2)

    return {
        "riskFlags": flags,
        "metadata": {
            "healthEngineVersion": HEALTH_ENGINE_VERSION,
            "metricsEngineVersion": METRICS_ENGINE_VERSION,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "generationMs": generation_ms,
        },
    }
