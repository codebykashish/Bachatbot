from fastapi import APIRouter, Depends, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import serialize_doc
from typing import Optional

router = APIRouter()

@router.get("/transactions")
async def get_transactions(
    monthKey: Optional[str] = Query(None),
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