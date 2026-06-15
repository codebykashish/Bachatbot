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

    # Create new budget document — backfill spent from existing transactions
    new_ref = budgets_ref.document()
    budget_data = {
        "category": body.category,
        "limit": body.limit,
        "spent": actual_spent,          # ← use real spend, not 0
        "alertThreshold": threshold,
        "monthKey": month_key,
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    }
    new_ref.set(budget_data)

    percent_used = round((actual_spent / body.limit) * 100, 2) if body.limit > 0 else 0.0
    print(f"[BUDGET] Created new budget id={new_ref.id} backfilled spent={actual_spent}")

    return {
        "success": True,
        "message": f"Budget for '{body.category}' created.",
        "data": {
            "id": new_ref.id,
            "category": body.category,
            "limit": body.limit,
            "spent": actual_spent,
            "remaining": max(0.0, body.limit - actual_spent),
            "percentUsed": percent_used,
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

    # Compute actual spent per category from transactions (single query)
    tx_docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("monthKey", "==", month_key)
        .where("type", "==", "expense")
        .where("status", "==", "confirmed")
        .stream()
    )
    actual_spent_map: dict = {}
    for tx in tx_docs:
        td = tx.to_dict()
        if td.get("isDeleted", False):
            continue
        cat = td.get("category", "")
        actual_spent_map[cat] = actual_spent_map.get(cat, 0.0) + float(td.get("amount", 0.0))

    budgets = []
    for doc in budgets_ref:
        data = doc.to_dict()
        limit_val = data.get("limit", 0.0)
        category = data.get("category")
        # Always use transaction-based spend so category page matches reports
        spent = actual_spent_map.get(category, 0.0)
        percent_used = round((spent / limit_val) * 100, 2) if limit_val > 0 else 0.0

        budgets.append({
            "id": doc.id,
            "category": category,
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


# ─── DELETE /budgets/{category} ──────────────────────────────────────────────

@router.delete("/budgets/{category}")
async def delete_budget(
    category: str,
    monthKey: Optional[str] = Query(None),
    current_user: dict = Depends(get_current_user),
):
    """Delete a budget for a category. Only allowed if spent == 0 for the month."""
    uid = current_user["uid"]
    db = get_firestore()
    month_key = monthKey or get_current_month_key()

    docs = list(
        db.collection("users").document(uid).collection("budgets")
        .where("category", "==", category)
        .where("monthKey", "==", month_key)
        .limit(1)
        .stream()
    )

    if not docs:
        raise HTTPException(
            status_code=404,
            detail={"success": False, "error": {"code": "NOT_FOUND", "message": f"No budget found for '{category}'."}},
        )

    actual_spent = sum_category_expense(db, uid, category, month_key)

    if actual_spent > 0:
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "HAS_TRACKED_EXPENSES",
                    "message": f"Cannot remove {category}: Rs {int(actual_spent)} has been tracked. Clear expenses first.",
                    "spent": actual_spent,
                },
            },
        )

    docs[0].reference.delete()
    print(f"[BUDGET] Deleted budget uid={uid} category={category} monthKey={month_key}")
    return {"success": True, "message": f"Budget for '{category}' removed."}