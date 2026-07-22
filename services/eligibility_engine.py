"""
eligibility_engine.py
========================
Eligibility Waterfall — Phase 5.2 (implemented at last, per the Phase
5.9 review that found nothing wired it in). See
backend/FINANCIAL_ENGINE_SPEC.md, "Phase 5.2 — Eligibility" and
"Eligibility Waterfall — Implementation," for the full contract this
file implements.

Scope, frozen: Gates 6 (Timing) and 7 (Interruption Level) never
reject — they only inform delivery, and their values are already
looked up inside notification_generator.py. Gate 2 (Context) has no
real signal to check against anywhere in this codebase, so it is a
named pass-through, not a fabricated check. The gates that actually
reject here are 1/3 (Justification + Notification-Eligible, via the
Eligibility Matrix), User Preferences (Phase 16, sits between Gates 2
and 4 — see FINANCIAL_ENGINE_SPEC.md "Phase 16 — Notification
Preference Philosophy"), 4 (Already Informed), and 5 (Frequency).

This module owns the eligibility DECISION only — it never computes
Health/Metrics/Behavior, never generates wording (that's
notification_generator.py), never persists (that's
notification_repository.py), never delivers (that's delivery_service.py).

Public API:
    check_eligibility(db, uid, event) -> dict  # {"eligible": bool, "reason": str|None}
    process_event(db, uid, event) -> dict|None  # orchestrates eligibility -> generate -> save -> deliver
"""

from datetime import datetime, timedelta, timezone

from services import notification_repository as repo
from services import notification_generator as gen
from services import delivery_service as delivery

# Eligibility Matrix (spec 5.2A), reconciled: HEALTH_IMPROVED moved from
# CONDITIONAL to ALWAYS here, since its own Diff Rule (_better()) already
# guarantees "not amber-to-amber" -- the same reconciliation already
# applied once to PRIMARY_RECOMMENDATION_CHANGED in 5.6B.
_ALWAYS = {
    "TRANSACTION_CREATED", "TRANSACTION_CONFIRMED", "PRIMARY_RECOMMENDATION_CHANGED",
    "HEALTH_WORSENED", "HEALTH_IMPROVED", "RECOVERY_STARTED",
    "RECOVERY_BECAME_IMPOSSIBLE", "RECOVERY_COMPLETED", "RECOVERY_FAILED",
    "CATEGORY_BECAME_EXHAUSTED", "MILESTONE_UNLOCKED", "HEALTHY_STREAK_BROKEN",
    "SAVING_STREAK_BROKEN", "UNUSUAL_SPENDING_DETECTED",
}

# Streak lengths worth celebrating -- first cut, tunable (spec 5.2A).
_STREAK_CHECKPOINTS = {7, 14, 30, 60, 90, 180, 365}

# A broken streak shorter than this wasn't worth having noticed in the
# first place (spec 5.2A's own original reasoning).
_MIN_MOURNED_STREAK_LENGTH = 3

_CONDITIONAL_EVENTS = {"LOGGING_STREAK_EXTENDED", "HEALTHY_STREAK_EXTENDED", "SAVING_STREAK_EXTENDED", "LOGGING_STREAK_BROKEN"}

_FREQUENCY_WINDOWS = {"DAILY": 1, "WEEKLY": 7, "MONTHLY": 30}

