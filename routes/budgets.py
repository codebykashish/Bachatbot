from fastapi import APIRouter, Depends, HTTPException, Query, Body
from pydantic import BaseModel, Field
from typing import Optional
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key, sum_category_expense
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

router = APIRouter()


# ─── Request Schemas ─────────────────────────────────────────────────────────

class BudgetRequest(BaseModel):
    category: str = Field(..., min_length=1, description="Expense category (e.g. Food)")
    limit: float = Field(..., gt=0, description="Monthly spending limit in NPR")
    monthKey: Optional[str] = Field(
        None,
        description="Target month in YYYY-MM format. Defaults to current month.",
    )
    alertThreshold: Optional[int] = Field(
        80,
        description="Alert threshold percentage (0-100).",
    )


# ─── POST /budgets ────────────────────────────────────────────────────────────

@router.post("/budgets", status_code=201)
async def create_or_update_budget(
    body: BudgetRequest,
    current_user: dict = Depends(get_current_user),
):
    """
    Creates or updates a monthly budget for a given category.

    - If a budget for this category + monthKey already exists → updates the limit.
    - If it is a brand-new budget → initialises spent = 0.
    - spent is never reset when updating an existing budget.
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = body.monthKey or get_current_month_key()
    threshold = body.alertThreshold if body.alertThreshold is not None else 80
    print(f"[BUDGET] uid={uid} category={body.category} limit={body.limit} monthKey={month_key}")

    # ── Spent-floor validation ────────────────────────────────────────────
    actual_spent = sum_category_expense(db, uid, body.category, month_key)
    if body.limit < actual_spent:
        print(
            f"[BUDGET] REJECTED: {body.category} limit Rs {body.limit} "
            f"< already spent Rs {actual_spent}"
        )
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "BUDGET_BELOW_SPENT",
                    "message": (
                        f"Cannot set {body.category} budget to Rs {int(body.limit)}. "
                        f"You have already spent Rs {int(actual_spent)} this month. "
                        f"Budget must be at least Rs {int(actual_spent)}."
                    ),
                    "currentSpent": actual_spent,
                },
            },
        )

    budgets_ref = (
        db.collection("users")
        .document(uid)
        .collection("budgets")
    )

    # Check for an existing budget for this category + month
    existing_query = (
        budgets_ref
        .where("category", "==", body.category)
        .where("monthKey", "==", month_key)
        .limit(1)
        .stream()
    )
    existing_docs = list(existing_query)

    if existing_docs:
        # Update limit only; preserve current spent value
        doc_ref = existing_docs[0].reference
        doc_ref.update({
            "limit": body.limit,
            "alertThreshold": threshold,
            "updatedAt": SERVER_TIMESTAMP,
        })
        updated = doc_ref.get().to_dict()
        spent = updated.get("spent", 0.0)
        percent_used = round((spent / body.limit) * 100, 2) if body.limit > 0 else 0.0

        print(f"[BUDGET] Updated existing budget id={doc_ref.id}, kept spent={spent}")

        return {
            "success": True,
            "message": f"Budget for '{body.category}' updated.",
            "data": {
                "id": doc_ref.id,
                "category": body.category,
                "limit": body.limit,
                "spent": spent,
                "remaining": max(0.0, body.limit - spent),
                "percentUsed": percent_used,
                "alertThreshold": threshold,
                "monthKey": month_key,
            },
        }

    # Create new budget document
    new_ref = budgets_ref.document()
    budget_data = {
        "category": body.category,
        "limit": body.limit,
        "spent": 0.0,
        "alertThreshold": threshold,
        "monthKey": month_key,
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    }
    new_ref.set(budget_data)

    print(f"[BUDGET] Created new budget id={new_ref.id}")

    return {
        "success": True,
        "message": f"Budget for '{body.category}' created.",
        "data": {
            "id": new_ref.id,
            "category": body.category,
            "limit": body.limit,
            "spent": 0.0,
            "remaining": body.limit,
            "percentUsed": 0.0,
            "alertThreshold": threshold,
            "monthKey": month_key,
        },
    }


# ─── GET /budgets ─────────────────────────────────────────────────────────────

@router.get("/budgets")
async def get_budgets(
    monthKey: Optional[str] = Query(None, description="YYYY-MM. Defaults to current month."),
    current_user: dict = Depends(get_current_user),
):
    """Returns all budgets for the given month with percentUsed calculated."""
    uid = current_user["uid"]
    db = get_firestore()

    month_key = monthKey or get_current_month_key()
    print(f"[BUDGET] uid={uid} list monthKey={month_key}")

    budgets_ref = (
        db.collection("users")
        .document(uid)
        .collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )

    budgets = []
    for doc in budgets_ref:
        data = doc.to_dict()
        limit_val = data.get("limit", 0.0)
        spent = data.get("spent", 0.0)
        percent_used = round((spent / limit_val) * 100, 2) if limit_val > 0 else 0.0

        budgets.append({
            "id": doc.id,
            "category": data.get("category"),
            "limit": limit_val,
            "spent": spent,
            "remaining": max(0.0, limit_val - spent),
            "percentUsed": percent_used,
            "alertThreshold": data.get("alertThreshold", 80),
            "monthKey": data.get("monthKey"),
        })

    # Also fetch confirmation status
    from services.budget_service import get_budget_month_meta
    meta = get_budget_month_meta(db, uid, month_key)

    return {
        "success": True,
        "data": {
            "budgets": budgets,
            "monthKey": month_key,
            "budgetConfirmedForMonth": meta.get("budgetConfirmedForMonth", False),
            "count": len(budgets),
        },
    }


@router.post("/budgets/confirm")
async def confirm_monthly_budget(
    monthKey: Optional[str] = Body(None, embed=True),
    current_user: dict = Depends(get_current_user),
):
    """
    Mark the budgets for a given month as 'confirmed' by the user.
    This stops the pre-month-end reminders for that month.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = monthKey or get_current_month_key()

    from services.budget_service import set_budget_confirmed_for_month
    set_budget_confirmed_for_month(db, uid, month_key, confirmed=True)

    return {
        "success": True,
        "message": f"Budgets for {month_key} confirmed."
    }