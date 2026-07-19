"""
behavior_engine.py
====================
The Behavior Engine — Phase 4.5. See backend/FINANCIAL_ENGINE_SPEC.md,
Phase 4.5.1 "Logging Behavior" and 4.5.2 "Spending Behavior," for the
full contract this file implements; this module must not drift from
that spec without a deliberate revision there first.

Public API so far (Steps 3-8 — Logging, Spending, Saving, Recovery, Milestones, and Behavior Summary):

    record_logging_activity(db, uid, reason, occurred_at=None)
    record_spending_activity(db, uid, overall_health_status, snapshot_date)
    record_saving_activity(db, uid, month_key, actual_savings)
    record_recovery_activity(db, uid, recovery_plan_present, recovery_possible, snapshot_date)
    check_goal_milestones(db, uid, goal_progress, today=None)
    compute_behavior_summary(db, uid, generated_at=None)

compute_behavior_summary() (spec 4.5.6) is read-only — it never writes
to behaviorState/behaviorHistory, only reads them, the same "compute on
demand" shape as Health/Recommendation Engine's own top-level
functions. It answers "how has the user been behaving, over time," and
deliberately never reads Financial/Metrics/Health/Recommendation output
— Behavior and Health can disagree on purpose (a bad day can flip
Health red while months of good habits keep Behavior excellent). Health
changes quickly; Behavior changes slowly — a single broken streak alone
never drops its status; only a *repeated* or *sustained* pattern does
(spec 4.5.6's `UNHEALTHY_SPENDING_PATTERN`/`REPEATED_RECOVERY_FAILURE`,
both backed by counters that only trigger from actual repetition).

FIRST_EXPENSE_LOGGED and LOGGING_STREAK_30_DAYS are checked inline
inside record_logging_activity(); FIRST_HEALTHY_WEEK inline inside
record_spending_activity() — see spec 4.5.5. check_goal_milestones()
is the one milestone with no natural record_*_activity() home (goal
completion isn't triggered by a transaction, day, or month boundary),
so it's exposed as its own function, unwired for the same reason every
other step's integration gap is unwired.

Reads/writes only through services/behavior_state_repository.py — this
module owns the *decisions* (does this trigger count, has the streak
continued or broken), the repository owns the *data access*, per the
ownership invariant frozen in Phase 4.5A.

Note the deliberate asymmetry across the three functions above. Logging
updates immediately, on each qualifying transaction event, because its
question ("did anything happen today") is fully decided the instant it
happens. Spending's question ("how did today end up") can't be decided
until the day is over, so record_spending_activity() has exactly one
legitimate caller — the Step 9 daily scheduler, once per day, after
that day's Daily Snapshot has captured the final overallHealth.status —
never a live transaction route. Saving's question ("did the month end
with positive Actual Savings") can't be decided until the *month* is
over, and — unlike Spending — its trigger infrastructure already
exists: `record_saving_activity()`'s only legitimate caller is the
already-scheduled MONTH_ROLLOVER job (`services/budget_service.py`'s
`run_month_rollover`), not the not-yet-built Step 9 scheduler, which
runs on a different cadence entirely. See spec 4.5.2's "Frozen: the
healthy/overspending streaks are finalized only when the day closes"
and 4.5.3's "Actual Savings" section.
"""

from datetime import date, datetime, timedelta, timezone

from services import behavior_state_repository as repo

BEHAVIOR_ENGINE_VERSION = "1.0.0"

# Fixed Nepal Standard Time offset (UTC+5:45, no daylight saving) — see
# spec's "Frozen: day-boundary timezone" for why this is a constant, not
# server UTC and not a per-user configurable timezone.
LOGGING_TIMEZONE = timezone(timedelta(hours=5, minutes=45))

# Frozen valid-triggers table (spec 4.5.1) — reuses financial_engine's
# RecomputeReason vocabulary directly rather than inventing new names.
_LOGGING_TRIGGERS = {
    "TRANSACTION_CREATED",
    "TRANSACTION_CONFIRMED",
}


