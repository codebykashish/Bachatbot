"""
weekly_reflection_service.py
===============================
Weekly Reflection — Phase 22. See backend/FINANCIAL_ENGINE_SPEC.md,
"Phase 22 — Weekly Reflection Philosophy" and "Phase 22B — Weekly
Observation," for the full contract this file implements.

Answers the one question none of the other engines answer: not "what's
happening now" (Health Engine), not "what changed" (Diff Generator),
not "what should I do" (Recommendation Engine), but "what did I learn
about my money this week." Assembles a reflection from already-
computed engine outputs and raw transaction records — never a second
financial engine, never a new calculation of anything another engine
already owns.

Phase B (this file's `gather_weekly_observation`) is a pure evidence
assembler: it collects facts, in whatever quantity actually exists, and
returns them raw. It never judges, ranks, summarizes, or produces
user-facing language -- that split (observation vs. interpretation) is
frozen in the spec and must not blur here.

Public API:
    gather_weekly_observation(db, uid, week_start, week_end) -> dict

Raises:
    WeeklyReflectionError if the week fails the Account Existence
    Boundary (see below).
"""

from datetime import date as date_cls, datetime, timedelta, timezone

from services import snapshot_service
from services import financial_engine
from services import health_engine
from services import recommendation_engine
from services import behavior_state_repository as behavior_repo
from services import notification_repository as notif_repo
from utils import get_current_month_key

WEEKLY_REFLECTION_VERSION = "1.0.0"


class WeeklyReflectionError(ValueError):
    """Raised when a week is not eligible for reflection -- fail fast,
    the same convention as NotificationGeneratorError/snapshot_service's
    _is_complete, rather than silently gathering misleading evidence."""


def _account_created_date(db, uid: str):
    """Returns the account's creation date, or None if genuinely
    unavailable (treated as no restriction -- a data-quality gap
    elsewhere in the app is not this module's invariant to enforce)."""
    doc = db.collection("users").document(uid).get()
    created_at = (doc.to_dict() or {}).get("createdAt")
    return created_at.date() if hasattr(created_at, "date") else None


def _as_utc_datetime(d: date_cls, end_of_day: bool = False) -> datetime:
    if end_of_day:
        return datetime(d.year, d.month, d.day, 23, 59, 59, 999999, tzinfo=timezone.utc)
    return datetime(d.year, d.month, d.day, tzinfo=timezone.utc)


def _timestamp_in_range(ts, start_dt: datetime, end_dt: datetime) -> bool:
    """Same tolerant handling as utils.py's is_today/is_in_current_month --
    a real Firestore timestamp is naive-or-aware; never raises on a
    malformed value."""
    if ts is None or not hasattr(ts, "year"):
        return False
    if getattr(ts, "tzinfo", None) is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return start_dt <= ts <= end_dt


def _gather_transactions(db, uid: str, start_dt: datetime, end_dt: datetime) -> dict:
    """
    Direct date-range read over raw transactions -- deliberately NOT
    monthKey-scoped, so a week crossing a month boundary is handled
    naturally (no merging two budget-scoped queries). Same equality-
    filter-then-client-side-date-filter convention already used
    elsewhere in this codebase (pattern_service.py, budget_service.py's
    _sum_confirmed_expense_by_category) rather than a new composite
    Firestore index.
    """
    transactions_ref = db.collection("users").document(uid).collection("transactions")

    total_spent = 0.0
    total_income = 0.0
    transaction_count = 0
    category_spending: dict = {}

    for tx_type in ("expense", "income"):
        docs = (
            transactions_ref
            .where("type", "==", tx_type)
            .where("status", "==", "confirmed")
            .stream()
        )
        for doc in docs:
            data = doc.to_dict() or {}
            if data.get("isDeleted", False):
                continue
            if not _timestamp_in_range(data.get("createdAt"), start_dt, end_dt):
                continue
            amount = float(data.get("amount") or 0)
            transaction_count += 1
            if tx_type == "expense":
                total_spent += amount
                category = data.get("category")
                if category:
                    category_spending[category] = category_spending.get(category, 0.0) + amount
            else:
                total_income += amount

    return {
        "totalSpent": round(total_spent, 2),
        "totalIncome": round(total_income, 2),
        "transactionCount": transaction_count,
        "categorySpending": {k: round(v, 2) for k, v in category_spending.items()},
    }


