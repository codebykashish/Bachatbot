"""
notification_generator.py
============================
Notification Generator — Phase 5.6B. See backend/FINANCIAL_ENGINE_SPEC.md,
"Phase 5.6 — Notification Generator Philosophy" through "Rule 8 —
Generator Fails Fast," for the full contract this file implements.

This module owns composition only. It never detects changes, evaluates
health, computes streaks, or decides whether an event is eligible to
notify at all (Rule 1) — the caller must have already confirmed
eligibility (the 5.2 waterfall, not yet implemented) before calling
generate_notification(). Reading the Priority/Frequency/Timing/Template
tables below is a pure, stateless lookup — not a re-decision of
anything Eligibility's stateful gates (notification history, live
context) are responsible for.

Public API:
    generate_notification(event) -> dict
"""

# ─── Priority Matrix (spec 5.3) ────────────────────────────────────────────
_PRIORITY = {
    "RECOVERY_BECAME_IMPOSSIBLE": "Critical",
    "HEALTH_WORSENED": "High",
    "RECOVERY_STARTED": "High",
    "RECOVERY_FAILED": "High",
    "CATEGORY_BECAME_EXHAUSTED": "High",
    "HEALTHY_STREAK_BROKEN": "High",
    "PRIMARY_RECOMMENDATION_CHANGED": "Normal",
    "RECOVERY_COMPLETED": "Normal",
    "LOGGING_STREAK_BROKEN": "Normal",
    "SAVING_STREAK_BROKEN": "Normal",
    "HEALTH_IMPROVED": "Low",
    "LOGGING_STREAK_EXTENDED": "Low",
    "HEALTHY_STREAK_EXTENDED": "Low",
    "SAVING_STREAK_EXTENDED": "Low",
    "MILESTONE_UNLOCKED": "Low",
    "UNUSUAL_SPENDING_DETECTED": "High",
}

# ─── Frequency Matrix (spec 5.4A) ──────────────────────────────────────────
_FREQUENCY = {
    "PRIMARY_RECOMMENDATION_CHANGED": "UNTIL_RESOLVED",
    "HEALTH_WORSENED": "DAILY",
    "HEALTH_IMPROVED": "ONCE",
    "RECOVERY_STARTED": "ONCE",
    "RECOVERY_BECAME_IMPOSSIBLE": "DAILY",
    "RECOVERY_COMPLETED": "ONCE",
    "RECOVERY_FAILED": "ONCE",
    "CATEGORY_BECAME_EXHAUSTED": "DAILY",
    "LOGGING_STREAK_EXTENDED": "WEEKLY",
    "LOGGING_STREAK_BROKEN": "DAILY",
    "HEALTHY_STREAK_EXTENDED": "WEEKLY",
    "HEALTHY_STREAK_BROKEN": "DAILY",
    "SAVING_STREAK_EXTENDED": "MONTHLY",
    "SAVING_STREAK_BROKEN": "MONTHLY",
    "MILESTONE_UNLOCKED": "ONCE",
    # DAILY here is a defense-in-depth backstop, not the real dedup
    # mechanism -- eventId already scopes by date+category (Gate 4,
    # Already Informed, already rejects a same-day repeat). Scoped by
    # `category` (see eligibility_engine._FREQUENCY_SCOPE_FIELD) so a
    # DAILY check on one category can never block a different
    # category's alert the same day -- the exact shape of bug
    # MILESTONE_UNLOCKED's ONCE policy had before it was scoped by code.
    "UNUSUAL_SPENDING_DETECTED": "DAILY",
}

# ─── Timing Matrix (spec 5.5A) ─────────────────────────────────────────────
_TIMING = {
    "PRIMARY_RECOMMENDATION_CHANGED": "IMMEDIATE",
    "HEALTH_WORSENED": "IMMEDIATE",
    "HEALTH_IMPROVED": "IMMEDIATE",
    "RECOVERY_STARTED": "IMMEDIATE",
    "RECOVERY_BECAME_IMPOSSIBLE": "IMMEDIATE",
    "RECOVERY_COMPLETED": "IMMEDIATE",
    "RECOVERY_FAILED": "IMMEDIATE",
    "CATEGORY_BECAME_EXHAUSTED": "IMMEDIATE",
    "LOGGING_STREAK_EXTENDED": "NIGHT",
    "LOGGING_STREAK_BROKEN": "NIGHT",
    "HEALTHY_STREAK_EXTENDED": "NIGHT",
    "HEALTHY_STREAK_BROKEN": "NIGHT",
    "SAVING_STREAK_EXTENDED": "MONTH_END",
    "SAVING_STREAK_BROKEN": "MONTH_END",
    "MILESTONE_UNLOCKED": "IMMEDIATE",
    "UNUSUAL_SPENDING_DETECTED": "IMMEDIATE",
}

