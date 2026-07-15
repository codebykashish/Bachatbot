from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional
from firebase_config import get_firestore
from auth import get_current_user
from utils import serialize_doc, get_current_month_key
from services.goal_service import compute_goal_progress
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
import logging

router = APIRouter()
logger = logging.getLogger(__name__)


# ─── Request Schemas ─────────────────────────────────────────────────────────

class GoalRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=60)
    targetAmount: float = Field(..., gt=0)
    timeframeMonths: int = Field(..., gt=0, le=60)


class GoalUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=60)
    targetAmount: Optional[float] = Field(None, gt=0)
    timeframeMonths: Optional[int] = Field(None, gt=0, le=60)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _with_computed_fields(goal: dict, saved: float) -> dict:
    """
    Adds savedSoFar/percentComplete/remaining/monthlyTarget — all derived
    live, never stored. `saved` comes from compute_goal_progress (the
    unallocated-income pool), not from any stored field.
    """
    target = float(goal.get("targetAmount", 0) or 0)
    months = int(goal.get("timeframeMonths", 1) or 1)
    goal["savedSoFar"] = saved
    goal["percentComplete"] = round(min(100, (saved / target) * 100), 1) if target > 0 else 0
    goal["remaining"] = max(0.0, target - saved)
    goal["monthlyTarget"] = round(target / months, 2) if months > 0 else 0
    goal["status"] = "completed" if saved >= target and target > 0 else goal.get("status", "active")
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
    progress = compute_goal_progress(db, uid, month_key)

    return {
        "success": True,
        "message": f"Goal '{body.name}' created.",
        "data": {"goal": _with_computed_fields(serialize_doc(saved_doc), progress.get(new_ref.id, 0.0))},
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
    progress = compute_goal_progress(db, uid, month_key)

    goals = []
    for doc in docs:
        data = doc.to_dict()
        if data.get("isDeleted", False):
            continue
        data["id"] = doc.id
        saved = progress.get(doc.id, float(data.get("targetAmount", 0) or 0))  # completed goals: full
        if data.get("status") == "completed":
            saved = float(data.get("targetAmount", 0) or 0)
        goals.append(_with_computed_fields(serialize_doc(data), saved))

    return {"success": True, "data": {"goals": goals}}


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

    goal_ref.update(update_payload)
    logger.info(f"[GOALS] uid={uid} updated goal id={goal_id}")

    updated = goal_ref.get().to_dict()
    updated["id"] = goal_id

    month_key = get_current_month_key()
    progress = compute_goal_progress(db, uid, month_key)

    return {
        "success": True,
        "message": "Goal updated.",
        "data": {"goal": _with_computed_fields(serialize_doc(updated), progress.get(goal_id, 0.0))},
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

    return {"success": True, "message": "Goal removed."}