def _gather_budgets(db, uid: str, week_start: date_cls, week_end: date_cls) -> dict:
    """
    Category limits, only when the week sits inside one month (Phase A
    rule 4) -- reused directly from financial_engine.get_summary(),
    never recomputed. A week crossing a month boundary reports which
    month_keys are involved and gathers no limits at all, rather than
    guessing across two different budget documents.
    """
    start_month_key = snapshot_service.month_key_for(week_start)
    end_month_key = snapshot_service.month_key_for(week_end)
    month_keys_involved = sorted({start_month_key, end_month_key})

    category_limits = {}
    if len(month_keys_involved) == 1:
        summary = financial_engine.get_summary(db, uid, start_month_key)
        category_remaining = summary.get("categoryRemaining") or {}
        category_limits = {
            cat: data.get("limit", 0)
            for cat, data in category_remaining.items()
            if (data.get("limit") or 0) > 0
        }

    return {
        "monthKeysInvolved": month_keys_involved,
        "categoryLimits": category_limits,
    }


def _gather_health(db, uid: str, week_start: date_cls, week_end: date_cls) -> dict:
    """
    First and last daily-snapshot health status actually found in the
    week's 7 calendar dates (Phase A rule 6) -- never assumes all 7
    exist, never recomputes a historical day's health (Health Engine
    can only be evaluated against LIVE current data, per Phase 22's own
    verification -- a stored snapshot's status is the only faithful
    historical record).
    """
    found = []
    current = week_start
    while current <= week_end:
        doc = (
            db.collection("users").document(uid)
            .collection("dailySnapshots").document(current.isoformat())
            .get()
        )
        if doc.exists:
            data = doc.to_dict() or {}
            status = (data.get("health") or {}).get("overallHealthStatus")
            if status is not None:
                found.append({"date": current.isoformat(), "status": status})
        current += timedelta(days=1)

    return {
        "snapshotsFound": len(found),
        "first": found[0] if found else None,
        "last": found[-1] if found else None,
    }


def _gather_behavior(db, uid: str) -> dict:
    """
    Current, live streak counts (Phase A rule 5) -- never a
    reconstructed day-by-day history. A quiet week naturally shows up
    as a low/zero count here; that is evidence to report, not a gap.
    """
    state = behavior_repo.load_state(db, uid)
    return {
        "loggingStreak": state["logging"]["currentStreak"],
        "healthySpendingStreak": state["spending"]["currentHealthyStreak"],
        "overspendingStreak": state["spending"]["currentOverspendingStreak"],
        "savingProtectionStreak": state["saving"]["currentProtectionStreak"],
    }


def _gather_pattern_alerts(db, uid: str, start_dt: datetime, end_dt: datetime) -> list:
    """
    UNUSUAL_SPENDING_DETECTED notifications created within the week
    (Phase A rule 8) -- read directly from the Notification Repository,
    never recomputed. No date-range query exists on that repository
    (by design, spec 5.7 -- persistence-only, no domain filtering
    beyond status); filtered client-side here instead, the same
    convention as every other date-scoped read in this file.
    """
    alerts = []
    for n in notif_repo.list_notifications(db, uid):
        if n.get("eventCode") != "UNUSUAL_SPENDING_DETECTED":
            continue
        if not _timestamp_in_range(n.get("createdAt"), start_dt, end_dt):
            continue
        payload = n.get("payload") or {}
        alerts.append({"category": payload.get("category"), "createdAt": n.get("createdAt")})
    return alerts


