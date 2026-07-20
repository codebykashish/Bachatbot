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
    "TRANSACTION_CREATED": "High",
    "TRANSACTION_CONFIRMED": "High",
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
}

# ─── Frequency Matrix (spec 5.4A) ──────────────────────────────────────────
_FREQUENCY = {
    "TRANSACTION_CREATED": "UNTIL_RESOLVED",
    "TRANSACTION_CONFIRMED": "UNTIL_RESOLVED",
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
}

# ─── Timing Matrix (spec 5.5A) ─────────────────────────────────────────────
_TIMING = {
    "TRANSACTION_CREATED": "IMMEDIATE",
    "TRANSACTION_CONFIRMED": "IMMEDIATE",
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
}

# ─── Template Matrix (spec 5.6A) ───────────────────────────────────────────
# Each entry: (templateId, title, body, cta). Title/body may reference
# payload keys via {from}/{to}/{category} — the REAL payload shape
# diff_generator.py actually produces (spec 5.6's own correction), never
# the illustrative "{n}" placeholder first sketched.
_TEMPLATES = {
    "TRANSACTION_CREATED": ("TITLE_PENDING_TXN", "New transaction detected", "Was this your transaction?", "Confirm transaction"),
    "TRANSACTION_CONFIRMED": ("TITLE_PENDING_TXN", "New transaction detected", "Was this your transaction?", "Confirm transaction"),
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
}

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
        # Not yet computable, named honestly rather than fabricated:
        # interruptionLevel needs the 5.2 Context gate (live app state),
        # which isn't implemented; deepLink needs Flutter's actual route
        # names (Step 13), which don't exist yet. Both slots are always
        # present on the object (spec 5.6B's frozen shape), populated
        # with real values once their dependency exists.
        "interruptionLevel": None,
        "deepLink": None,
        "templateId": template_id,
        "title": title,
        "body": body,
        "cta": cta,
        "payload": payload,
        "status": "Created",
    }
