"""
services/metrics_engine.py
=============================
The Metrics Engine — Phase 2. Read-only interpretation layer on top of
the Financial Engine's financialSummary (spec FINANCIAL_ENGINE_SPEC.md,
"Phase 2.0 — Metrics Design").

Metrics never modify money. This module must never write to Firestore,
never call financial_engine.recompute(), and never import anything from
financial_engine.py's write path — only get_summary(), its read-only
public API. Only the Financial Engine changes financial state; this
module only reads and interprets.

Phase 2.1: Days Remaining. Phase 2.2: Budget Utilization. Phase 2.3:
Recommended Daily Spend. Phase 2.3a: Category Daily Target (added later,
while designing Phase 4.0 — a narrow, named amendment to the Phase 2
freeze, not a reopening of it). Phase 2.4: Spending Pace. Phase 2.5:
Recovery Plan. Phase 2.6: Category Pressure. Phase 2.7: Projected
Savings.
"""

import time
from datetime import datetime, timezone

from utils import (
    get_current_month_key,
    get_days_remaining_in_month,
    get_days_passed_in_month,
    get_total_days_in_month,
)
from services.financial_engine import get_summary

METRICS_ENGINE_VERSION = 1


def compute_days_remaining(month_key: str, reference_date: datetime = None) -> int:
    """
    Days left in the calendar month, inclusive of today (see spec:
    Phase 2.1 Design). Only meaningful for the current month — a past
    month is already closed and returns 0.
    """
    ref = reference_date or datetime.now(timezone.utc)
    current_month_key = get_current_month_key() if reference_date is None else ref.strftime("%Y-%m")

    if month_key != current_month_key:
        return 0

    return get_days_remaining_in_month(ref)


def compute_budget_utilization(category_remaining: dict) -> dict:
    """
    Per-category utilization = spent/limit * 100 (see spec: Phase 2.2
    Design). Reads categoryRemaining from financialSummary only — never
    sums transactions or reads a budget document itself.

    Edge cases, decided in the spec:
    - limit <= 0 -> 0% (no usable budget to measure usage against;
      spent is irrelevant in this case, never a divide-by-zero error).
    - Over budget -> not clamped; returns the real ratio (e.g. 113.3%)
      so Phase 2.6/Phase 3 can see how far over, not a flattened 100%.
    - Negative spent/limit is never guarded against here — that's a
      Financial Engine invariant failure (Section 7), not something
      this function silently corrects.
    """
    result = {}
    for category, data in (category_remaining or {}).items():
        limit = data.get("limit", 0) or 0
        spent = data.get("spent", 0) or 0

        if limit <= 0:
            utilization = 0.0
        else:
            utilization = (spent / limit) * 100

        result[category] = {"utilization": utilization}
    return result


def compute_recommended_daily_spend(category_remaining: dict, days_remaining: int):
    """
    Advisory metric (see spec: Phase 2.3 Design) — "aim to spend" per
    day, not "safe to spend." Never includes savingsPool: the product
    philosophy treats Savings as the last resort, and a recommendation
    that assumes it would quietly tell the user it's fine to spend it.

    Formula: sum(remaining category budgets with limit > 0) / daysRemaining.
    Recomputed from current remaining every call — not fixed at the
    start of the month, so it naturally drops as the user spends and
    recovers if a transaction is undone.

    Returns None (not 0, not a fabricated number) if no category has a
    budget set at all — faking a number where no budget exists would be
    exactly the kind of lie Phase 2.0's design pass exists to prevent.
    """
    category_remaining = category_remaining or {}
    budgeted = [
        data for data in category_remaining.values()
        if (data.get("limit", 0) or 0) > 0
    ]
    if not budgeted:
        return None

    if days_remaining <= 0:
        return None

    total_remaining = sum(data.get("remaining", 0) or 0 for data in budgeted)
    # Never a negative recommendation — Recovery Plan (Phase 2.5), not
    # this metric, is where "you're over" gets explained.
    value = max(total_remaining, 0) / days_remaining

    return {"value": value, "confidence": "medium"}