def gather_weekly_observation(db, uid: str, week_start, week_end) -> dict:
    """
    Public API — Phase B. `week_start`/`week_end` are date objects (or
    ISO date strings), the completed ISO week (Monday-Sunday) being
    reflected on. Returns raw evidence only; Phase C decides what any
    of it means.

    Goal Risk and the primary Recommendation are read against the
    CURRENT month_key, not the week's -- both are inherently forward-
    looking signals (Phase A rule 7), so describing "how this week
    affects your goals" honestly means their live state, never a
    reconstructed history that doesn't exist.

    Account Existence Boundary (frozen with this guard): a week whose
    entire span ended before the account was created has no valid
    evidence to gather -- budgets in particular aren't versioned in
    this app, so "the current limit" would be silently misattributed
    as "the limit back then." Raises WeeklyReflectionError rather than
    gathering misleading data. A week that only PARTIALLY overlaps
    account creation (e.g. account created Wednesday, week is Mon-Sun)
    is allowed -- the pre-account days simply have no transactions/
    snapshots to find, which every gather function already reports
    honestly as zero/absent, no special-casing needed beyond this one
    boundary check.
    """
    if isinstance(week_start, str):
        week_start = date_cls.fromisoformat(week_start)
    if isinstance(week_end, str):
        week_end = date_cls.fromisoformat(week_end)

    account_created = _account_created_date(db, uid)
    if account_created is not None and week_end < account_created:
        raise WeeklyReflectionError(
            f"Week {week_start.isoformat()} to {week_end.isoformat()} ended before "
            f"the account was created ({account_created.isoformat()}) -- no "
            f"reflection may be generated for a week that ended entirely before "
            f"the account existed (Account Existence Boundary, spec Phase 22B)."
        )

    start_dt = _as_utc_datetime(week_start)
    end_dt = _as_utc_datetime(week_end, end_of_day=True)
    current_month_key = get_current_month_key()

    goal_risk_result = health_engine.compute_goal_risk(db, uid, current_month_key)
    recommendation_result = recommendation_engine.compute_recommendations(db, uid, current_month_key)

    return {
        "weekStart": week_start.isoformat(),
        "weekEnd": week_end.isoformat(),
        "transactions": _gather_transactions(db, uid, start_dt, end_dt),
        "budgets": _gather_budgets(db, uid, week_start, week_end),
        "health": _gather_health(db, uid, week_start, week_end),
        "behavior": _gather_behavior(db, uid),
        "goalRisk": goal_risk_result["goalRisk"],
        "recommendation": recommendation_result["primaryRecommendation"],
        "patternAlerts": _gather_pattern_alerts(db, uid, start_dt, end_dt),
        "metadata": {
            "weeklyReflectionVersion": WEEKLY_REFLECTION_VERSION,
        },
    }


# ═══════════════════════════════════════════════════════════════════════
# Phase C — Weekly Interpretation (spec Phase 22C)
# ═══════════════════════════════════════════════════════════════════════
#
# Pure function, no Firestore. Selects deterministic meaning from
# Phase B's already-gathered evidence -- never invents evidence, never
# performs a calculation that belongs to another engine. May compare
# directly-observed weekly spending against a directly-retrieved budget
# limit, select from existing engine outputs, and apply the frozen
# rules below. Nothing here produces user-facing prose (Phase D's job).

# Higher rank = healthier. Shared with nothing else -- a local ordering
# for comparing two already-real status strings, not a new health
# computation.
_HEALTH_RANK = {"red": 0, "amber": 1, "green": 2}

# The single shared boundary between "comfortably within budget" and
# "high usage" (spec Phase 22C Design) -- reuses the same 80% this
# codebase already treats as the budget-alert threshold everywhere else
# (chat.py/transactions.py/confirm.py's own alert messages), not a new
# invented number. A category at exactly this ratio or above is concern
# territory; strictly below is highlight territory -- no overlap.
_HIGH_USAGE_THRESHOLD = 0.8

# A streak shorter than this isn't yet meaningful enough to praise --
# first cut, tunable, same spirit as every other "first guess" threshold
# already frozen elsewhere in this codebase (e.g. metrics_engine.py's
# HEALTH_MATERIALITY_THRESHOLD).
_MEANINGFUL_STREAK_MIN = 3

# Deterministic tie-break order when more than one streak qualifies --
# saving and healthy-spending streaks are rarer, more deliberate wins
# than a logging streak, which is the most basic habit this app tracks.
_STREAK_FIELDS_PRIORITY = ["savingProtectionStreak", "healthySpendingStreak", "loggingStreak"]


def _highlight_health_improved(observation: dict):
    health = observation.get("health") or {}
    first, last = health.get("first"), health.get("last")
    if health.get("snapshotsFound", 0) < 2 or not first or not last:
        return None
    first_rank = _HEALTH_RANK.get(first.get("status"))
    last_rank = _HEALTH_RANK.get(last.get("status"))
    if first_rank is None or last_rank is None or last_rank <= first_rank:
        return None
    return {"type": "HEALTH_IMPROVED", "from": first["status"], "to": last["status"]}


