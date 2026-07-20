"""
diff_generator.py
====================
Diff Generator — Step 10. See backend/FINANCIAL_ENGINE_SPEC.md, "Step
10.0 — Diff Generator Philosophy" through "Step 10.3 — Generator
Pipeline," for the full contract this file implements.

This module owns comparison logic only. It never recomputes a domain
engine (Rule 1), never emits a state as if it were an event (Rule 2),
never emits for an unchanged field (Rule 3), never lets one transition
produce more than one event (Rule 4/Rule 9/Rule 11), never guesses at
an unmapped transition (Rule 10), and never decides notification
importance or ordering (Rule 5, and the no-ordering rule).

Public API:
    generate_events(uid, yesterday_snapshot, today_snapshot, milestones_today=None) -> list[dict]
"""

DIFF_VERSION = "1.0.0"
_SUPPORTED_SNAPSHOT_VERSIONS = {"1.0.0"}

_HEALTH_ORDER = {"green": 0, "amber": 1, "red": 2}


def _get(snapshot, path):
    value = snapshot
    for key in path:
        if value is None:
            return None
        value = value.get(key)
    return value


def _worse(a, b):
    return a in _HEALTH_ORDER and b in _HEALTH_ORDER and _HEALTH_ORDER[b] > _HEALTH_ORDER[a]


def _better(a, b):
    return a in _HEALTH_ORDER and b in _HEALTH_ORDER and _HEALTH_ORDER[b] < _HEALTH_ORDER[a]


def _increased(a, b):
    return a is not None and b is not None and b > a


def _broke_to_zero(a, b):
    return a is not None and a > 0 and b == 0


def _flipped_true(a, b):
    return a is False and b is True


def _flipped_false(a, b):
    return a is True and b is False


def _any_change(a, b):
    return a != b


# Frozen Diff Matrix (spec Step 10.2). The generator iterates over this
# table, never over the snapshot's own fields (Rule 12) -- adding an
# event is adding one row here, never rewriting comparison logic.
# CATEGORY_BECAME_EXHAUSTED and MILESTONE_UNLOCKED are handled
# separately below since they each iterate over a collection, not a
# single scalar field.
_DIFF_MATRIX = [
    {"id": "recovery_started", "field": ("metrics", "recoveryPlanPresent"),
     "transition": _flipped_true, "event": "RECOVERY_STARTED"},
    {"id": "recovery_became_impossible", "field": ("metrics", "recoveryPossible"),
     "transition": _flipped_false, "event": "RECOVERY_BECAME_IMPOSSIBLE"},
    {"id": "health_worsened", "field": ("health", "overallHealthStatus"),
     "transition": _worse, "event": "HEALTH_WORSENED"},
    {"id": "health_improved", "field": ("health", "overallHealthStatus"),
     "transition": _better, "event": "HEALTH_IMPROVED"},
    {"id": "recommendation_changed", "field": ("recommendation", "primaryRecommendationCode"),
     "transition": _any_change, "event": "PRIMARY_RECOMMENDATION_CHANGED"},
    {"id": "logging_streak_extended", "field": ("behavior", "state", "logging", "currentStreak"),
     "transition": _increased, "event": "LOGGING_STREAK_EXTENDED"},
    {"id": "logging_streak_broken", "field": ("behavior", "state", "logging", "currentStreak"),
     "transition": _broke_to_zero, "event": "LOGGING_STREAK_BROKEN"},
    {"id": "healthy_streak_extended", "field": ("behavior", "state", "spending", "currentHealthyStreak"),
     "transition": _increased, "event": "HEALTHY_STREAK_EXTENDED"},
    {"id": "healthy_streak_broken", "field": ("behavior", "state", "spending", "currentHealthyStreak"),
     "transition": _broke_to_zero, "event": "HEALTHY_STREAK_BROKEN"},
    {"id": "saving_streak_extended", "field": ("behavior", "state", "saving", "currentProtectionStreak"),
     "transition": _increased, "event": "SAVING_STREAK_EXTENDED"},
    {"id": "saving_streak_broken", "field": ("behavior", "state", "saving", "currentProtectionStreak"),
     "transition": _broke_to_zero, "event": "SAVING_STREAK_BROKEN"},
    {"id": "recovery_completed", "field": ("behavior", "state", "recovery", "totalResolved"),
     "transition": _increased, "event": "RECOVERY_COMPLETED"},
    {"id": "recovery_failed", "field": ("behavior", "state", "recovery", "totalFailed"),
     "transition": _increased, "event": "RECOVERY_FAILED"},
]


def _load_inputs(yesterday_snapshot, today_snapshot, milestones_today):
    """Stage 1 -- exactly three things, nothing else."""
    return {
        "yesterday": yesterday_snapshot,
        "today": today_snapshot,
        "milestones": milestones_today or [],
    }