def _local_date(occurred_at: datetime = None):
    """Returns the LOGGING_TIMEZONE calendar date for the given moment
    (server UTC 'now' if not given)."""
    moment = occurred_at or datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(LOGGING_TIMEZONE).date()


def _milestone_unlocked(history: dict, code: str) -> bool:
    return any(m["code"] == code for m in history["milestones"])


def _check_milestone(db, uid: str, code: str, milestone_type: str, threshold, condition_met: bool, today) -> None:
    """
    Unlocks a milestone the first time `condition_met` is True, per spec
    4.5.5's "has this ever happened before" test. A no-op if it's already
    unlocked or the condition isn't met — never re-emitted, never
    reversed. Stored as { code, type, threshold, unlockedAt } so future
    thresholds of the same type (e.g. a 100-day logging streak) are new
    definitions, not a schema change.
    """
    if not condition_met:
        return
    history = repo.load_history(db, uid)
    if _milestone_unlocked(history, code):
        return
    repo.append_milestone(db, uid, {
        "code": code,
        "type": milestone_type,
        "threshold": threshold,
        "unlockedAt": today.isoformat(),
    })


def record_logging_activity(db, uid: str, reason: str, occurred_at: datetime = None) -> dict:
    """
    Applies one financial-activity event to Logging Behavior, per the
    frozen state machine (spec 4.5.1). Returns the resulting
    behaviorState.logging section — unchanged if `reason` isn't a valid
    logging trigger, or if today was already logged.

    Idempotent within a day: any number of qualifying events on the same
    local calendar day update the streak exactly once, on the first one.

    Also checks the two logging-owned milestones (spec 4.5.5)
    FIRST_EXPENSE_LOGGED and LOGGING_STREAK_30_DAYS, inline, right after
    the streak they depend on is known — no scheduler dependency, unlike
    Spending/Recovery's milestone-free equivalents.
    """
    if reason not in _LOGGING_TRIGGERS:
        return repo.load_state(db, uid)["logging"]

    repo.initialize(db, uid)
    today = _local_date(occurred_at)
    state = repo.load_state(db, uid)
    logging_state = state["logging"]

    last_logged = logging_state["lastLoggedDate"]
    last_logged_date = (
        datetime.fromisoformat(last_logged).date() if last_logged else None
    )

    if last_logged_date == today:
        # Already logged today — no-op, per the "once per day, not once
        # per transaction" invariant. A qualifying action still happened
        # today, so FIRST_EXPENSE_LOGGED is still worth checking (it's a
        # no-op itself once already unlocked).
        _check_milestone(db, uid, "FIRST_EXPENSE_LOGGED", "LOGGING_FIRST", None, True, today)
        return logging_state

    if last_logged_date == today - timedelta(days=1):
        # Consecutive day — streak continues.
        new_streak = logging_state["currentStreak"] + 1
        streak_started_on = logging_state["streakStartedOn"]
    else:
        # No prior day, or a gap of more than one day — streak restarts
        # at 1, never partially credited for the gap.
        new_streak = 1
        streak_started_on = today.isoformat()

    new_best = max(logging_state["bestStreak"], new_streak)

    repo.update_state(db, uid, {
        "logging.currentStreak": new_streak,
        "logging.bestStreak": new_best,
        "logging.streakStartedOn": streak_started_on,
        "logging.lastLoggedDate": today.isoformat(),
    })

    _check_milestone(db, uid, "FIRST_EXPENSE_LOGGED", "LOGGING_FIRST", None, True, today)
    _check_milestone(db, uid, "LOGGING_STREAK_30_DAYS", "LOGGING_STREAK", 30, new_streak >= 30, today)

    return {
        "currentStreak": new_streak,
        "bestStreak": new_best,
        "streakStartedOn": streak_started_on,
        "lastLoggedDate": today.isoformat(),
    }


def _as_date(value):
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    return datetime.fromisoformat(value).date()


