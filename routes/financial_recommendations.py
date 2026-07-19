"""
routes/financial_recommendations.py
=============================
The endpoint the UI reads Recommendation Engine values from — the
Phase 4 counterpart to routes/financial_health.py. No calculation
happens here; this is a thin read matching
services/recommendation_engine.py's compute_recommendations().
"""

from fastapi import APIRouter, Depends
from auth import get_current_user
from firebase_config import get_firestore
from utils import get_current_month_key
from services.recommendation_engine import compute_recommendations

router = APIRouter()


@router.get("/financial-recommendations")
async def financial_recommendations(
    monthKey: str = None,
    current_user: dict = Depends(get_current_user),
):
    """
    Returns the current best-action recommendation for the calling
    user/month: { primaryRecommendation, alternatives,
    recommendationTrace, metadata }.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = monthKey or get_current_month_key()

    recommendations = compute_recommendations(db, uid, month_key)

    return {
        "success": True,
        "data": recommendations,
    }