def _validate_inputs(inputs):
    """Stage 2 -- infrastructure concerns only, never domain logic.
    See spec's "Validation scope, frozen" for why this is narrower than
    "consecutive dates": only strict ordering is enforced, not adjacency."""
    yesterday, today = inputs["yesterday"], inputs["today"]
    if yesterday is None or today is None:
        raise ValueError("generate_events requires both snapshots to exist")
    if today.get("snapshotVersion") not in _SUPPORTED_SNAPSHOT_VERSIONS:
        raise ValueError(f"Unsupported snapshotVersion: {today.get('snapshotVersion')}")
    if today.get("snapshotDate") <= yesterday.get("snapshotDate"):
        raise ValueError(
            "today_snapshot must be strictly after yesterday_snapshot "
            f"(got {yesterday.get('snapshotDate')} -> {today.get('snapshotDate')})"
        )


def _compare_fields(inputs):
    """Stage 3 -- (row, yesterday_value, today_value) for every Diff
    Matrix row. Differences only -- no events yet."""
    yesterday, today = inputs["yesterday"], inputs["today"]
    return [
        (row, _get(yesterday, row["field"]), _get(today, row["field"]))
        for row in _DIFF_MATRIX
    ]


def _match_matrix_rows(diffs):
    """Stage 4 -- the heart. Keep only the transitions the matrix
    actually claims; everything else is silently ignored (Rule 10)."""
    return [(row, y, t) for row, y, t in diffs if row["transition"](y, t)]


def _category_health_events(inputs):
    """CATEGORY_BECAME_EXHAUSTED -- one event per category newly at
    red, kept separate from the flat matrix above since it iterates a
    dict of categories, not a single scalar field."""
    yesterday = _get(inputs["yesterday"], ("health", "categoryHealth")) or {}
    today = _get(inputs["today"], ("health", "categoryHealth")) or {}
    return [
        {"diffRuleId": "category_became_exhausted", "event": "CATEGORY_BECAME_EXHAUSTED",
         "payload": {"category": category}}
        for category, status in today.items()
        if status == "red" and yesterday.get(category) != "red"
    ]


def _milestone_events(inputs):
    """MILESTONE_UNLOCKED -- the one Producer: Milestone History row
    (spec Step 9.1's Option C). Reads behaviorHistory.milestones[],
    already filtered to today's date by the caller -- never the
    snapshot, and never Firestore directly."""
    today_date = inputs["today"].get("snapshotDate")
    return [
        {"diffRuleId": "milestone_unlocked", "event": "MILESTONE_UNLOCKED",
         "payload": {"code": milestone.get("code")}}
        for milestone in inputs["milestones"]
        if milestone.get("unlockedAt") == today_date
    ]


def _build_events(matched, inputs):
    """Stage 5 -- structured events only. No wording, no priority, no
    cooldowns -- those belong to Notification Engine (Phase 5)."""
    events = [
        {"diffRuleId": row["id"], "event": row["event"], "payload": {"from": y, "to": t}}
        for row, y, t in matched
    ]
    events.extend(_category_health_events(inputs))
    events.extend(_milestone_events(inputs))
    return events


def _assign_ids(events, uid, snapshot_date):
    """
    Stage 6 -- deterministic eventId per Phase 4.5A's idempotency
    guarantee: (uid, snapshotDate, diffRuleId), same every run.

    Refinement found during implementation: diffRuleId alone collides
    for the two rows that can fire more than once per day
    (CATEGORY_BECAME_EXHAUSTED, one per category; MILESTONE_UNLOCKED,
    one per milestone) -- both get a fourth component appended
    (category name / milestone code) to stay unique. Every other row
    is a single scalar field, where diffRuleId alone is already unique.
    """
    for event in events:
        distinguisher = event["payload"].get("category") or event["payload"].get("code")
        event["eventId"] = (
            f"{uid}:{snapshot_date}:{event['diffRuleId']}"
            + (f":{distinguisher}" if distinguisher else "")
        )
    return events


def generate_events(uid: str, yesterday_snapshot: dict, today_snapshot: dict, milestones_today: list = None) -> list:
    """
    Given two snapshots and the frozen Diff Matrix (spec Step 10.2),
    returns which events should be produced. Never recomputes a domain
    engine. Returns events in Diff Matrix row order, exactly as frozen
    (no sorting, no priority) -- ordering is Notification Engine's job,
    not this function's.

    `milestones_today` is behaviorHistory.milestones[] already filtered
    to today's date by the caller -- this function never reads
    Firestore itself.
    """
    inputs = _load_inputs(yesterday_snapshot, today_snapshot, milestones_today)
    _validate_inputs(inputs)
    diffs = _compare_fields(inputs)
    matched = _match_matrix_rows(diffs)
    events = _build_events(matched, inputs)
    return _assign_ids(events, uid, today_snapshot["snapshotDate"])