def record_spending_activity(db, uid: str, overall_health_status: str, snapshot_date) -> dict:
    """
    Applies one day's already-closed Overall Health verdict to Spending
    Behavior, per the frozen state machine (spec 4.5.2). `snapshot_date`
    is the calendar day the verdict is *about* (the Daily Snapshot's
    snapshotDate) — required, not defaulted to "now," because this
    function must only ever be called for a day that has already ended.

    Idempotent per day: calling this twice for the same snapshot_date is
    a no-op the second time, protecting against a scheduler/Diff
    Generator retry double-counting a day.
    """
    repo.initialize(db, uid)
    today = _as_date(snapshot_date)
    state = repo.load_state(db, uid)
    spending_state = state["spending"]

    last_evaluated = spending_state["lastEvaluatedDate"]
    last_evaluated_date = (
        datetime.fromisoformat(last_evaluated).date() if last_evaluated else None
    )

    if last_evaluated_date == today:
        # Already evaluated this day — no-op, per the idempotency guarantee.
        return spending_state

    consecutive = last_evaluated_date == today - timedelta(days=1)
    # currentHealthyStreak and currentOverspendingStreak are mutually
    # exclusive by construction (a healthy day always zeroes the other),
    # so "the prior run of my own kind" can be read directly off my own
    # counter — no separate "was yesterday healthy" flag is needed.
    prior_healthy_run = spending_state["currentHealthyStreak"] if consecutive else 0
    prior_overspend_run = spending_state["currentOverspendingStreak"] if consecutive else 0

    healthy = overall_health_status != "red"

    if healthy:
        new_healthy = prior_healthy_run + 1
        new_overspend = 0
        new_best_healthy = max(spending_state["bestHealthyStreak"], new_healthy)
        new_last_healthy_date = today.isoformat()
    else:
        new_healthy = 0
        new_overspend = prior_overspend_run + 1
        new_best_healthy = spending_state["bestHealthyStreak"]
        new_last_healthy_date = spending_state["lastHealthyDate"]

    repo.update_state(db, uid, {
        "spending.currentHealthyStreak": new_healthy,
        "spending.bestHealthyStreak": new_best_healthy,
        "spending.currentOverspendingStreak": new_overspend,
        "spending.lastHealthyDate": new_last_healthy_date,
        "spending.lastEvaluatedDate": today.isoformat(),
    })

    _check_milestone(db, uid, "FIRST_HEALTHY_WEEK", "HEALTHY_STREAK", 7, new_healthy >= 7, today)

    return {
        "currentHealthyStreak": new_healthy,
        "bestHealthyStreak": new_best_healthy,
        "currentOverspendingStreak": new_overspend,
        "lastHealthyDate": new_last_healthy_date,
        "lastEvaluatedDate": today.isoformat(),
    }


def _next_month_key(month_key: str) -> str:
    year, month = (int(part) for part in month_key.split("-"))
    if month == 12:
        return f"{year + 1}-01"
    return f"{year}-{month + 1:02d}"


def record_saving_activity(db, uid: str, month_key: str, actual_savings: float) -> dict:
    """
    Applies one completed month's Actual Savings (spec 4.5.3: Income -
    confirmed Spending for that month, read from the closed month's
    financialSummary — never Savings Pool, never Projected Savings) to
    Saving Behavior's protection streak.

    `month_key` is the month that just closed (e.g. "2026-07"); this
    function must only ever be called after that month has fully ended
    — its only legitimate caller is the MONTH_ROLLOVER job.

    Idempotent per month: calling this twice for the same month_key is
    a no-op the second time.
    """
    repo.initialize(db, uid)
    state = repo.load_state(db, uid)
    saving_state = state["saving"]

    last_evaluated = saving_state["lastMonthKeyEvaluated"]

    if last_evaluated == month_key:
        # Already evaluated this month — no-op, per the idempotency guarantee.
        return saving_state

    consecutive = last_evaluated is not None and _next_month_key(last_evaluated) == month_key
    prior_streak = saving_state["currentProtectionStreak"] if consecutive else 0

    successful = actual_savings > 0
    new_streak = prior_streak + 1 if successful else 0
    new_best = max(saving_state["bestProtectionStreak"], new_streak)

    repo.update_state(db, uid, {
        "saving.currentProtectionStreak": new_streak,
        "saving.bestProtectionStreak": new_best,
        "saving.lastMonthKeyEvaluated": month_key,
    })

    return {
        "currentProtectionStreak": new_streak,
        "bestProtectionStreak": new_best,
        "lastMonthKeyEvaluated": month_key,
    }