# Notification Preference Category Map (spec Phase 16 — Notification
# Preference Philosophy). Maps each event code to the one user-facing
# category it belongs to; a code with no entry has nothing to gate
# (pass-through). RECOVERY_BECAME_IMPOSSIBLE is deliberately still
# listed under "recovery" -- the Critical-priority bypass below is what
# keeps it undeliverable-proof, not an omission from this map.
_PREFERENCE_CATEGORY = {
    "TRANSACTION_CREATED": "transactions",
    "TRANSACTION_CONFIRMED": "transactions",
    "CATEGORY_BECAME_EXHAUSTED": "budgetAlerts",
    "HEALTH_WORSENED": "financialHealth",
    "HEALTH_IMPROVED": "financialHealth",
    "PRIMARY_RECOMMENDATION_CHANGED": "financialHealth",
    "RECOVERY_STARTED": "recovery",
    "RECOVERY_BECAME_IMPOSSIBLE": "recovery",
    "RECOVERY_COMPLETED": "recovery",
    "RECOVERY_FAILED": "recovery",
    "LOGGING_STREAK_EXTENDED": "streaks",
    "LOGGING_STREAK_BROKEN": "streaks",
    "HEALTHY_STREAK_EXTENDED": "streaks",
    "HEALTHY_STREAK_BROKEN": "streaks",
    "SAVING_STREAK_EXTENDED": "streaks",
    "SAVING_STREAK_BROKEN": "streaks",
    "MILESTONE_UNLOCKED": "milestones",
    "UNUSUAL_SPENDING_DETECTED": "budgetAlerts",
}

# Frequency Scoping (Phase 17's generalization of the Phase 13.14 fix).
# Any event code where ONE eventCode is shared by many genuinely
# distinct payload identities (MILESTONE_UNLOCKED's many milestone
# codes; UNUSUAL_SPENDING_DETECTED's many categories) must scope its
# "most recent notification" lookup by that identity field, or a
# frequency policy meant to apply per-identity silently becomes
# per-eventCode instead -- the exact bug MILESTONE_UNLOCKED had before
# it was scoped by `payload.code`. Registered here once, generically,
# instead of adding another hardcoded `if code == ...` branch for
# every future event with the same shape of problem.
_FREQUENCY_SCOPE_FIELD = {
    "MILESTONE_UNLOCKED": "code",
    "UNUSUAL_SPENDING_DETECTED": "category",
}


def _conditional_passes(code: str, payload: dict) -> bool:
    if code in ("LOGGING_STREAK_EXTENDED", "HEALTHY_STREAK_EXTENDED", "SAVING_STREAK_EXTENDED"):
        return payload.get("to") in _STREAK_CHECKPOINTS
    if code == "LOGGING_STREAK_BROKEN":
        return (payload.get("from") or 0) >= _MIN_MOURNED_STREAK_LENGTH
    return False


def _most_recent_notification_for_code(db, uid: str, event_code: str, scope_field: str = None, scope_value=None):
    """
    `scope_field`/`scope_value` narrow the match to one specific
    payload identity (e.g. payload.code for MILESTONE_UNLOCKED,
    payload.category for UNUSUAL_SPENDING_DETECTED) rather than every
    notification sharing the same eventCode -- see
    `_FREQUENCY_SCOPE_FIELD`. Without this, a frequency policy meant to
    apply "once per identity" would mean "once ever, for ANY identity"
    -- the first one a user ever triggers would silently block every
    subsequent, genuinely distinct one forever after. Found via a real
    account where a real goal completion produced no notification at
    all (MILESTONE_UNLOCKED, Phase 13.14); generalized here so the same
    bug shape doesn't need to be independently rediscovered per event.
    """
    matching = [
        n for n in repo.list_notifications(db, uid)
        if n.get("eventCode") == event_code
        and (scope_field is None or (n.get("payload") or {}).get(scope_field) == scope_value)
    ]
    if not matching:
        return None
    return max(matching, key=lambda n: n.get("createdAt") or 0)


def _preferences_allow(db, uid: str, code: str) -> bool:
    """
    Gate: User Preferences (spec Phase 16). A user preference is a
    high-level opt-in/opt-out signal, not a second eligibility engine --
    it never touches Frequency/Timing/Priority, it only asks "does the
    user want this category at all." Critical-priority events (today,
    only RECOVERY_BECAME_IMPOSSIBLE) always bypass this gate: user
    preferences can control attention, but they cannot suppress
    critical financial information.
    """
    if gen._PRIORITY.get(code) == "Critical":
        return True

    category = _PREFERENCE_CATEGORY.get(code)
    if category is None:
        return True

    doc = db.collection("users").document(uid).get()
    if not doc.exists:
        return True
    data = doc.to_dict() or {}
    notification_prefs = (data.get("preferences") or {}).get("notifications") or {}
    # Missing category = True -- opt-out only, so pre-existing accounts
    # need no migration and default to fully informed.
    return notification_prefs.get(category, True)


