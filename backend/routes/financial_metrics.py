"""
routes/financial_metrics.py
=============================
The endpoint the UI reads Metrics Engine values from — the Phase 2
counterpart to routes/financial_summary.py. No calculation happens here;
this is a thin read matching services/metrics_engine.py's get_metrics().

Phase 2.1: returns daysRemaining only. Later phases add fields to
get_metrics() itself, not a new endpoint.
"""

from fastapi import APIRouter, Depends
from auth import get_current_user
from firebase_config import get_firestore
from utils import get_current_month_key
from services.metrics_engine import get_metrics

router = APIRouter()


@router.get("/financial-metrics")
async def financial_metrics(
    monthKey: str = None,
    current_user: dict = Depends(get_current_user),
):
    """
    Returns the current financialMetrics for the calling user/month.
    Phase 2.1: { daysRemaining, metadata }.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = monthKey or get_current_month_key()

    metrics = get_metrics(db, uid, month_key)

    return {
        "success": True,
        "data": metrics,
    }
