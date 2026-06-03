from fastapi import APIRouter, Depends, Query, HTTPException
from firebase_config import get_firestore
from auth import get_current_user
from utils import serialize_doc, get_current_month_key
from typing import Optional
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
router = APIRouter()

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