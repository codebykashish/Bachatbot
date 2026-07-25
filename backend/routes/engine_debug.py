"""
routes/engine_debug.py
=======================
Developer-only "Engine Health Dashboard" — exposes the Financial Engine's
own recompute metadata (recomputeId, reason, durationMs, decisionLog) for
the calling user's current summary. Not a financial calculation itself —
this is purely a debugging aid for Phase 1.5 route migration, so a
developer can confirm a route actually triggered a recompute (and what the
Engine decided) without opening Firestore by hand.

Only ever reads the calling user's own financialSummary — no cross-user
data exposed, so this is safe to leave mounted, but the frontend has no
reason to call it; it's for manual/dev inspection only.
"""

from fastapi import APIRouter, Depends
from auth import get_current_user
from firebase_config import get_firestore
from utils import get_current_month_key
from services.financial_engine import get_summary

router = APIRouter()


@router.get("/debug/engine-health")
async def engine_health(
    monthKey: str = None,
    current_user: dict = Depends(get_current_user),
):
    """Last recompute's metadata for the current user/month — dev inspection only."""
    uid = current_user["uid"]
    db = get_firestore()
    month_key = monthKey or get_current_month_key()

    summary = get_summary(db, uid, month_key)
    metadata = summary.get("metadata", {})

    return {
        "success": True,
        "data": {
            "monthKey": month_key,
            "recomputeId": metadata.get("recomputeId"),
            "reason": metadata.get("reason"),
            "durationMs": metadata.get("durationMs"),
            "engineVersion": metadata.get("engineVersion"),
            "summaryVersion": metadata.get("version"),
            "recomputedAt": summary.get("lastUpdated"),
            "decisionLog": metadata.get("decisionLog", []),
            "status": "success",
        },
    }