def compute_category_daily_target(category_remaining: dict, days_remaining: int):
    """
    Advisory metric (see spec: Phase 2.3a Design, added while designing
    Phase 4.0's Recommendation Matrix) — the per-category counterpart to
    Recommended Daily Spend. Deliberately does NOT pool across
    categories the way Recommended Daily Spend and Recovery Plan do —
    "if you only spend from this category's own remaining, here's
    today's rate," a strict per-category view, never merged with
    recovery-after-overspending logic (that stays Recovery Plan's job).

    Formula: categoryRemaining[cat].remaining / daysRemaining, per
    category with limit > 0. An exhausted category (remaining == 0,
    already floored there by the Financial Engine's No Negative Budgets
    invariant) gets an included value of 0 — meaningful information,
    not omitted the way an unbudgeted category is.

    Returns None if no category has a budget at all, or if
    days_remaining <= 0 (non-current month) — same current-month-only
    scope every other days-based metric already observes.
    """
    category_remaining = category_remaining or {}
    budgeted = {
        cat: data for cat, data in category_remaining.items()
        if (data.get("limit", 0) or 0) > 0
    }
    if not budgeted:
        return None
    if days_remaining <= 0:
        return None

    return {
        cat: {
            "value": (data.get("remaining", 0) or 0) / days_remaining,
            "confidence": "medium",
        }
        for cat, data in budgeted.items()
    }


def _classify_pace(difference: float) -> str:
    """
    Thresholds are a first cut, expected to be tuned later — that's why
    the raw difference is always returned alongside the label, not
    discarded once classified (see spec: Phase 2.4 Design).
    """
    if difference <= -0.10:
        return "ahead"
    if difference <= 0.10:
        return "on_pace"
    if difference <= 0.25:
        return "slightly_fast"
    return "too_fast"


def compute_spending_pace(total_spent: float, total_budget: float, elapsed_days: int, total_days: int):
    """
    Analytical metric (see spec: Phase 2.4 Design) — compares budget
    progress against time progress, never today's spending alone and
    never a re-derivation of Budget Utilization. High confidence: unlike
    Recommended Daily Spend, this makes no assumption about future
    logging — it only describes today's already-trusted numbers.

    Never recommends an action and never assigns a health color; both
    are out of scope for this metric by design (Recovery Plan / Phase 3).

    Returns None if no budget is set at all — a pace compared against a
    budget that doesn't exist would be a fabricated number.
    """
    if not total_budget or total_budget <= 0:
        return None
    if not total_days or total_days <= 0:
        return None

    time_progress = elapsed_days / total_days
    budget_progress = total_spent / total_budget
    # No clamping — an over-budget user (budget_progress > 1.0) should
    # land in "too_fast" with the real magnitude, not a flattened one.
    difference = budget_progress - time_progress

    return {
        "difference": difference,
        "status": _classify_pace(difference),
        "confidence": "high",
        # Additive fields (Phase 2.7) — Projected Savings is built
        # directly from these two, not a second re-derivation from raw
        # totals. Purely additive: no existing consumer of `difference`
        # is affected by these two extra keys.
        "budgetProgress": budget_progress,
        "timeProgress": time_progress,
    }


def _practical_round(value: float) -> float:
    """
    Round to a number a person can actually plan a day around — never a
    precise decimal like Rs 183.42 (spec: Phase 2.5 Design — "optimize
    for something the user can realistically follow, not mathematical
    perfection"). Small amounts round to the nearest 5, larger ones to
    the nearest 10, so a genuinely tiny target doesn't round away to 0
    just because it's under 10.
    """
    if value <= 0:
        return 0
    if value < 50:
        return round(value / 5) * 5
    return round(value / 10) * 10


