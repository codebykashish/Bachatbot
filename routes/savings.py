"""
savings.py
===========
Savings Reserve — the user's explicitly declared monthly protected savings
amount. Separate from category budgets. Goals draw from this reserve.

Endpoints:
  GET  /savings-reserve          → current reserve + impact summary
  POST /savings-reserve          → set / update reserve amount
  POST /savings/contribute       → allocate unused budget to a goal (Path B)
"""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from services.financial_engine import recompute as engine_recompute, RecomputeReason
import logging

router = APIRouter()
logger = logging.getLogger(__name__)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _get_income(user_doc: dict) -> float:
    income_map = user_doc.get("income") or {}
    return (
        float(income_map.get("inHand") or 0)
        + float(income_map.get("inBank") or 0)
        + float(income_map.get("onlineBanking") or 0)
    )


def _get_total_budget_limits(db, uid: str, month_key: str) -> float:
    docs = (
        db.collection("users").document(uid).collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )
    return sum(float(d.to_dict().get("limit") or 0) for d in docs)


def _compute_impact(income: float, new_reserve: float, current_budget_total: float) -> dict:
    """
    Returns how much unallocated budget vs existing category budgets must
    absorb the reserve. Used to warn the user before confirming.
    """
    available_for_budgeting = max(0.0, income - new_reserve)
    shortfall = max(0.0, current_budget_total - available_for_budgeting)
    unallocated = max(0.0, income - current_budget_total)

    # How much of the shortfall can be covered by unallocated budget?
    covered_by_unallocated = min(unallocated, new_reserve)
    must_trim_from_budgets = max(0.0, new_reserve - covered_by_unallocated)

    return {
        "availableForBudgeting": round(available_for_budgeting, 2),
        "currentBudgetTotal": round(current_budget_total, 2),
        "unallocated": round(unallocated, 2),
        "shortfall": round(shortfall, 2),
        "mustTrimFromBudgets": round(must_trim_from_budgets, 2),
        "requiresBudgetAdjustment": must_trim_from_budgets > 0.5,
    }


# ─── Request Schemas ───────────────────────────────────────────────────────────

class SavingsReserveRequest(BaseModel):
    amount: float = Field(..., ge=0, description="Monthly reserve in Rs (0 = no reserve)")
    percentage: Optional[float] = Field(None, ge=0, le=100, description="% of income (informational only)")


class ContributeRequest(BaseModel):
    goalId: str
    amount: float = Field(..., gt=0)
    source: str = Field("unused_budget", description="'unused_budget' | 'reserve'")


# ═══════════════════════════════════════════════════════════════════════════════
# GET /savings-reserve
# ═══════════════════════════════════════════════════════════════════════════════

