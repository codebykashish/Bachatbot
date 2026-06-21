from fastapi import APIRouter, Depends, Query, HTTPException
from pydantic import BaseModel, Field
from firebase_config import get_firestore
from auth import get_current_user
from utils import serialize_doc, get_current_month_key
from typing import Optional
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment
import logging

router = APIRouter()
logger = logging.getLogger(__name__)


class ManualExpenseRequest(BaseModel):
    category: str = Field(..., min_length=1)
    amount: float = Field(..., gt=0)
    note: Optional[str] = Field(default="", max_length=200)
    monthKey: Optional[str] = None


@router.post("/transactions/manual")
async def add_manual_expense(
    body: ManualExpenseRequest,
    current_user: dict = Depends(get_current_user),
):
    """
    Manually add an expense from the category detail page.
    Mirrors what chat does: saves transaction + increments budget.spent
    (if a budget exists) + creates an alert.
    """
    uid = current_user["uid"]
    db = get_firestore()
    month_key = body.monthKey or get_current_month_key()

    # 1 — Save transaction
    tx_ref = (
        db.collection("users").document(uid)
        .collection("transactions").document()
    )
    tx_ref.set({
        "amount": body.amount,
        "category": body.category,
        "type": "expense",
        "status": "confirmed",
        "source": "manual",
        "description": body.note or "",
        "monthKey": month_key,
        "isDeleted": False,
        "deletedAt": None,
        "originalMessageId": None,
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    })
    logger.info(f"[MANUAL] uid={uid} expense {body.category} Rs {body.amount} saved id={tx_ref.id}")

    # 2 — Increment budget.spent if a budget exists for this category + month
    percent_used = 0.0
    budget_update = None
    try:
        budgets_ref = db.collection("users").document(uid).collection("budgets")
        matching = list(
            budgets_ref
            .where("category", "==", body.category)
            .where("monthKey", "==", month_key)
            .limit(1)
            .stream()
        )
        if matching:
            bref = matching[0].reference
            bref.update({"spent": Increment(body.amount), "updatedAt": SERVER_TIMESTAMP})
            updated = bref.get().to_dict()
            new_spent = updated.get("spent", 0.0)
            blimit = updated.get("limit", 0.0)
            percent_used = round((new_spent / blimit) * 100, 2) if blimit > 0 else 0.0
            budget_update = {
                "category": body.category,
                "limit": blimit,
                "spent": new_spent,
                "remaining": max(0.0, blimit - new_spent),
                "percentUsed": percent_used,
            }
            logger.info(f"[MANUAL] budget {body.category} spent→{new_spent} ({percent_used}%)")

            # Rebalance if overspent — purely additive, no other flow changes
            if new_spent > blimit:
                try:
                    from services.budget_service import rebalance_on_overspend
                    rb = rebalance_on_overspend(
                        db, uid, body.category, new_spent, blimit, matching[0].id, month_key
                    )
                    if rb:
                        budget_update["limit"] = rb["newLimit"]
                        budget_update["remaining"] = max(0.0, rb["newLimit"] - new_spent)
                        budget_update["percentUsed"] = round(
                            (new_spent / rb["newLimit"]) * 100, 2
                        ) if rb["newLimit"] > 0 else 0.0
                        logger.info(f"[MANUAL] [REBALANCE] {body.category} covered Rs {rb['totalCovered']:.0f}")
                except Exception as rb_err:
                    logger.warning(f"[MANUAL] [REBALANCE] error (non-fatal): {rb_err}")
    except Exception as e:
        logger.warning(f"[MANUAL] budget update failed: {e}")

    # 3 — Create alert
    try:
        msg = f"Rs {int(body.amount)} {body.category} expense saved."
        if budget_update and percent_used >= 80:
            msg = f"{body.category} Rs {int(body.amount)} saved, {int(percent_used)}% budget used!"
        aref = db.collection("users").document(uid).collection("alerts").document()
        aref.set({
            "type": "expense",
            "message": msg,
            "category": body.category,
            "amount": body.amount,
            "note": body.note or "",
            "severity": "medium" if percent_used >= 80 else "low",
            "isRead": False,
            "isDeleted": False,
            "monthKey": month_key,
            "relatedTransactionId": tx_ref.id,
            "createdAt": SERVER_TIMESTAMP,
        })
        logger.info(f"[MANUAL] alert created: {msg}")
    except Exception as e:
        logger.warning(f"[MANUAL] alert creation failed: {e}")

    return {
        "success": True,
        "message": f"Rs {int(body.amount)} added to {body.category}.",
        "data": {
            "transactionId": tx_ref.id,
            "category": body.category,
            "amount": body.amount,
            "monthKey": month_key,
            "budgetUpdate": budget_update,
        },
    }

