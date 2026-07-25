"""
routes/weekly_reflection.py
==============================
The endpoint the UI reads "Your Week in Money" from — the Phase 22E
counterpart to routes/financial_health.py. No calculation happens
here; this is a thin read/generate matching
services/weekly_reflection_service.py's generate_weekly_reflection().
"""

from fastapi import APIRouter, Depends
from auth import get_current_user
from firebase_config import get_firestore
from services.weekly_reflection_service import (
    generate_weekly_reflection,
    most_recent_completed_week,
    WeeklyReflectionError,
)

router = APIRouter()


@router.get("/weekly-reflection")
async def weekly_reflection(current_user: dict = Depends(get_current_user)):
    """
    Returns the most recently completed ISO week's reflection,
    generating and persisting it on first request (idempotent --
    subsequent calls the same week return the already-persisted
    document, never recomputed).

    Returns `{"success": True, "data": null}` rather than an error when
    the account is too new for any completed week to exist yet (the
    Account Existence Boundary, spec Phase 22B) -- an honest "nothing
    to show yet," not a failure.
    """
    uid = current_user["uid"]
    db = get_firestore()

    week_start, week_end = most_recent_completed_week()

    try:
        reflection = generate_weekly_reflection(db, uid, week_start, week_end)
    except WeeklyReflectionError:
        # Account Existence Boundary: account is too new for a completed past week.
        # Fall back to the current (in-progress) week so new accounts still see the card.
        from datetime import date, timedelta
        today = date.today()
        this_monday = today - timedelta(days=today.weekday())
        this_week_end = this_monday + timedelta(days=6)
        try:
            reflection = generate_weekly_reflection(db, uid, this_monday, this_week_end)
        except WeeklyReflectionError:
            return {"success": True, "data": None}

    return {"success": True, "data": reflection}