def record_recovery_activity(
    db, uid: str, recovery_plan_present: bool, recovery_possible: bool, snapshot_date
) -> dict:
    """
    Applies one day's Recovery Plan state (spec 4.5.4) to Recovery
    Behavior's lifecycle. `recovery_plan_present`/`recovery_possible` are
    that day's already-closed values (Metrics Engine's
    compute_recovery_plan() output for that day — presence, and
    recoveryPossible if present); `recovery_possible` is ignored when
    `recovery_plan_present` is False.

    A recovery attempt opens the first day the plan is present, stays
    open across however many days it takes, and closes the day the plan
    disappears — classified RECOVERY_FAILED if `recoveryPossible` was
    ever False at any point during the attempt, RECOVERY_COMPLETED
    otherwise. Only ever called once per day; naturally idempotent for a
    repeated call on the same day, because closing an attempt resets
    openRecoveryStartedOn, and re-opening only happens from a genuinely
    closed state.
    """
    repo.initialize(db, uid)
    today = _as_date(snapshot_date)
    state = repo.load_state(db, uid)
    recovery_state = state["recovery"]

    is_open = recovery_state["openRecoveryStartedOn"] is not None

    if not is_open:
        if not recovery_plan_present:
            # No recovery open, none needed today -- nothing to do.
            return recovery_state

        # A new recovery attempt opens today.
        repo.update_state(db, uid, {
            "recovery.openRecoveryStartedOn": today.isoformat(),
            "recovery.openRecoveryEverImpossible": recovery_possible is False,
            "recovery.totalAttempts": recovery_state["totalAttempts"] + 1,
        })
        return repo.load_state(db, uid)["recovery"]

    # A recovery is currently open.
    ever_impossible = recovery_state["openRecoveryEverImpossible"] or recovery_possible is False

    if recovery_plan_present:
        # Still open -- only the ever-impossible flag can change; no
        # streak/counter update until the attempt actually closes.
        if ever_impossible != recovery_state["openRecoveryEverImpossible"]:
            repo.update_state(db, uid, {"recovery.openRecoveryEverImpossible": ever_impossible})
            return repo.load_state(db, uid)["recovery"]
        return recovery_state

    # Recovery Plan disappeared today -- the attempt closes.
    started_on = recovery_state["openRecoveryStartedOn"]
    if ever_impossible:
        new_streak = 0
        new_total_resolved = recovery_state["totalResolved"]
        new_total_failed = recovery_state["totalFailed"] + 1
        outcome = "failed"
    else:
        new_streak = recovery_state["currentStreak"] + 1
        new_total_resolved = recovery_state["totalResolved"] + 1
        new_total_failed = recovery_state["totalFailed"]
        outcome = "resolved"
    new_best = max(recovery_state["bestStreak"], new_streak)

    repo.update_state(db, uid, {
        "recovery.currentStreak": new_streak,
        "recovery.bestStreak": new_best,
        "recovery.totalResolved": new_total_resolved,
        "recovery.totalFailed": new_total_failed,
        "recovery.openRecoveryStartedOn": None,
        "recovery.openRecoveryEverImpossible": False,
    })
    repo.append_recovery_attempt(db, uid, {
        "startedOn": started_on,
        "resolvedOn": today.isoformat(),
        "outcome": outcome,
    })

    return repo.load_state(db, uid)["recovery"]


