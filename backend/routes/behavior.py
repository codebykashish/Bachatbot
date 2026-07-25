"""
routes/behavior.py
=====================
The endpoint the UI reads Behavior Engine values from — the Phase 13.2
counterpart to routes/financial_health.py. No calculation happens here;
this is a thin read matching services/behavior_engine.py's
compute_behavior_summary() and services/behavior_state_repository.py's
load_state()/load_history().

The milestone catalog below (title/description per code) is UI-facing
copy, not domain logic — it lives here rather than in behavior_engine.py
so the engine stays free of presentation strings, the same separation
notification_generator.py's own Template Matrix already draws between
"what happened" and "how it's worded."
"""

from fastapi import APIRouter, Depends
from auth import get_current_user
from firebase_config import get_firestore
from services import behavior_state_repository as repo
from services.behavior_engine import compute_behavior_summary

router = APIRouter()

_MILESTONE_CATALOG = {
    "FIRST_EXPENSE_LOGGED": {
        "title": "First expense logged!",
        "description": "You've started your budgeting journey",
    },
    "LOGGING_STREAK_30_DAYS": {
        "title": "30-day logging streak!",
        "description": "You've logged your expenses for 30 days straight",
    },
    "FIRST_HEALTHY_WEEK": {
        "title": "First Healthy Week unlocked!",
        "description": "You kept your spending healthy for 7 days straight",
    },
    "FIRST_GOAL_COMPLETED": {
        "title": "First goal completed!",
        "description": "You reached your first savings goal",
    },
}


def _milestones_with_lock_state(history: dict) -> list:
    unlocked_by_code = {m["code"]: m for m in history["milestones"]}
    return [
        {
            "code": code,
            "title": catalog_entry["title"],
            "description": catalog_entry["description"],
            "unlocked": code in unlocked_by_code,
            "unlockedAt": unlocked_by_code.get(code, {}).get("unlockedAt"),
        }
        for code, catalog_entry in _MILESTONE_CATALOG.items()
    ]


@router.get("/behavior")
async def behavior(current_user: dict = Depends(get_current_user)):
    """
    Returns the current Behavior Summary, raw streak/recovery state, and
    every known milestone (locked or unlocked):
    { summary, state, milestones }.
    """
    uid = current_user["uid"]
    db = get_firestore()

    summary = compute_behavior_summary(db, uid)
    state = repo.load_state(db, uid)
    history = repo.load_history(db, uid)

    return {
        "success": True,
        "data": {
            "summary": summary,
            "state": state,
            "milestones": _milestones_with_lock_state(history),
        },
    }
