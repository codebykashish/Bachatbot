"""
behavior_state_repository.py
=============================
Phase 4.5, Step 2 — the BehaviorState Repository. See
backend/FINANCIAL_ENGINE_SPEC.md, Phase 4.5A "Firestore paths — frozen"
and "Behavior State Model," for the contract this file implements.

Pure data access only — no business logic. This module does not decide
what a streak is, when it extends, or when it breaks; it only reads and
writes the two documents Behavior Engine owns. Streak/milestone/recovery
logic belongs in the behavior category modules (4.5.1 onward), never
here.

Public API:

    initialize(db, uid)                    -> None
    load_state(db, uid)                    -> dict
    save_state(db, uid, state)             -> None
    update_state(db, uid, patch)           -> None
    load_history(db, uid)                  -> dict
    append_milestone(db, uid, milestone)   -> None
    append_recovery_attempt(db, uid, attempt) -> None
"""

from google.cloud.firestore_v1 import ArrayUnion

STATE_COLLECTION = "behaviorState"
HISTORY_COLLECTION = "behaviorHistory"
DOC_ID = "current"


def _default_state() -> dict:
    """The frozen default shape of behaviorState/current — spec's
    'Behavior State Model' block, before any behavior has been recorded."""
    return {
        "logging": {
            "currentStreak": 0,
            "bestStreak": 0,
            "streakStartedOn": None,
            "lastLoggedDate": None,
        },
        "spending": {
            "currentHealthyStreak": 0,
            "bestHealthyStreak": 0,
            "currentOverspendingStreak": 0,
            "lastHealthyDate": None,
            "lastEvaluatedDate": None,
        },
        "saving": {
            "currentProtectionStreak": 0,
            "bestProtectionStreak": 0,
            "lastMonthKeyEvaluated": None,
        },
        "recovery": {
            "currentStreak": 0,
            "bestStreak": 0,
            "totalAttempts": 0,
            "totalResolved": 0,
            "totalFailed": 0,
            "openRecoveryStartedOn": None,
            "openRecoveryEverImpossible": False,
        },
    }


def _default_history() -> dict:
    """The frozen default shape of behaviorHistory/current — empty,
    append-only arrays only, per spec's narrowed 'Behavior State Model.'"""
    return {
        "milestones": [],
        "recoveryAttempts": [],
    }


def _state_ref(db, uid: str):
    return (
        db.collection("users").document(uid)
        .collection(STATE_COLLECTION).document(DOC_ID)
    )


def _history_ref(db, uid: str):
    return (
        db.collection("users").document(uid)
        .collection(HISTORY_COLLECTION).document(DOC_ID)
    )


def initialize(db, uid: str) -> None:
    """
    Creates behaviorState/current and behaviorHistory/current with their
    frozen default shapes, only if they don't already exist. Safe to call
    repeatedly — an existing document is never overwritten.
    """
    state_ref = _state_ref(db, uid)
    if not state_ref.get().exists:
        state_ref.set(_default_state())

    history_ref = _history_ref(db, uid)
    if not history_ref.get().exists:
        history_ref.set(_default_history())


def load_state(db, uid: str) -> dict:
    """Returns behaviorState/current, or the frozen default shape if the
    document doesn't exist yet (no write happens — call initialize() for that)."""
    doc = _state_ref(db, uid).get()
    return doc.to_dict() if doc.exists else _default_state()


def save_state(db, uid: str, state: dict) -> None:
    """Overwrites behaviorState/current in place with the given dict."""
    _state_ref(db, uid).set(state)


def update_state(db, uid: str, patch: dict) -> None:
    """
    Merges the given fields into behaviorState/current without touching
    the rest of the document. Keys may be dotted paths (e.g.
    "logging.currentStreak") to update a single nested field.

    Uses DocumentReference.update(), not set(merge=True) — Firestore only
    resolves dotted string keys as nested field paths for update(); passed
    to set(merge=True), a dotted key is stored as one literal field name
    containing dots, which silently fails to touch the intended nested
    field. update() requires the document to already exist, which
    initialize() guarantees before any category module calls this.
    """
    _state_ref(db, uid).update(patch)


def load_history(db, uid: str) -> dict:
    """Returns behaviorHistory/current, or the frozen default shape if the
    document doesn't exist yet (no write happens — call initialize() for that)."""
    doc = _history_ref(db, uid).get()
    return doc.to_dict() if doc.exists else _default_history()


def append_milestone(db, uid: str, milestone: dict) -> None:
    """Appends one { code, unlockedAt } record to behaviorHistory.milestones.
    Append-only, per the frozen Behavior State Model — never rewrites
    or removes an existing entry."""
    _history_ref(db, uid).set(
        {"milestones": ArrayUnion([milestone])}, merge=True
    )


def append_recovery_attempt(db, uid: str, attempt: dict) -> None:
    """Appends one { startedOn, resolvedOn, outcome } record to
    behaviorHistory.recoveryAttempts. Append-only, same reasoning as
    append_milestone()."""
    _history_ref(db, uid).set(
        {"recoveryAttempts": ArrayUnion([attempt])}, merge=True
    )
