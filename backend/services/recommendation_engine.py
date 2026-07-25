"""
services/recommendation_engine.py
=============================
The Recommendation Engine — Phase 4. Chooses one best next action.
See FINANCIAL_ENGINE_SPEC.md "Phase 4.0 — Recommendation Philosophy."

Five frozen rules (spec: Phase 4.0):
  1. Never change money — this module only reads, never writes, never
     calls financial_engine.recompute().
  2. Recommend actions, not observations — every recommendation names a
     next step, never restates a Health/Risk Flag reason.
  3. One recommendation per problem — exactly one primaryRecommendation,
     everything else is an alternative, never a checklist.
  4. Achievable, grounded in existing metrics — every actionValue is
     read directly from a Metrics Engine field, never computed here.
  5. Explainable via traceability — every recommendation carries
     generatedFrom/source; the response also carries a mechanical
     recommendationTrace (the same philosophy as decisionLog/decisionTrace).

Pipeline: Load Risk Flags -> Validate -> Matrix Lookup -> Build
Recommendation Object -> Sort (inherited from Risk Flags' own ordering,
never recomputed) -> Return. No calculation, no money, no thresholds.

Only compute_recommendations() is public.
"""

import time
from datetime import datetime, timezone

from services.health_engine import compute_risk_flags, HEALTH_ENGINE_VERSION
from services.metrics_engine import get_metrics, METRICS_ENGINE_VERSION

RECOMMENDATION_ENGINE_VERSION = "1.0.0"

# The Recommendation Matrix (spec: Phase 4.0 Design) — the only place a
# trigger code maps to a recommendation. Extending this dict is the only
# way a new recommendation is ever added; verified to cover every code
# health_engine.py's _RISK_SEVERITY table can produce.
_RECOMMENDATION_MATRIX = {
    "PROJECTED_DEFICIT": {
        "code": "START_RECOVERY_PLAN",
        "type": "recover",
        "actionUnit": None,
        "source": "projectedSavings",
        "expiresWhen": "Projected Savings is no longer negative",
    },
    "RECOVERY_IMPOSSIBLE": {
        "code": "ACCEPT_REDUCED_SAVINGS",
        "type": "recover",
        "actionUnit": None,
        "source": "recoveryPlan",
        "expiresWhen": "Recovery becomes possible again",
    },
    "RECOVERY_NEEDED": {
        "code": "LIMIT_DAILY_SPENDING",
        "type": "recover",
        "actionUnit": "per_day",
        "source": "recoveryPlan",
        "expiresWhen": "Recovery Plan is no longer needed",
    },
    "CATEGORY_EXHAUSTED": {
        "code": "STOP_CATEGORY_SPENDING",
        "type": "stop",
        "actionUnit": "per_day",
        "source": "categoryHealth",
        "expiresWhen": "{category} is no longer exhausted",
    },
    "CATEGORY_HIGH_PRESSURE": {
        "code": "REDUCE_CATEGORY_SPENDING",
        "type": "reduce",
        "actionUnit": "per_day",
        "source": "categoryHealth",
        "expiresWhen": "{category} pressure returns to normal/low",
    },
    "MULTIPLE_CATEGORIES_PRESSURED": {
        "code": "REVIEW_MULTIPLE_CATEGORIES",
        "type": "reduce",
        "actionUnit": None,
        "source": "categoryPressure",
        "expiresWhen": "Fewer than two material categories are pressured",
    },
    "CATEGORY_RECOVERABLE": {
        "code": "MONITOR_CATEGORY_SPENDING",
        "type": "monitor",
        "actionUnit": "per_day",
        "source": "categoryHealth",
        "expiresWhen": "{category} pressure changes from medium",
    },
    "SPENDING_TOO_FAST": {
        "code": "SLOW_SPENDING_PACE",
        "type": "reduce",
        "actionUnit": None,
        "source": "spendingPace",
        "expiresWhen": "Spending Pace is no longer too_fast",
    },
    "GOAL_AT_RISK": {
        "code": "INCREASE_GOAL_CONTRIBUTION",
        # "protect" — a genuinely new type (spec: Phase 19 Design). None
        # of recover/stop/reduce/monitor/maintain fit "put more toward
        # this specific goal," so the taxonomy grows by one rather than
        # force-fitting an ill-matching label.
        "type": "protect",
        "actionUnit": None,
        "source": "goalRisk",
        "expiresWhen": "{goalName} is no longer at risk",
    },
}

_HEALTHY_RECOMMENDATION = {
    "code": "KEEP_CURRENT_HABITS",
    "type": "maintain",
    "actionUnit": None,
    "source": "overallHealth",
    "expiresWhen": "Overall Health changes from green",
}


def _load_risk_flags(db, uid: str, month_key: str = None) -> list:
    return compute_risk_flags(db, uid, month_key).get("riskFlags") or []


def _load_metrics(db, uid: str, month_key: str = None) -> dict:
    return get_metrics(db, uid, month_key)


def _validate_flags(flags: list) -> list:
    """
    Defensive only — Risk Flags already guarantees a well-formed list;
    this just guards against a malformed input, never re-derives it.
    """
    return flags or []