def compute_recovery_plan(
    category_remaining: dict,
    days_remaining: int,
    total_budget: float,
    total_days_in_month: int,
    recommended_daily_spend,
    spending_pace,
):
    """
    Advisory metric (see spec: Phase 2.5 Design) — answers only "if I
    continue from today, how should I adjust my spending?" Never reads
    or recommends savingsPool: recovery is about future behavior, not
    money movement, and the product philosophy treats Savings as the
    last resort regardless of what the Engine may have already done.

    Reuses already-computed metrics only (categoryRemaining, Days
    Remaining, Recommended Daily Spend, Spending Pace) — never queries
    transactions itself, keeping the dependency graph exactly what the
    spec's dependency graph already describes.

    Returns None (no plan) when:
    - there's no runway left to spread an adjustment over (daysRemaining <= 1)
    - there are no budgets at all (recommended_daily_spend is None)
    - none of the three trigger conditions hold (spending is fine)
    """
    if days_remaining is None or days_remaining <= 1:
        return None
    if recommended_daily_spend is None:
        return None

    category_remaining = category_remaining or {}
    budgeted = {
        cat: data for cat, data in category_remaining.items()
        if (data.get("limit", 0) or 0) > 0
    }
    exhausted = sorted(
        cat for cat, data in budgeted.items()
        if (data.get("remaining", 0) or 0) <= 0
    )

    too_fast = spending_pace is not None and spending_pace.get("status") == "too_fast"

    # "Dropped significantly" substitutes for a historical comparison
    # (nothing in Phase 2 persists between calls) with a comparison
    # against the month's own even-split baseline rate instead.
    baseline_daily_rate = (
        total_budget / total_days_in_month
        if total_budget and total_days_in_month else 0
    )
    significant_drop = (
        baseline_daily_rate > 0
        and recommended_daily_spend["value"] < baseline_daily_rate * 0.75
    )

    category_exhausted = len(exhausted) > 0

    if not (too_fast or significant_drop or category_exhausted):
        return None

    total_remaining = sum((data.get("remaining", 0) or 0) for data in budgeted.values())
    recovery_possible = total_remaining > 0

    daily_target = _practical_round(max(total_remaining, 0) / days_remaining)

    if len(exhausted) >= 2 or daily_target <= 0:
        severity = "high"
    elif len(exhausted) == 1:
        severity = "medium"
    else:
        severity = "minor"

    return {
        "needed": True,
        "dailyTarget": daily_target,
        "durationDays": days_remaining,
        "affectedCategories": exhausted,
        "severity": severity,
        "recoveryPossible": recovery_possible,
        "confidence": "medium",
    }


def _classify_pressure(difference: float) -> str:
    """
    Different thresholds from Spending Pace's global classification —
    per-category volatility is noisier than the whole-budget aggregate,
    so a wider "normal" band avoids flagging every small category swing
    (see spec: Phase 2.6 Design). First cut, expected to be tuned later.
    """
    if difference <= -0.20:
        return "low"
    if difference <= 0.10:
        return "normal"
    if difference <= 0.30:
        return "medium"
    return "high"


# Health (Phase 3.1) needs to know whether a category is big enough to
# single-handedly affect Overall Health, without Health itself doing any
# arithmetic (Phase 3.0's Rule 1). The ratio check lives here, in Metrics
# Engine, where category math already happens — Health only ever reads
# the resulting `material` boolean. Named like ENGINE_VERSION/
# METRICS_ENGINE_VERSION so the threshold is a one-line change later,
# not a hunt through hardcoded literals.
HEALTH_MATERIALITY_THRESHOLD = 0.05  # 5% of totalBudget — first cut, tunable


def compute_category_pressure(
    category_remaining: dict, elapsed_days: int, total_days: int, total_budget: float = 0
):
    """
    Analytical metric (see spec: Phase 2.6 Design) — per-category
    pressure = category budget progress minus month time progress. High
    confidence: only current, already-trusted data, no future assumption.

    Independently recomputes time progress from the same date Facts
    Spending Pace also reads — never consumes Spending Pace's or Days
    Remaining's *output* (the Phase 2 Review's dependency correction
    applies here too: each metric depends on the minimum it needs).

    Categories with no budget (limit <= 0) are simply omitted from
    byCategory. Returns None if no category has a budget at all.

    Each entry also carries `material` — whether this category's limit
    is at least HEALTH_MATERIALITY_THRESHOLD of totalBudget (spec: Phase
    3.0, Q4) — a tiny category (e.g. Rs 100 Entertainment) shouldn't
    single-handedly move Overall Health, but still reports its own
    honest status here for anyone drilling into that one category.
    """
    category_remaining = category_remaining or {}
    if not total_days or total_days <= 0:
        return None

    time_progress = elapsed_days / total_days

    by_category = {}
    for cat, data in category_remaining.items():
        limit = data.get("limit", 0) or 0
        if limit <= 0:
            continue
        spent = data.get("spent", 0) or 0
        budget_progress = spent / limit
        # No clamping — an already-over-budget category should land in
        # "high" with the real magnitude, not a flattened one.
        difference = budget_progress - time_progress
        material = bool(total_budget) and (limit / total_budget) >= HEALTH_MATERIALITY_THRESHOLD
        by_category[cat] = {
            "pressure": difference,
            "status": _classify_pressure(difference),
            "confidence": "high",
            "material": material,
        }

    if not by_category:
        return None

    priority_order = sorted(
        by_category.keys(), key=lambda c: by_category[c]["pressure"], reverse=True
    )

    return {
        "byCategory": by_category,
        "priorityOrder": priority_order,
    }