def check_goal_milestones(db, uid: str, goal_progress: list, today=None) -> None:
    """
    Checks FIRST_GOAL_COMPLETED (spec 4.5.5) against already-computed
    goal progress — never recomputes progress itself, per the same
    "receives the fact, doesn't derive it" pattern record_spending_activity
    already follows for overall_health_status.

    `goal_progress` is a list of {"goalId", "savedSoFar", "targetAmount"}
    for the caller's active goals (goal_service.compute_goal_progress()'s
    output, reshaped by the caller — Behavior Engine does not call
    goal_service itself). Unlocks once, the first time any single goal's
    savedSoFar reaches its own targetAmount; a second or third completed
    goal afterward is a no-op, per the "has this ever happened" test.
    """
    today = _as_date(today) if today is not None else datetime.now(timezone.utc).astimezone(LOGGING_TIMEZONE).date()
    any_completed = any(
        g["targetAmount"] > 0 and g["savedSoFar"] >= g["targetAmount"]
        for g in goal_progress
    )
    _check_milestone(db, uid, "FIRST_GOAL_COMPLETED", "GOAL_COMPLETED", None, any_completed, today)


# ─── Behavior Summary (spec 4.5.6, Step 8) ─────────────────────────────────

# Confidence each reason carries, per its source category — reused
# directly from each category's own already-frozen Output confidence
# (4.5.1/4.5.2/4.5.3/4.5.4), never a new judgment invented here.
_BEHAVIOR_CONFIDENCE = {
    "logging": "high",
    "spending": "medium",
    "saving": "high",
    "recovery": "medium",
}
_CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}

_POSITIVE_OR_NEGATIVE_CODES = {
    "CONSISTENT_LOGGING", "HEALTHY_SPENDING", "MONTHLY_SAVING_SUCCESS",
    "RECOVERY_SUCCESS", "UNHEALTHY_SPENDING_PATTERN", "REPEATED_RECOVERY_FAILURE",
}

# First-match priority within each status, for picking primaryReason
# out of every reason that triggered.
_PRIMARY_REASON_PRIORITY = {
    "inactive": ["NEW_USER"],
    "excellent": ["CONSISTENT_LOGGING", "HEALTHY_SPENDING", "MONTHLY_SAVING_SUCCESS"],
    "good": ["CONSISTENT_LOGGING", "HEALTHY_SPENDING", "MONTHLY_SAVING_SUCCESS", "RECOVERY_SUCCESS"],
    "needs_improvement": ["UNHEALTHY_SPENDING_PATTERN", "REPEATED_RECOVERY_FAILURE"],
    "building": ["BUILDING_HABITS"],
}


def _evaluate_behavior_reasons(state: dict, history: dict) -> list:
    """Returns [(code, source), ...] for every reason (spec 4.5.6's
    frozen table) that independently evaluates true right now."""
    logging_state = state["logging"]
    spending_state = state["spending"]
    saving_state = state["saving"]
    recovery_state = state["recovery"]
    recovery_attempts = history["recoveryAttempts"]

    reasons = []

    if logging_state["bestStreak"] == 0:
        reasons.append(("NEW_USER", "logging"))
    elif logging_state["currentStreak"] >= 7:
        reasons.append(("CONSISTENT_LOGGING", "logging"))

    if spending_state["currentHealthyStreak"] >= 7:
        reasons.append(("HEALTHY_SPENDING", "spending"))
    if spending_state["currentOverspendingStreak"] >= 7:
        reasons.append(("UNHEALTHY_SPENDING_PATTERN", "spending"))

    if saving_state["currentProtectionStreak"] >= 1:
        reasons.append(("MONTHLY_SAVING_SUCCESS", "saving"))

    if recovery_attempts and recovery_attempts[-1]["outcome"] == "resolved":
        reasons.append(("RECOVERY_SUCCESS", "recovery"))
    if recovery_state["totalFailed"] >= 2:
        reasons.append(("REPEATED_RECOVERY_FAILURE", "recovery"))

    codes = {code for code, _source in reasons}
    if logging_state["bestStreak"] > 0 and not (codes & _POSITIVE_OR_NEGATIVE_CODES):
        reasons.append(("BUILDING_HABITS", "logging"))

    return reasons