# ─── Template Matrix (spec 5.6A) ───────────────────────────────────────────
# Each entry: (templateId, title, body, cta). Title/body may reference
# payload keys via {from}/{to}/{category} — the REAL payload shape
# diff_generator.py actually produces (spec 5.6's own correction), never
# the illustrative "{n}" placeholder first sketched.
_TEMPLATES = {
    "PRIMARY_RECOMMENDATION_CHANGED": ("TITLE_RECOMMENDATION_CHANGED", "Your recommendation has changed", "Your financial situation changed, so has our advice", "View recommendation"),
    "HEALTH_WORSENED": ("TITLE_HEALTH_WORSENED", "Spending pace increased", "You're spending faster than your monthly plan", "Review your spending"),
    "HEALTH_IMPROVED": ("TITLE_HEALTH_IMPROVED", "Your finances are back on track", "Your spending pace has improved this week", "View your report"),
    "RECOVERY_STARTED": ("TITLE_RECOVERY_STARTED", "Recovery plan started", "We've built a plan to help you get back on track", "Open Recovery Plan"),
    "RECOVERY_BECAME_IMPOSSIBLE": ("TITLE_RECOVERY_IMPOSSIBLE", "Your recovery plan needs attention", "The current plan is no longer enough — let's adjust it", "Review Recovery Plan"),
    "RECOVERY_COMPLETED": ("TITLE_RECOVERY_COMPLETED", "Recovery complete", "You brought your spending back on track", "View your progress"),
    "RECOVERY_FAILED": ("TITLE_RECOVERY_FAILED", "This recovery attempt didn't succeed", "Here's what happened, and what might help next time", "View recovery history"),
    "CATEGORY_BECAME_EXHAUSTED": ("TITLE_CATEGORY_EXHAUSTED", "{category} budget exhausted", "You've used all of this month's {category} budget", "Review {category} spending"),
    "LOGGING_STREAK_EXTENDED": ("TITLE_LOGGING_EXTENDED", "{to}-day logging streak", "Consistent budgeters rarely miss two days in a row", "View your streak"),
    "LOGGING_STREAK_BROKEN": ("TITLE_LOGGING_BROKEN", "Your logging streak ended", "Tomorrow starts a new opportunity", "Log today's expenses"),
    "HEALTHY_STREAK_EXTENDED": ("TITLE_HEALTHY_EXTENDED", "{to} healthy days", "Your spending has stayed on track this week", "View your streak"),
    "HEALTHY_STREAK_BROKEN": ("TITLE_HEALTHY_BROKEN", "Your healthy streak ended today", "Tomorrow starts a new opportunity", "Review today's spending"),
    "SAVING_STREAK_EXTENDED": ("TITLE_SAVING_EXTENDED", "Another month protected", "You saved money again this month", "View your savings"),
    "SAVING_STREAK_BROKEN": ("TITLE_SAVING_BROKEN", "This month's savings goal was missed", "Here's what changed this month", "View monthly report"),
    "UNUSUAL_SPENDING_DETECTED": (
        "TITLE_UNUSUAL_SPENDING",
        "Unusual {category} spending today",
        "You've spent Rs {todayTotal} on {category} today — about double your usual Rs {baselineAverage}",
        "Review {category} spending",
    ),
}

# ─── Deep Link Matrix (Step 13's own completion of spec 5.6B's
# reserved-but-empty deepLink slot) ──────────────────────────────────────────
# A semantic destination key, never a Flutter class name — this module
# has no business knowing Flutter route/widget names. The frontend owns
# the key -> screen mapping. MILESTONE_UNLOCKED and the streak events
# share "streak" regardless of milestone code, since they all belong on
# the same Behavior/Streak screen.
_DEEP_LINKS = {
    "HEALTH_WORSENED": "health",
    "HEALTH_IMPROVED": "health",
    "PRIMARY_RECOMMENDATION_CHANGED": "health",
    "RECOVERY_STARTED": "health",
    "RECOVERY_BECAME_IMPOSSIBLE": "health",
    "RECOVERY_COMPLETED": "health",
    "RECOVERY_FAILED": "health",
    "CATEGORY_BECAME_EXHAUSTED": "category_detail",
    "MILESTONE_UNLOCKED": "streak",
    "LOGGING_STREAK_EXTENDED": "streak",
    "LOGGING_STREAK_BROKEN": "streak",
    "HEALTHY_STREAK_EXTENDED": "streak",
    "HEALTHY_STREAK_BROKEN": "streak",
    "SAVING_STREAK_EXTENDED": "streak",
    "SAVING_STREAK_BROKEN": "streak",
    "UNUSUAL_SPENDING_DETECTED": "category_detail",
}

# TRANSACTION_CREATED/TRANSACTION_CONFIRMED — deliberately absent from
# every matrix above (spec Phase 21). They were never designed-but-
# forgotten Notification Engine events; they started as
# financial_engine.RecomputeReason values (Phase 1.5), and Phase 5
# borrowed that existing naming to fill out matrix rows for
# completeness discipline, despite no producer ever existing (still
# true as of the Phase 5.9/13.6 audits — no Diff Matrix row, no
# scheduler awareness of individual transactions). Unlike NEW_BEST_STREAK
# (a genuinely missing feature with no substitute), a complete,
# already-working notification mechanism for "a transaction happened"
# already exists: every transaction-creation path writes its own
# `alerts` doc ("expense"/"income"/"transaction_confirmed"/
# "pending_transaction"), delivered in real time by AlertPopupService.
# Giving these two codes a real producer here would create a SECOND
# notification for the same transaction through a second system.
# If you're reading this because the "missing policy" check below
# flagged them again -- don't add rows back. The Notification Engine
# does not own transaction lifecycle notifications; it owns
# behavior/state-change notifications the alert system doesn't already
# cover. RecomputeReason.TRANSACTION_CREATED/TRANSACTION_CONFIRMED in
# financial_engine.py are a different concept (why a recompute ran) and
# are untouched by this removal.

