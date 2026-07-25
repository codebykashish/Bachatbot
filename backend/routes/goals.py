from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional
from firebase_config import get_firestore
from auth import get_current_user
from utils import serialize_doc, get_current_month_key
from services.financial_engine import recompute as engine_recompute, get_summary, RecomputeReason
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
import logging

router = APIRouter()
logger = logging.getLogger(__name__)


# ─── Request Schemas ─────────────────────────────────────────────────────────

class GoalRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=60)
    targetAmount: float = Field(..., gt=0)
    timeframeMonths: int = Field(..., gt=0, le=60)
    priority: int = Field(1, ge=1, le=99)


class GoalUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=60)
    targetAmount: Optional[float] = Field(None, gt=0)
    timeframeMonths: Optional[int] = Field(None, gt=0, le=60)
    priority: Optional[int] = Field(None, ge=1, le=99)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _merge_engine_fields(goal: dict, summary: dict) -> dict:
    """
    No math happens here — every derived field (savedSoFar, remaining,
    percentComplete, monthlyTarget, status) comes straight from the
    Engine's goalProgress (financial_engine.py's _calculate_goal_impact).
    This function only merges that entry onto the raw serialized doc.

    A completed goal is excluded from the Engine's active-goal set (by
    design — see goal_service.get_active_goals), so it won't have an entry;
    fall back to "fully saved" for a goal already marked completed, or a
    defensive zero-progress default for the rare case of a goal not yet
    reflected in the summary (e.g. a legacy write path that hasn't
    triggered a recompute).
    """
    entry = next((g for g in summary.get("goalProgress", []) if g["id"] == goal["id"]), None)
    if entry is not None:
        goal.update({
            "priority": entry["priority"],
            "savedSoFar": entry["savedSoFar"],
            "remaining": entry["remaining"],
            "percentComplete": entry["percentComplete"],
            "monthlyTarget": entry["monthlyTarget"],
            "status": entry["status"],
        })
        return goal

    target = float(goal.get("targetAmount", 0) or 0)
    months = int(goal.get("timeframeMonths", 1) or 1)
    already_complete = goal.get("status") == "completed"
    saved = target if already_complete else 0.0
    goal.update({
        "priority": int(goal.get("priority") or 1),
        "savedSoFar": saved,
        "remaining": max(0.0, target - saved),
        "percentComplete": 100.0 if already_complete else 0.0,
        "monthlyTarget": round(target / months, 2) if months > 0 else 0,
        "status": goal.get("status", "active"),
    })
    return goal


# ═══════════════════════════════════════════════════════════════════════════════
# POST /goals — create a new goal
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/goals", status_code=201)
async def create_goal(
    body: GoalRequest,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    goals_ref = db.collection("users").document(uid).collection("goals")
    new_ref = goals_ref.document()
    goal_data = {
        "name": body.name,
        "targetAmount": body.targetAmount,
        "timeframeMonths": body.timeframeMonths,
        "priority": body.priority,
        "status": "active",
        "isDeleted": False,
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    }
    new_ref.set(goal_data)
    logger.info(f"[GOALS] uid={uid} created goal '{body.name}' id={new_ref.id}")

    saved_doc = new_ref.get().to_dict()
    saved_doc["id"] = new_ref.id

    month_key = get_current_month_key()
    summary = engine_recompute(db, uid, month_key, reason=RecomputeReason.GOAL_CREATED)

    return {
        "success": True,
        "message": f"Goal '{body.name}' created.",
        "data": {"goal": _merge_engine_fields(serialize_doc(saved_doc), summary)},
    }


# ═══════════════════════════════════════════════════════════════════════════════
# GET /goals — list all active (non-deleted) goals
# ═══════════════════════════════════════════════════════════════════════════════

@router.get("/goals")
async def get_goals(
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    docs = (
        db.collection("users").document(uid).collection("goals")
        .order_by("createdAt", direction="DESCENDING")
        .stream()
    )

    month_key = get_current_month_key()
    summary = get_summary(db, uid, month_key)  # read-only, self-heals if missing — no recompute here

    goals = []
    for doc in docs:
        data = doc.to_dict()
        if data.get("isDeleted", False):
            continue
        data["id"] = doc.id
        goals.append(_merge_engine_fields(serialize_doc(data), summary))

    return {"success": True, "data": {"goals": goals, "availableToSave": summary["savingsPool"]}}


# ═══════════════════════════════════════════════════════════════════════════════
# PATCH /goals/{goalId} — edit a goal
# ═══════════════════════════════════════════════════════════════════════════════

@router.patch("/goals/{goal_id}")
async def update_goal(
    goal_id: str,
    body: GoalUpdateRequest,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    goal_ref = db.collection("users").document(uid).collection("goals").document(goal_id)
    doc = goal_ref.get()
    if not doc.exists or doc.to_dict().get("isDeleted"):
        raise HTTPException(
            status_code=404,
            detail={"success": False, "error": {"code": "GOAL_NOT_FOUND", "message": "Goal not found."}},
        )

    update_payload = {"updatedAt": SERVER_TIMESTAMP}
    if body.name is not None:
        update_payload["name"] = body.name
    if body.targetAmount is not None:
        update_payload["targetAmount"] = body.targetAmount
    if body.timeframeMonths is not None:
        update_payload["timeframeMonths"] = body.timeframeMonths
    if body.priority is not None:
        update_payload["priority"] = body.priority

    goal_ref.update(update_payload)
    logger.info(f"[GOALS] uid={uid} updated goal id={goal_id}")

    updated = goal_ref.get().to_dict()
    updated["id"] = goal_id

    month_key = get_current_month_key()
    summary = engine_recompute(db, uid, month_key, reason=RecomputeReason.GOAL_UPDATED)

    return {
        "success": True,
        "message": "Goal updated.",
        "data": {"goal": _merge_engine_fields(serialize_doc(updated), summary)},
    }


# ═══════════════════════════════════════════════════════════════════════════════
# DELETE /goals/{goalId}
# ═══════════════════════════════════════════════════════════════════════════════

@router.delete("/goals/{goal_id}")
async def delete_goal(
    goal_id: str,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    goal_ref = db.collection("users").document(uid).collection("goals").document(goal_id)
    doc = goal_ref.get()
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={"success": False, "error": {"code": "GOAL_NOT_FOUND", "message": "Goal not found."}},
        )

    goal_ref.update({"isDeleted": True, "updatedAt": SERVER_TIMESTAMP})
    logger.info(f"[GOALS] uid={uid} deleted goal id={goal_id}")

    try:
        engine_recompute(db, uid, get_current_month_key(), reason=RecomputeReason.GOAL_DELETED)
    except Exception as _re:
        logger.warning(f"[GOALS] Engine recompute failed (non-fatal): {_re}")

    return {"success": True, "message": "Goal removed."}