def _concern_health_worsened(observation: dict):
    health = observation.get("health") or {}
    first, last = health.get("first"), health.get("last")
    if health.get("snapshotsFound", 0) < 2 or not first or not last:
        return None
    first_rank = _HEALTH_RANK.get(first.get("status"))
    last_rank = _HEALTH_RANK.get(last.get("status"))
    if first_rank is None or last_rank is None or last_rank >= first_rank:
        return None
    return {"type": "HEALTH_WORSENED", "from": first["status"], "to": last["status"]}


def _highlight_streak(observation: dict):
    behavior = observation.get("behavior") or {}
    candidates = [(i, field, behavior.get(field, 0)) for i, field in enumerate(_STREAK_FIELDS_PRIORITY)]
    qualifying = [c for c in candidates if c[2] >= _MEANINGFUL_STREAK_MIN]
    if not qualifying:
        return None
    # Highest value wins; ties broken by priority index (lower = wins) --
    # deterministic, never random.
    qualifying.sort(key=lambda c: (-c[2], c[0]))
    _, field, value = qualifying[0]
    return {"type": "MEANINGFUL_STREAK", "streakType": field, "value": value}


def _highlight_category_within_budget(observation: dict):
    budgets = observation.get("budgets") or {}
    if len(budgets.get("monthKeysInvolved") or []) != 1:
        return None
    limits = budgets.get("categoryLimits") or {}
    spending = (observation.get("transactions") or {}).get("categorySpending") or {}
    qualifying = [
        (cat, spending[cat], limits[cat])
        for cat in spending
        if cat in limits and limits[cat] > 0
        and 0 < spending[cat] < limits[cat] * _HIGH_USAGE_THRESHOLD
    ]
    if not qualifying:
        return None
    qualifying.sort(key=lambda t: -t[1])  # highest spending amount wins
    cat, spent, limit = qualifying[0]
    return {"type": "CATEGORY_WITHIN_BUDGET", "category": cat, "spent": spent, "limit": limit}


def _concern_category_high_usage(observation: dict):
    budgets = observation.get("budgets") or {}
    if len(budgets.get("monthKeysInvolved") or []) != 1:
        return None
    limits = budgets.get("categoryLimits") or {}
    spending = (observation.get("transactions") or {}).get("categorySpending") or {}
    qualifying = [
        (cat, spending[cat], limits[cat], spending[cat] / limits[cat])
        for cat in spending
        if cat in limits and limits[cat] > 0 and (spending[cat] / limits[cat]) >= _HIGH_USAGE_THRESHOLD
    ]
    if not qualifying:
        return None
    qualifying.sort(key=lambda t: -t[3])  # highest usage ratio wins
    cat, spent, limit, _ratio = qualifying[0]
    return {"type": "CATEGORY_HIGH_USAGE", "category": cat, "spent": spent, "limit": limit}


def _concern_low_activity(observation: dict):
    transactions = observation.get("transactions") or {}
    behavior = observation.get("behavior") or {}
    if transactions.get("transactionCount", 0) == 0 and behavior.get("loggingStreak", 0) == 0:
        return {"type": "LOW_ACTIVITY"}
    return None


def _select_pattern(observation: dict):
    """
    Max 1 (spec rule). All UNUSUAL_SPENDING_DETECTED notifications
    share the same Priority ("High") -- there is no severity field to
    differentiate multiple alerts in one week, so recency is the only
    honest deterministic tiebreak, not an invented one.
    """
    alerts = observation.get("patternAlerts") or []
    dated = [a for a in alerts if a.get("createdAt") is not None]
    if not dated:
        return None
    best = max(dated, key=lambda a: a["createdAt"])
    return {"type": "UNUSUAL_SPENDING", "category": best.get("category"), "createdAt": best.get("createdAt")}


def _select_goal_context(observation: dict):
    """
    Independent of highlights/concerns (spec Phase 22C Design) -- a
    goal shouldn't have to "compete" with spending/health signals for
    one of the capped slots. At-risk goals always win the slot when any
    exist (largest shortfall = most urgent); otherwise the highest-
    priority healthy goal is named. Current-state language only --
    never a claim that this week caused the goal's state (Phase A rule
    7: Goal Risk is a live signal, not a reconstructed history).
    """
    goal_risk = observation.get("goalRisk") or {}
    if not goal_risk:
        return None

    at_risk = [(gid, g) for gid, g in goal_risk.items() if g.get("atRisk")]
    if at_risk:
        at_risk.sort(key=lambda gg: -(gg[1].get("shortfall") or 0))
        gid, g = at_risk[0]
        return {
            "type": "GOAL_AT_RISK", "goalId": gid,
            "goalName": g.get("goalName"), "shortfall": g.get("shortfall"),
        }

    gid, g = next(iter(goal_risk.items()))
    return {"type": "GOAL_ON_TRACK", "goalId": gid, "goalName": g.get("goalName")}