PROJECTED_SAVINGS_ASSUMPTION = "current_spending_continues"


def compute_projected_savings(spending_pace, total_budget: float, savings_pool: float):
    """
    Predictive metric (see spec: Phase 2.7 Design) — the only Predictive
    metric in Phase 2, and the only one that assumes future behavior.

    Built directly from Spending Pace's already-computed budgetProgress/
    timeProgress — "Facts -> Budget Utilization -> Spending Pace ->
    Projected Savings" — never a second, parallel prediction path off
    raw transactions.

    Formula: extrapolates the current daily rate (budgetProgress /
    timeProgress) across the whole month, then adds whatever category
    budget would be left over to savingsPool. No clamping in either
    direction: an overspending user can legitimately get a negative
    value (a projected deficit), and a user who stops spending can
    project well above their current savingsPool.

    Confidence tracks how much of the month remains, not the spending
    pace itself: "low" when more than half the month is still ahead
    (more room for behavior to change before this is ever tested),
    "medium" once less than half remains. Never "high" — this assumes
    the future, Spending Pace doesn't.

    Returns None if there's no budget at all (spending_pace is None) —
    nothing to project against.
    """
    if spending_pace is None:
        return None
    if not total_budget or total_budget <= 0:
        return None

    time_progress = spending_pace["timeProgress"]
    budget_progress = spending_pace["budgetProgress"]
    if time_progress <= 0:
        return None

    rate = budget_progress / time_progress
    projected_total_spent = rate * total_budget
    projected_remaining_budget = total_budget - projected_total_spent
    # No clamping in either direction — a projected deficit is a real,
    # meaningful forecast, not something to hide by flooring at 0.
    value = savings_pool + projected_remaining_budget

    confidence = "low" if (1 - time_progress) > 0.5 else "medium"

    return {
        "value": value,
        "confidence": confidence,
        "assumption": PROJECTED_SAVINGS_ASSUMPTION,
    }


def get_metrics(db, uid: str, month_key: str = None) -> dict:
    """
    Returns the current financialMetrics for the given month. Computed
    fresh on every call — nothing here is stored or recomputed, since
    every metric is a pure read/interpretation of financialSummary plus
    the current date.
    """
    start = time.perf_counter()
    month_key = month_key or get_current_month_key()

    summary = get_summary(db, uid, month_key)
    category_remaining = summary.get("categoryRemaining", {}) or {}
    days_remaining = compute_days_remaining(month_key)

    total_spent = summary.get("totalSpent", 0) or 0
    savings_pool = summary.get("savingsPool", 0) or 0
    total_budget = sum(
        data.get("limit", 0) or 0
        for data in category_remaining.values()
        if (data.get("limit", 0) or 0) > 0
    )
    total_days_in_month = get_total_days_in_month()
    elapsed_days = get_days_passed_in_month()

    recommended_daily_spend = compute_recommended_daily_spend(category_remaining, days_remaining)
    spending_pace = compute_spending_pace(
        total_spent, total_budget, elapsed_days, total_days_in_month
    )

    metrics = {
        "daysRemaining": days_remaining,
        "budgetUtilization": compute_budget_utilization(category_remaining),
        "recommendedDailySpend": recommended_daily_spend,
        "categoryDailyTarget": compute_category_daily_target(category_remaining, days_remaining),
        "spendingPace": spending_pace,
        "recoveryPlan": compute_recovery_plan(
            category_remaining, days_remaining, total_budget, total_days_in_month,
            recommended_daily_spend, spending_pace,
        ),
        "categoryPressure": compute_category_pressure(
            category_remaining, elapsed_days, total_days_in_month, total_budget
        ),
        "projectedSavings": compute_projected_savings(spending_pace, total_budget, savings_pool),
    }

    generation_ms = round((time.perf_counter() - start) * 1000, 2)
    metrics["metadata"] = {
        "metricsEngineVersion": METRICS_ENGINE_VERSION,
        "monthKey": month_key,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "generationMs": generation_ms,
    }

    return metrics