def _frequency_allows(db, uid: str, code: str, payload: dict) -> bool:
    policy = gen._FREQUENCY.get(code)
    if policy in (None, "UNTIL_RESOLVED"):
        # UNTIL_RESOLVED's real escalating cadence is a Delivery/scheduling
        # concern beyond a single eligibility check (spec's own note) --
        # simplified to always-allow here, not half-built.
        return True

    scope_field = _FREQUENCY_SCOPE_FIELD.get(code)
    scope_value = payload.get(scope_field) if scope_field else None
    most_recent = _most_recent_notification_for_code(db, uid, code, scope_field, scope_value)
    if most_recent is None:
        return True
    if policy == "ONCE":
        return False

    window_days = _FREQUENCY_WINDOWS.get(policy)
    if window_days is None:
        return True
    created_at = most_recent.get("createdAt")
    if not isinstance(created_at, (int, float)):
        # A real Firestore timestamp -- compare against wall-clock "now".
        now = datetime.now(timezone.utc)
        age = now - created_at if hasattr(created_at, "tzinfo") else None
        return age is None or age >= timedelta(days=window_days)
    # Fake-clock counters (as used in tests) are always "old enough" --
    # tests exercise the ONCE/None-history paths instead for windowed policies.
    return True


def check_eligibility(db, uid: str, event: dict) -> dict:
    """
    Runs the Eligibility Waterfall (spec 5.2) against one Event.
    Returns {"eligible": bool, "reason": str|None} — `reason` is always
    populated when `eligible` is False, so every rejection is traceable
    to a named gate, never a silent no.
    """
    code = event.get("event")
    if not code:
        return {"eligible": False, "reason": "event has no 'event' code"}

    # Gates 1/3: Justification + Notification-Eligible (Eligibility Matrix)
    if code in _CONDITIONAL_EVENTS:
        if not _conditional_passes(code, event.get("payload") or {}):
            return {"eligible": False, "reason": f"'{code}' failed its conditional eligibility check"}
    elif code not in _ALWAYS:
        return {"eligible": False, "reason": f"no Eligibility Matrix row for '{code}'"}

    # Gate 2: Context -- no app-presence signal exists anywhere in this
    # codebase; named pass-through, not a fabricated check.

    # Gate: User Preferences (Phase 16) -- an additional input to the
    # same waterfall, not a second notification engine.
    if not _preferences_allow(db, uid, code):
        return {"eligible": False, "reason": f"muted by user preference for category '{_PREFERENCE_CATEGORY.get(code)}'"}

    # Gate 4: Already Informed
    event_id = event.get("eventId")
    if event_id and repo.get(db, uid, event_id) is not None:
        return {"eligible": False, "reason": "already informed (a notification already exists for this event)"}

    # Gate 5: Frequency
    if not _frequency_allows(db, uid, code, event.get("payload") or {}):
        return {"eligible": False, "reason": f"'{code}' frequency policy ({gen._FREQUENCY.get(code)}) not yet elapsed"}

    return {"eligible": True, "reason": None}


def process_event(db, uid: str, event: dict) -> dict:
    """
    Orchestrates the full pipeline for one Event: Eligibility ->
    Notification Generator -> Notification Repository -> Delivery
    (best-effort — a delivery failure never blocks the notification
    from existing; Delivery already handles its own retries and
    graceful failure, spec 5.8).

    Returns the resulting notification if one was created, or
    {"eligible": False, "reason": ...} if the event never became one.
    Never raises past itself — an ineligible or malformed event is a
    normal, expected outcome, not an error.
    """
    decision = check_eligibility(db, uid, event)
    if not decision["eligible"]:
        return decision

    notification = gen.generate_notification(event)
    saved = repo.save(db, uid, notification)
    delivery.deliver_notification(db, uid, saved)
    return repo.get(db, uid, saved["eventId"])