def _select_next_step(observation: dict):
    """
    Direct pass-through of the primary Recommendation -- never a new
    recommendation invented here (Rule 3 of the Recommendation Engine
    itself: one recommendation per problem, and it isn't this module's
    problem to solve). Omitted entirely for the healthy-account
    fallback (KEEP_CURRENT_HABITS) -- "maintain what you're doing" isn't
    a next step worth occupying the one slot for.
    """
    recommendation = observation.get("recommendation") or {}
    code = recommendation.get("code")
    if not code or code == "KEEP_CURRENT_HABITS":
        return None
    return {"recommendationCode": code}


def interpret_weekly_observation(observation: dict) -> dict:
    """
    Public API — Phase C. Pure function: no Firestore, no database
    reads, no new financial calculations, no recommendation generation,
    no user-facing prose. Only deterministic selection over Phase B's
    already-gathered evidence, capped per the frozen rules (spec Phase
    22A rule 11): max 2 highlights, max 2 concerns, max 1 pattern, max
    1 goal context, max 1 next step.
    """
    highlights = [
        h for h in (
            _highlight_health_improved(observation),
            _highlight_streak(observation),
            _highlight_category_within_budget(observation),
        ) if h is not None
    ][:2]

    concerns = [
        c for c in (
            _concern_health_worsened(observation),
            _concern_category_high_usage(observation),
            _concern_low_activity(observation),
        ) if c is not None
    ][:2]

    return {
        "highlights": highlights,
        "concerns": concerns,
        "pattern": _select_pattern(observation),
        "goalContext": _select_goal_context(observation),
        "nextStep": _select_next_step(observation),
    }


# ═══════════════════════════════════════════════════════════════════════
# Phase D — Weekly Reflection Composition (spec Phase 22D)
# ═══════════════════════════════════════════════════════════════════════
#
# Tone Principle (frozen): the reflection is observational, supportive,
# and actionable. It describes facts without shame, exaggeration,
# artificial urgency, or moral judgment. Negative signals are presented
# as opportunities for awareness, never as personal failure -- "Shopping
# reached its full budget this week," never "you overspent."
#
# Template-based, deterministic -- no LLM call, no hallucination risk,
# same reasoning that kept Chat Context v2 to two named facts rather
# than a free-form generation. Pure function: reads only the
# Interpretation object plus the Observation's already-gathered factual
# values (never Firestore, never a new calculation) and returns
# structured content -- Flutter/Chat decide layout, this module only
# decides wording.

_STREAK_LABELS = {
    "loggingStreak": "logging streak",
    "healthySpendingStreak": "healthy spending streak",
    "savingProtectionStreak": "saving streak",
}

_HEALTH_STATUS_LABELS = {"green": "healthy", "amber": "watch", "red": "needs attention"}

# Next Step phrasing per recommendation code -- mirrors, but does not
# duplicate, health_screen.dart's own _recommendationCopy (that one
# writes for the Health screen's "what to do next" card; this one
# writes for the weekly-reflection framing specifically, e.g. "this
# week" phrasing). Both ultimately read the same Recommendation Engine
# codes, per Rule 3 (one recommendation per problem) -- neither invents
# a new recommendation, they just word an existing one differently for
# their own screen. KEEP_CURRENT_HABITS is absent by design (Phase C
# already omits it before Composition ever sees it).
_NEXT_STEP_TEMPLATES = {
    "START_RECOVERY_PLAN": "Consider reviewing your spending this week to help get back on track.",
    "ACCEPT_REDUCED_SAVINGS": "Full recovery may not be possible this month — focus on stabilizing from here.",
    "LIMIT_DAILY_SPENDING": "Try keeping your daily spending a little lower for the rest of the month.",
    "STOP_CATEGORY_SPENDING": "Try to avoid further {category} spending for now.",
    "REDUCE_CATEGORY_SPENDING": "Consider easing up on {category} spending.",
    "REVIEW_MULTIPLE_CATEGORIES": "A few categories could use a closer look this week.",
    "MONITOR_CATEGORY_SPENDING": "Keep an eye on {category} — it's trending toward pressure.",
    "SLOW_SPENDING_PACE": "Try slowing your spending pace a little this week.",
    "INCREASE_GOAL_CONTRIBUTION": "Consider increasing your contribution toward your {goalName} goal.",
}