def _determine_behavior_status(reasons: list) -> str:
    """
    Waterfall, first match wins (spec 4.5.6). Needs Improvement is
    checked before the Building fallback, deliberately — Building's
    condition is broad enough to otherwise swallow every negative-
    pattern case. Excellent/Good are checked first regardless, so a
    sustained positive pattern is never overridden by one negative
    pattern — the same slow-change principle in both directions.
    """
    codes = {code for code, _source in reasons}
    if "NEW_USER" in codes:
        return "inactive"
    if {"CONSISTENT_LOGGING", "HEALTHY_SPENDING", "MONTHLY_SAVING_SUCCESS"} <= codes:
        return "excellent"
    if codes & {"CONSISTENT_LOGGING", "HEALTHY_SPENDING", "MONTHLY_SAVING_SUCCESS", "RECOVERY_SUCCESS"}:
        return "good"
    if codes & {"UNHEALTHY_SPENDING_PATTERN", "REPEATED_RECOVERY_FAILURE"}:
        return "needs_improvement"
    return "building"


def _primary_reason(status: str, reasons: list):
    codes = [code for code, _source in reasons]
    for code in _PRIMARY_REASON_PRIORITY[status]:
        if code in codes:
            return code
    return codes[0] if codes else None


def _determine_behavior_confidence(reasons: list) -> str:
    """Weakest link across whichever reasons triggered — "nothing found"
    (no reasons at all) defaults to high, same reasoning Health's own
    _determine_confidence uses for a clean Green."""
    if not reasons:
        return "high"
    return min(
        (_BEHAVIOR_CONFIDENCE[source] for _code, source in reasons),
        key=lambda c: _CONFIDENCE_RANK.get(c, 1),
    )


def _build_behavior_trace(state: dict, history: dict, reasons: list) -> list:
    logging_state, spending_state = state["logging"], state["spending"]
    saving_state, recovery_state = state["saving"], state["recovery"]
    trace = [
        f"logging: currentStreak={logging_state['currentStreak']}, bestStreak={logging_state['bestStreak']}",
        f"spending: currentHealthyStreak={spending_state['currentHealthyStreak']}, "
        f"currentOverspendingStreak={spending_state['currentOverspendingStreak']}",
        f"saving: currentProtectionStreak={saving_state['currentProtectionStreak']}",
        f"recovery: totalFailed={recovery_state['totalFailed']}, "
        f"openRecoveryStartedOn={recovery_state['openRecoveryStartedOn']}",
    ]
    if history["recoveryAttempts"]:
        trace.append(f"most recent recovery attempt outcome={history['recoveryAttempts'][-1]['outcome']}")
    trace.append(f"reasons triggered: {[code for code, _source in reasons]}")
    return trace


def compute_behavior_summary(db, uid: str, generated_at: str = None) -> dict:
    """
    Behavior Summary (spec 4.5.6) — read-only, never writes state.
    Answers "how has the user been behaving, over time," reading only
    behaviorState/behaviorHistory — never Financial/Metrics/Health/
    Recommendation output.
    """
    repo.initialize(db, uid)
    state = repo.load_state(db, uid)
    history = repo.load_history(db, uid)

    reasons = _evaluate_behavior_reasons(state, history)
    status = _determine_behavior_status(reasons)

    return {
        "status": status,
        "primaryReason": _primary_reason(status, reasons),
        "reasons": [code for code, _source in reasons],
        "confidence": _determine_behavior_confidence(reasons),
        "summaryVersion": BEHAVIOR_ENGINE_VERSION,
        "generatedAt": generated_at or datetime.now(timezone.utc).isoformat(),
        "behaviorTrace": _build_behavior_trace(state, history, reasons),
    }