def _lookup_action_value(trigger_code: str, flag: dict, metrics: dict):
    """
    Reads actionValue straight from an existing Metrics Engine field —
    never computed here (Rule 4). The only two codes with a real number
    both read from metrics that exist specifically to support this
    (Recovery Plan's dailyTarget, Phase 2.5; Category Daily Target,
    Phase 2.3a).
    """
    if trigger_code == "RECOVERY_NEEDED":
        recovery_plan = metrics.get("recoveryPlan") or {}
        return recovery_plan.get("dailyTarget")

    if trigger_code == "CATEGORY_EXHAUSTED":
        # Always 0 — the same field, Category Daily Target, already
        # returns 0 for an exhausted category by its own design
        # (Phase 2.3a), so no new logic produces this zero.
        return 0

    if trigger_code in ("CATEGORY_HIGH_PRESSURE", "CATEGORY_RECOVERABLE"):
        category = flag.get("category")
        category_daily_target = metrics.get("categoryDailyTarget") or {}
        entry = category_daily_target.get(category) if category else None
        return entry.get("value") if entry else None

    if trigger_code == "GOAL_AT_RISK":
        # Read directly off the flag -- compute_goal_risk() (Phase 18)
        # already computed this; no fresh Metrics Engine lookup exists
        # for a per-goal shortfall, and Rule 4 forbids computing one
        # here. Explicit scope decision (spec Phase 19 Design): the
        # shortfall fact only, never a suggested spending-cut number --
        # that would need a new metric that doesn't exist yet.
        return flag.get("shortfall")

    return None


def _build_recommendation(flag: dict, metrics: dict):
    """
    One Risk Flag -> one recommendation object, via the frozen Matrix
    lookup only (Rule 3: one recommendation per problem). Returns None
    for a flag code with no Matrix row (defensive only — every code
    Risk Flags can produce has a row, verified by direct enumeration).
    """
    trigger_code = flag.get("code")
    template = _RECOMMENDATION_MATRIX.get(trigger_code)
    if template is None:
        return None

    category = flag.get("category")
    # goalId/goalName (Phase 19) -- carried through exactly like
    # `category` above, never a goal-specific code path. Only GOAL_AT_RISK
    # flags ever set these; every other flag leaves them None.
    goal_id = flag.get("goalId")
    goal_name = flag.get("goalName")

    expires_when = template["expiresWhen"]
    if category and "{category}" in expires_when:
        expires_when = expires_when.format(category=category)
    if goal_name and "{goalName}" in expires_when:
        expires_when = expires_when.format(goalName=goal_name)

    return {
        "code": template["code"],
        "type": template["type"],
        "confidence": flag.get("confidence"),
        "actionValue": _lookup_action_value(trigger_code, flag, metrics),
        "actionUnit": template["actionUnit"],
        "category": category,
        "goalId": goal_id,
        "goalName": goal_name,
        "source": template["source"],
        "generatedFrom": trigger_code,
        "expiresWhen": expires_when,
    }


def _build_healthy_recommendation() -> dict:
    template = _HEALTHY_RECOMMENDATION
    return {
        "code": template["code"],
        "type": template["type"],
        "confidence": "high",
        "actionValue": None,
        "actionUnit": template["actionUnit"],
        "category": None,
        "goalId": None,
        "goalName": None,
        "source": template["source"],
        "generatedFrom": None,
        "expiresWhen": template["expiresWhen"],
    }


def _build_recommendation_trace(flags: list, recommendations: list) -> list:
    """
    Mechanical, debug-only — the same philosophy as decisionLog/
    decisionTrace. Never shown to the user.
    """
    if not recommendations:
        return ["No risk flags present", "Matrix lookup: KEEP_CURRENT_HABITS (maintain)"]

    trace = []
    for flag, rec in zip(flags, recommendations):
        if rec is None:
            continue
        label = f"{flag['code']}"
        if flag.get("category"):
            label += f" ({flag['category']})"
        elif flag.get("goalName"):
            label += f" ({flag['goalName']})"
        trace.append(f"Risk: {label}")
        trace.append(f"Matrix lookup: {rec['code']}")
        if rec.get("actionValue") is not None:
            trace.append(f"actionValue: {rec['actionValue']} ({rec.get('actionUnit')})")
    return trace


def compute_recommendations(db, uid: str, month_key: str = None) -> dict:
    """
    Public API — the only function anything outside this module calls.
    Pipeline: Load Risk Flags -> Validate -> Matrix Lookup -> Build
    Recommendation Object -> Sort (inherited, never recomputed) -> Return.
    """
    start = time.perf_counter()

    flags = _validate_flags(_load_risk_flags(db, uid, month_key))

    if not flags:
        primary = _build_healthy_recommendation()
        primary["priority"] = 1
        alternatives = []
        trace = _build_recommendation_trace([], [])
    else:
        metrics = _load_metrics(db, uid, month_key)
        recommendations = [_build_recommendation(f, metrics) for f in flags]
        matched_flags = [f for f, r in zip(flags, recommendations) if r is not None]
        recommendations = [r for r in recommendations if r is not None]

        # Priority inherited directly from Risk Flags' own ordering — no
        # second sort exists anywhere in this engine.
        for i, rec in enumerate(recommendations):
            rec["priority"] = i + 1

        primary = recommendations[0]
        alternatives = recommendations[1:]
        trace = _build_recommendation_trace(matched_flags, recommendations)

    generation_ms = round((time.perf_counter() - start) * 1000, 2)

    return {
        "primaryRecommendation": primary,
        "alternatives": alternatives,
        "recommendationTrace": trace,
        "metadata": {
            "recommendationEngineVersion": RECOMMENDATION_ENGINE_VERSION,
            "healthEngineVersion": HEALTH_ENGINE_VERSION,
            "metricsEngineVersion": METRICS_ENGINE_VERSION,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "generationMs": generation_ms,
        },
    }