def _compose_opening(interpretation: dict) -> str:
    has_highlights = bool(interpretation.get("highlights"))
    has_concerns = bool(interpretation.get("concerns"))
    if has_highlights and not has_concerns:
        return "You made some good progress this week."
    if not has_highlights and not has_concerns:
        return "Here's a look at how your money week went."
    return "Here's what stood out about your money this week."


def _compose_highlight(item: dict) -> str:
    kind = item["type"]
    if kind == "HEALTH_IMPROVED":
        return "Your financial health improved this week."
    if kind == "MEANINGFUL_STREAK":
        label = _STREAK_LABELS.get(item["streakType"], "streak")
        return f"You kept your {label} going for {item['value']} days."
    if kind == "CATEGORY_WITHIN_BUDGET":
        return f"Your {item['category']} spending stayed comfortably within budget."
    return ""


def _compose_concern(item: dict) -> str:
    kind = item["type"]
    if kind == "HEALTH_WORSENED":
        frm = _HEALTH_STATUS_LABELS.get(item["from"], item["from"])
        to = _HEALTH_STATUS_LABELS.get(item["to"], item["to"])
        return f"Your financial health moved from {frm} to {to} this week."
    if kind == "CATEGORY_HIGH_USAGE":
        percent = round((item["spent"] / item["limit"]) * 100) if item.get("limit") else 0
        if percent >= 100:
            return f"{item['category']} used its full budget this week. It may be worth keeping an eye on it next week."
        return f"{item['category']} reached {percent}% of its budget this week. It may be worth keeping an eye on it next week."
    if kind == "LOW_ACTIVITY":
        return "There wasn't much spending activity recorded this week."
    return ""


def _compose_pattern(item: dict) -> str:
    return f"Your {item['category']} spending was unusually high compared with your recent pattern."


def _compose_goal_context(item: dict) -> str:
    goal_name = (item.get("goalName") or "").capitalize() or "goal"
    if item["type"] == "GOAL_AT_RISK":
        shortfall = item.get("shortfall")
        amount = f"Rs {round(shortfall)}" if isinstance(shortfall, (int, float)) else "some amount"
        return f"You're currently {amount} short of your {goal_name} goal."
    return f"You're currently on track toward your {goal_name} goal."


def _compose_next_step(next_step: dict, observation: dict) -> str:
    """
    Reads observation["recommendation"] for factual values (category/
    goalName) that Phase C's nextStep deliberately doesn't carry --
    Composition is allowed to read Observation for factual values, per
    spec Phase 22D Design; this is not a new calculation, just a wider
    read of already-gathered evidence.
    """
    code = next_step.get("recommendationCode")
    template = _NEXT_STEP_TEMPLATES.get(code)
    if not template:
        return ""
    recommendation = observation.get("recommendation") or {}
    category = recommendation.get("category") or ""
    goal_name = (recommendation.get("goalName") or "").capitalize()
    try:
        return template.format(category=category, goalName=goal_name)
    except KeyError:
        return template


def compose_weekly_reflection(interpretation: dict, observation: dict) -> dict:
    """
    Public API — Phase D. Pure function: no Firestore, no new
    calculations, no LLM call. Turns Phase C's structured interpretation
    into structured, human-worded content -- each section carries both
    its `type` (for the UI's own icon/color choice, same convention as
    every HealthTheme-driven screen this session already built) and the
    composed `text`. Section visibility rules: highlights/concerns are
    empty lists when nothing qualified (never padded); pattern/
    goalContext/nextStep are None when Phase C found nothing to say —
    the caller (Flutter/Chat) is expected to hide an empty section
    entirely, not render a placeholder.
    """
    highlights = [
        {"type": h["type"], "text": _compose_highlight(h)}
        for h in interpretation.get("highlights") or []
    ]
    concerns = [
        {"type": c["type"], "text": _compose_concern(c)}
        for c in interpretation.get("concerns") or []
    ]

    pattern = interpretation.get("pattern")
    pattern_out = {"type": pattern["type"], "text": _compose_pattern(pattern)} if pattern else None

    goal_context = interpretation.get("goalContext")
    goal_out = (
        {"type": goal_context["type"], "goalName": goal_context.get("goalName"), "text": _compose_goal_context(goal_context)}
        if goal_context else None
    )

    next_step = interpretation.get("nextStep")
    next_step_out = (
        {"recommendationCode": next_step["recommendationCode"], "text": _compose_next_step(next_step, observation)}
        if next_step else None
    )

    return {
        "weekStart": observation.get("weekStart"),
        "weekEnd": observation.get("weekEnd"),
        "opening": _compose_opening(interpretation),
        "highlights": highlights,
        "concerns": concerns,
        "pattern": pattern_out,
        "goalContext": goal_out,
        "nextStep": next_step_out,
    }


