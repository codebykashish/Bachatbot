"""
routes/financial_summary.py
=============================
The one endpoint the UI is allowed to read calculated financial values
from. Phase 1.9 prerequisite: every screen currently computes its own
numbers from raw Firestore data (income - spent, budget.limit -
budget.spent, goal.target - goal.saved, ...). This endpoint is what lets
Flutter stop doing that — it returns exactly what financial_engine.py's
get_summary() already computes, unmodified, so a screen can display
`summary['remainingBudget']` instead of recomputing it.

No new calculation happens here. This route is a thin read, matching the
Engine's public API (spec Section 0) — getSummary(userId, monthKey).
"""

from fastapi import APIRouter, Depends
from auth import get_current_user
from firebase_config import get_firestore
from utils import get_current_month_key, serialize_doc
from services.financial_engine import get_summary

router = APIRouter()


@router.get("/financial-summary")
async def financial_summary(
    monthKey: str = None,
    current_user: dict = Depends(get_current_user),
):
    """
    Returns the current financialSummary for the calling user/month —
    remainingBudget, categoryRemaining, savingsPool, goalProgress,
    income, totalSpent, metadata. Self-heals (triggers a recompute) if no
    summary exists yet for this month.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = monthKey or get_current_month_key()

    summary = get_summary(db, uid, month_key)

    return {
        "success": True,
        "data": serialize_doc(summary),
    }
