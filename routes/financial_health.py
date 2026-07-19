"""
routes/financial_health.py
=============================
The endpoint the UI reads Health Engine values from — the Phase
3.1/3.2/3.3 counterpart to routes/financial_summary.py and
routes/financial_metrics.py. No calculation happens here; this is a
thin read matching services/health_engine.py's compute_overall_health(),
compute_category_health(), and compute_risk_flags().
"""

from fastapi import APIRouter, Depends
from auth import get_current_user
from firebase_config import get_firestore
from utils import get_current_month_key
from services.health_engine import (
    compute_overall_health,
    compute_category_health,
    compute_risk_flags,
)

router = APIRouter()


@router.get("/financial-health")
async def financial_health(
    monthKey: str = None,
    current_user: dict = Depends(get_current_user),
):
    """
    Returns the current Overall Health, Category Health, and Risk Flags
    for the calling user/month:
    { overallHealth, decisionTrace, categoryHealth, riskFlags, metadata }.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = monthKey or get_current_month_key()

    overall = compute_overall_health(db, uid, month_key)
    by_category = compute_category_health(db, uid, month_key)
    risks = compute_risk_flags(db, uid, month_key)

    return {
        "success": True,
        "data": {
            "overallHealth": overall["overallHealth"],
            "decisionTrace": overall["decisionTrace"],
            "categoryHealth": by_category["categoryHealth"],
            "riskFlags": risks["riskFlags"],
            "metadata": overall["metadata"],
        },
    }