# ═══════════════════════════════════════════════════════════════════════
# Phase E — Persistence (spec Phase 22E)
# ═══════════════════════════════════════════════════════════════════════
#
# One completed week -> one reflection. Idempotent per week_start, the
# same discipline as snapshot_service.create_daily_snapshot() and
# notification_repository.save(): a no-op returning the already-
# persisted document if one exists, never overwrites, never recomputes
# a week that's already been reflected on.


def most_recent_completed_week(today=None) -> tuple:
    """
    Returns (week_start, week_end) for the most recently completed ISO
    week (Mon-Sun) relative to `today` (defaults to the real current
    date). The current, still-in-progress week is never returned --
    Phase A rule 2: only completed weeks get a reflection.
    """
    today = today or datetime.now(timezone.utc).date()
    this_monday = today - timedelta(days=today.weekday())
    week_start = this_monday - timedelta(days=7)
    week_end = week_start + timedelta(days=6)
    return week_start, week_end


def get_weekly_reflection(db, uid: str, week_start) -> dict:
    """Returns the persisted reflection for `week_start`, or None if it
    hasn't been generated yet. Never generates -- a pure read."""
    if isinstance(week_start, str):
        week_start = date_cls.fromisoformat(week_start)
    doc = (
        db.collection("users").document(uid)
        .collection("weeklyReflections").document(week_start.isoformat())
        .get()
    )
    return doc.to_dict() if doc.exists else None


def generate_weekly_reflection(db, uid: str, week_start, week_end, generated_at: str = None) -> dict:
    """
    Public API — Phase E. Runs the full Observe -> Interpret -> Compose
    pipeline and persists the result at
    users/{uid}/weeklyReflections/{week_start}. Idempotent: returns the
    existing document unchanged if one already exists for this
    week_start, never overwrites (one completed week -> one reflection).

    The persisted document carries both the composed, human-worded
    reflection (for direct display) and the raw structured
    Interpretation object (for Chat or any other future consumer that
    needs the facts, not the wording) -- per spec Phase 22E Design, so
    nothing needs to recompute the week just to read it differently.
    `observationMetadata` is a light trace (counts, not the full raw
    evidence) -- the composed text already condenses what mattered;
    duplicating all of Phase B's raw category/transaction maps forever
    would be evidence hoarding, not the "assemble, don't duplicate"
    principle this whole feature is built on.
    """
    if isinstance(week_start, str):
        week_start = date_cls.fromisoformat(week_start)
    if isinstance(week_end, str):
        week_end = date_cls.fromisoformat(week_end)

    ref = (
        db.collection("users").document(uid)
        .collection("weeklyReflections").document(week_start.isoformat())
    )
    existing = ref.get()
    if existing.exists:
        return existing.to_dict()

    observation = gather_weekly_observation(db, uid, week_start, week_end)
    interpretation = interpret_weekly_observation(observation)
    reflection = compose_weekly_reflection(interpretation, observation)

    document = {
        "weekStart": week_start.isoformat(),
        "weekEnd": week_end.isoformat(),
        "generatedAt": generated_at or datetime.now(timezone.utc).isoformat(),
        "weeklyReflectionVersion": WEEKLY_REFLECTION_VERSION,
        "opening": reflection["opening"],
        "highlights": reflection["highlights"],
        "concerns": reflection["concerns"],
        "pattern": reflection["pattern"],
        "goalContext": reflection["goalContext"],
        "nextStep": reflection["nextStep"],
        "interpretation": interpretation,
        "observationMetadata": {
            "transactionCount": observation["transactions"]["transactionCount"],
            "snapshotsFound": observation["health"]["snapshotsFound"],
            "monthKeysInvolved": observation["budgets"]["monthKeysInvolved"],
        },
    }
    ref.set(document)
    return document