# MILESTONE_UNLOCKED is keyed by its payload's milestone code, not a
# single fixed template — one row per milestone (spec 5.6A: `TITLE_
# MILESTONE_{code}`), kept separate from _TEMPLATES since it needs a
# second-level lookup the other events don't.
_MILESTONE_TEMPLATES = {
    "FIRST_EXPENSE_LOGGED": ("TITLE_MILESTONE_FIRST_EXPENSE_LOGGED", "First expense logged!", "You've started your budgeting journey", "View milestone"),
    "FIRST_HEALTHY_WEEK": ("TITLE_MILESTONE_FIRST_HEALTHY_WEEK", "First Healthy Week unlocked!", "You kept your spending healthy for 7 days straight", "View milestone"),
    "LOGGING_STREAK_30_DAYS": ("TITLE_MILESTONE_LOGGING_STREAK_30_DAYS", "30-day logging streak!", "You've logged your expenses for 30 days straight", "View milestone"),
    "FIRST_GOAL_COMPLETED": ("TITLE_MILESTONE_FIRST_GOAL_COMPLETED", "First goal completed!", "You reached your first savings goal", "View milestone"),
}


class NotificationGeneratorError(ValueError):
    """Raised whenever any required policy is missing — Rule 8: fail
    fast, never assign a default, invent a template, or produce a
    partial notification."""


def _milestone_template(payload: dict):
    code = payload.get("code")
    if code not in _MILESTONE_TEMPLATES:
        raise NotificationGeneratorError(
            f"MILESTONE_UNLOCKED payload references unknown milestone code '{code}'"
        )
    return _MILESTONE_TEMPLATES[code]


def generate_notification(event: dict) -> dict:
    """
    Assembles exactly one Notification object from exactly one
    already-eligible Event (spec 5.6B). The caller must have already
    confirmed eligibility (5.2's waterfall) — this function never
    re-evaluates that decision (Rule 1).

    Deterministic and pure (Rule 4): no timestamps, no randomness, no
    database writes, no side effects. Raises NotificationGeneratorError
    if any required policy is missing for this event's code (Rule 8) —
    never silently defaults, never partially assembles.
    """
    code = event.get("event")
    if not code:
        raise NotificationGeneratorError("Event is missing its 'event' code")

    payload = event.get("payload") or {}

    if code == "MILESTONE_UNLOCKED":
        template_id, title, body, cta = _milestone_template(payload)
    else:
        missing = [
            name for name, table in (
                ("Priority", _PRIORITY), ("Frequency", _FREQUENCY),
                ("Timing", _TIMING), ("Template", _TEMPLATES),
                ("Deep Link", _DEEP_LINKS),
            )
            if code not in table
        ]
        if missing:
            raise NotificationGeneratorError(
                f"Event code '{code}' is missing required policy: {missing}"
            )
        template_id, title_tpl, body_tpl, cta_tpl = _TEMPLATES[code]
        try:
            title = title_tpl.format(**payload)
            body = body_tpl.format(**payload)
            cta = cta_tpl.format(**payload)
        except KeyError as exc:
            raise NotificationGeneratorError(
                f"Event code '{code}' payload {payload} is missing key {exc} "
                f"required by its template"
            )

    if code != "MILESTONE_UNLOCKED":
        priority = _PRIORITY[code]
        frequency = _FREQUENCY[code]
        timing = _TIMING[code]
    else:
        priority = _PRIORITY["MILESTONE_UNLOCKED"]
        frequency = _FREQUENCY["MILESTONE_UNLOCKED"]
        timing = _TIMING["MILESTONE_UNLOCKED"]

    return {
        "eventId": event.get("eventId"),
        "eventCode": code,
        "priority": priority,
        "frequency": frequency,
        "timing": timing,
        # interruptionLevel: still not computable — needs the 5.2 Context
        # gate (live app state), which isn't implemented. Named honestly
        # as None rather than fabricated; the slot stays on the object
        # (spec 5.6B's frozen shape) for when that dependency exists.
        "interruptionLevel": None,
        # deepLink: now real (Step 13's completion) — a semantic
        # destination key, looked up the same way Priority/Frequency/
        # Timing already are, per event code (MILESTONE_UNLOCKED
        # included, regardless of which milestone code it carries).
        "deepLink": _DEEP_LINKS[code],
        "templateId": template_id,
        "title": title,
        "body": body,
        "cta": cta,
        "payload": payload,
        "status": "Created",
    }