@router.get("/savings-reserve")
async def get_savings_reserve(current_user: dict = Depends(get_current_user)):
    """
    Return the current savings reserve, impact summary, and goal allocation
    status for the current month.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = get_current_month_key()

    user_doc = (db.collection("users").document(uid).get().to_dict()) or {}
    income = _get_income(user_doc)
    reserve_map = user_doc.get("savingsReserve") or {}
    reserve_amount = float(reserve_map.get("amount") or 0)
    reserve_pct = float(reserve_map.get("percentage") or 0)

    total_budgets = _get_total_budget_limits(db, uid, month_key)
    impact = _compute_impact(income, reserve_amount, total_budgets)

    # Goal commitment summary from active goals
    from services.goal_service import get_active_goals
    active_goals = get_active_goals(db, uid)
    total_monthly_commitments = sum(
        float(g.get("targetAmount") or 0) / max(int(g.get("timeframeMonths") or 1), 1)
        for g in active_goals
    )
    reserve_shortfall = max(0.0, total_monthly_commitments - reserve_amount)
    general_savings = max(0.0, reserve_amount - min(total_monthly_commitments, reserve_amount))

    return {
        "success": True,
        "data": {
            "reserveAmount": reserve_amount,
            "reservePercentage": reserve_pct,
            "income": income,
            "isSet": reserve_amount > 0,
            "availableForBudgeting": impact["availableForBudgeting"],
            "totalGoalCommitments": round(total_monthly_commitments, 2),
            "generalSavings": round(general_savings, 2),
            "reserveShortfall": round(reserve_shortfall, 2),
            "budgetImpact": impact,
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# POST /savings-reserve
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/savings-reserve")
async def set_savings_reserve(
    body: SavingsReserveRequest,
    current_user: dict = Depends(get_current_user),
):
    """
    Set or update the monthly savings reserve. Returns budget impact so the
    frontend can confirm before applying when category budgets need trimming.
    The reserve is always written — the frontend decides whether to show the
    impact modal first.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = get_current_month_key()

    user_doc = (db.collection("users").document(uid).get().to_dict()) or {}
    income = _get_income(user_doc)

    if body.amount > income:
        raise HTTPException(
            status_code=400,
            detail={"success": False, "error": {
                "code": "RESERVE_EXCEEDS_INCOME",
                "message": f"Reserve Rs {body.amount:.0f} exceeds total income Rs {income:.0f}.",
            }},
        )

    total_budgets = _get_total_budget_limits(db, uid, month_key)
    impact = _compute_impact(income, body.amount, total_budgets)

    # Derive percentage from income if not provided
    pct = body.percentage if body.percentage is not None else (
        round((body.amount / income * 100), 1) if income > 0 else 0.0
    )

    # Write reserve to user document
    db.collection("users").document(uid).update({
        "savingsReserve.amount": body.amount,
        "savingsReserve.percentage": pct,
        "savingsReserve.updatedAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    })
    logger.info(f"[SAVINGS] uid={uid} reserve set to Rs {body.amount} ({pct}%)")

    # Create alert
    try:
        msg = (
            f"Savings reserve set to Rs {int(body.amount)}/month ({pct}% of income)."
            if body.amount > 0
            else "Savings reserve removed."
        )
        db.collection("users").document(uid).collection("alerts").document().set({
            "type": "savings_reserve_set",
            "message": msg,
            "category": None,
            "severity": "low",
            "isRead": False,
            "isDeleted": False,
            "monthKey": month_key,
            "relatedTransactionId": None,
            "createdAt": SERVER_TIMESTAMP,
        })
    except Exception as _ae:
        logger.warning(f"[SAVINGS] alert creation failed: {_ae}")

    # Recompute financial engine
    try:
        engine_recompute(db, uid, month_key, reason=RecomputeReason.SAVINGS_RESERVE_UPDATED)
    except Exception as _re:
        logger.warning(f"[SAVINGS] engine recompute failed (non-fatal): {_re}")

    return {
        "success": True,
        "message": f"Savings reserve updated to Rs {int(body.amount)}/month.",
        "data": {
            "reserveAmount": body.amount,
            "reservePercentage": pct,
            "availableForBudgeting": impact["availableForBudgeting"],
            "budgetImpact": impact,
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# POST /savings/contribute  (Path B — unused budget → goal)
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/savings/contribute")
async def contribute_to_goal(
    body: ContributeRequest,
    current_user: dict = Depends(get_current_user),
):
    """
    Allocate unused budget or extra reserve toward a specific goal.
    Does not change any income or budget document. Writes a contribution
    record that the engine reads when computing goal progress.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = get_current_month_key()

    # Validate goal exists
    goal_ref = db.collection("users").document(uid).collection("goals").document(body.goalId)
    goal_doc = goal_ref.get()
    if not goal_doc.exists or goal_doc.to_dict().get("isDeleted"):
        raise HTTPException(
            status_code=404,
            detail={"success": False, "error": {"code": "GOAL_NOT_FOUND", "message": "Goal not found."}},
        )

    goal_data = goal_doc.to_dict()
    goal_name = goal_data.get("name", "Goal")

    # Write to savingsContributions subcollection (upsert by month)
    contrib_ref = (
        db.collection("users").document(uid)
        .collection("savingsContributions").document(month_key)
    )
    contrib_doc = contrib_ref.get()
    existing = contrib_doc.to_dict() if contrib_doc.exists else {}
    goal_allocs = dict(existing.get("goalAllocations") or {})
    goal_allocs[body.goalId] = round(
        float(goal_allocs.get(body.goalId) or 0) + body.amount, 2
    )

    contrib_ref.set({
        "monthKey": month_key,
        "goalAllocations": goal_allocs,
        "source": body.source,
        "updatedAt": SERVER_TIMESTAMP,
    }, merge=True)

    logger.info(f"[SAVINGS] uid={uid} contributed Rs {body.amount} to goal={body.goalId} source={body.source}")

    # Create alert
    try:
        db.collection("users").document(uid).collection("alerts").document().set({
            "type": "goal_contribution",
            "message": f"Rs {int(body.amount)} contributed to {goal_name} goal.",
            "category": None,
            "severity": "low",
            "isRead": False,
            "isDeleted": False,
            "monthKey": month_key,
            "relatedTransactionId": None,
            "createdAt": SERVER_TIMESTAMP,
        })
    except Exception as _ae:
        logger.warning(f"[SAVINGS] alert creation failed: {_ae}")

    # Recompute
    try:
        engine_recompute(db, uid, month_key, reason=RecomputeReason.SAVINGS_RESERVE_UPDATED)
    except Exception as _re:
        logger.warning(f"[SAVINGS] engine recompute failed (non-fatal): {_re}")

    return {
        "success": True,
        "message": f"Rs {int(body.amount)} contributed to {goal_name}.",
        "data": {"goalId": body.goalId, "amount": body.amount, "monthKey": month_key},
    }