@router.get("/transactions")
async def get_transactions(
    monthKey: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    limit: int = Query(50),
    current_user: dict = Depends(get_current_user)
):
    uid = current_user["uid"]
    db = get_firestore()
    
    # Reference to transactions subcollection
    tx_ref = db.collection("users").document(uid).collection("transactions")
    
    # Start query
    query = tx_ref.where("isDeleted", "==", False)
    
    # Filter by month if provided (e.g., 2026-04)
    if monthKey:
        query = query.where("monthKey", "==", monthKey)
    
    # Filter by status if provided
    if status:
        query = query.where("status", "==", status)
    
    # Order by newest first
    query = query.order_by("createdAt", direction="DESCENDING").limit(limit)
    
    # Execute query
    docs = query.stream()
    
    transactions = []
    for doc in docs:
        data = doc.to_dict()
        data["id"] = doc.id
        transactions.append(serialize_doc(data))
        
    return {
        "success": True,
        "data": {
            "transactions": transactions,
            "count": len(transactions)
        }
    }


@router.get("/transactions/pending/notifications")
async def get_pending_notification_transactions(
    current_user: dict = Depends(get_current_user)
):
    """
    List pending transactions that originated from notifications.
    Used by the frontend to show the user which notification-based 
    expenses need category assignment and confirmation.
    """
    uid = current_user["uid"]
    db = get_firestore()
    
    tx_ref = db.collection("users").document(uid).collection("transactions")
    
    # Filter for pending notification transactions
    query = (
        tx_ref.where("isDeleted", "==", False)
        .where("status", "==", "pending")
        .where("source", "==", "notification")
        .order_by("createdAt", direction="DESCENDING")
    )
    
    docs = query.stream()
    
    transactions = []
    for doc in docs:
        data = doc.to_dict()
        data["id"] = doc.id
        transactions.append(serialize_doc(data))
        
    return {
        "success": True,
        "data": {
            "transactions": transactions,
            "count": len(transactions)
        }
    }


@router.post("/transactions")
async def create_transaction(
    body: dict,
    current_user: dict = Depends(get_current_user)
):
    """
    Create a new transaction manually
    """
    uid = current_user["uid"]
    db = get_firestore()
    
    amount = body.get("amount")
    category = body.get("category")
    tx_type = body.get("type")  # "expense" or "income"
    description = body.get("description", "")
    month_key = body.get("monthKey", get_current_month_key())
    
    if not all([amount, category, tx_type]):
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "MISSING_FIELDS",
                    "message": "amount, category, and type are required"
                }
            }
        )
    
    tx_ref = db.collection("users").document(uid).collection("transactions").document()
    
    tx_data = {
        "amount": float(amount),
        "category": category,
        "type": tx_type,
        "status": "confirmed",
        "source": "manual",
        "description": description,
        "monthKey": month_key,
        "isDeleted": False,
        "deletedAt": None,
        "originalMessageId": None,
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP
    }
    
    tx_ref.set(tx_data)
    
    return {
        "success": True,
        "message": "Transaction created",
        "data": {
            "id": tx_ref.id,
            "amount": float(amount),
            "category": category,
            "type": tx_type,
            "status": "confirmed",
            "monthKey": month_key
        }
    }


@router.get("/transactions/{transaction_id}")
async def get_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user)
):
    """
    Get a specific transaction by ID
    """
    uid = current_user["uid"]
    db = get_firestore()
    
    tx_ref = db.collection("users").document(uid).collection("transactions").document(transaction_id)
    doc = tx_ref.get()
    
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "TRANSACTION_NOT_FOUND",
                    "message": "Transaction not found"
                }
            }
        )
    
    data = doc.to_dict()
    data["id"] = doc.id
    
    return {
        "success": True,
        "data": serialize_doc(data)
    }


@router.delete("/transactions/{transaction_id}")
async def delete_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user)
):
    """
    Soft delete a transaction (set isDeleted=True)
    """
    uid = current_user["uid"]
    db = get_firestore()
    
    tx_ref = db.collection("users").document(uid).collection("transactions").document(transaction_id)
    
    doc = tx_ref.get()
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "TRANSACTION_NOT_FOUND",
                    "message": "Transaction not found"
                }
            }
        )
    
    tx_ref.update({
        "isDeleted": True,
        "deletedAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP
    })
    
    return {
        "success": True,
        "message": "Transaction deleted",
        "data": {
            "id": transaction_id,
            "isDeleted": True
        }
    }


@router.put("/transactions/{transaction_id}")
async def update_transaction(
    transaction_id: str,
    body: dict,
    current_user: dict = Depends(get_current_user)
):
    """
    Update a transaction (amount, category, description, etc.)
    """
    uid = current_user["uid"]
    db = get_firestore()
    
    tx_ref = db.collection("users").document(uid).collection("transactions").document(transaction_id)
    
    doc = tx_ref.get()
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "TRANSACTION_NOT_FOUND",
                    "message": "Transaction not found"
                }
            }
        )
    
    update_data = {}
    update_data["updatedAt"] = SERVER_TIMESTAMP
    
    # Only update provided fields
    if "amount" in body:
        update_data["amount"] = float(body["amount"])
    if "category" in body:
        update_data["category"] = body["category"]
    if "description" in body:
        update_data["description"] = body["description"]
    if "type" in body:
        update_data["type"] = body["type"]
    
    tx_ref.update(update_data)
    
    return {
        "success": True,
        "message": "Transaction updated",
        "data": {
            "id": transaction_id
        }
    }