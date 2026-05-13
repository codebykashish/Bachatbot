from fastapi import APIRouter, Depends, HTTPException
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key, serialize_doc, get_days_remaining_in_month
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment

router = APIRouter()


@router.post("/confirm-transaction/{transaction_id}")
async def confirm_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user)
):
    uid = current_user["uid"]
    db = get_firestore()
    
    # 1. Fetch transaction
    tx_ref = db.collection("users").document(uid).collection("transactions").document(transaction_id)
    tx_doc = tx_ref.get()
    
    if not tx_doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "TRANSACTION_NOT_FOUND",
                    "message": "Transaction not found."
                }
            }
        )
    
    tx_data = tx_doc.to_dict()
    
    if tx_data.get("status") != "pending":
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "INVALID_TRANSACTION_STATUS",
                    "message": "Transaction is not pending."
                }
            }
        )
    
    # 2. Update transaction
    tx_ref.update({
        "status": "confirmed",
        "updatedAt": SERVER_TIMESTAMP
    })
    
    # 3. Update related notification
    notifications_ref = db.collection("users").document(uid).collection("notifications")
    matching_notifs = list(notifications_ref.where("transactionId", "==", transaction_id).stream())
    
    for notif in matching_notifs:
        notif.reference.update({
            "status": "confirmed"
        })
    
    from datetime import datetime, timezone
    now_iso = datetime.now(timezone.utc).isoformat()
    
    # 4. Update budgets (if expense)
    amount = tx_data.get("amount", 0)
    category = tx_data.get("category")
    month_key = tx_data.get("monthKey")
    tx_type = tx_data.get("type")
    
    budget_update = None
    alerts = []
    
    if tx_type == "expense" and category:
        budgets_ref = db.collection("users").document(uid).collection("budgets")
        matching_budgets = list(
            budgets_ref
            .where("category", "==", category)
            .where("monthKey", "==", month_key)
            .limit(1)
            .stream()
        )
        
        if matching_budgets:
            budget_doc = matching_budgets[0]
            budget_ref = budget_doc.reference
            
            budget_ref.update({
                "spent": Increment(float(amount)),
                "updatedAt": SERVER_TIMESTAMP
            })
            
            updated_budget = budget_ref.get().to_dict()
            new_spent = updated_budget.get("spent", 0.0)
            budget_limit = updated_budget.get("limit", 0.0)
            threshold = updated_budget.get("alertThreshold", 80)
            
            percent_used = round((new_spent / budget_limit) * 100, 2) if budget_limit > 0 else 0.0
            remaining = budget_limit - new_spent
            days_remaining = get_days_remaining_in_month()
            
            budget_update = {
                "category": category,
                "limit": budget_limit,
                "spent": new_spent,
                "remaining": remaining,
                "percentUsed": percent_used
            }
            
            # Alert Logic
            if percent_used >= 100:
                alert_data = {
                    "type": "overspent",
                    "category": category,
                    "message": f"{category} budget OVER! Rs {new_spent} out of Rs {budget_limit}.",
                    "severity": "high",
                    "isRead": False,
                    "monthKey": month_key,
                    "createdAt": SERVER_TIMESTAMP
                }
                alert_ref = db.collection("users").document(uid).collection("alerts").document()
                alert_ref.set(alert_data)
                
                # For response
                resp_alert = alert_data.copy()
                resp_alert["id"] = alert_ref.id
                resp_alert["createdAt"] = now_iso
                alerts.append(resp_alert)
                
            elif percent_used >= threshold:
                alert_data = {
                    "type": "budget_warning",
                    "category": category,
                    "message": f"{category} ma Rs {new_spent}/{budget_limit} spend. Rs {remaining} left, {days_remaining} days remaining.",
                    "severity": "high",
                    "isRead": False,
                    "monthKey": month_key,
                    "createdAt": SERVER_TIMESTAMP
                }
                alert_ref = db.collection("users").document(uid).collection("alerts").document()
                alert_ref.set(alert_data)
                
                # For response
                resp_alert = alert_data.copy()
                resp_alert["id"] = alert_ref.id
                resp_alert["createdAt"] = now_iso
                alerts.append(resp_alert)

    # 5. Save assistant message
    messages_ref = db.collection("users").document(uid).collection("messages")
    reply = f"Transaction confirmed! Rs {amount} {category} ma record gareko chu."
    if alerts:
        reply += f"\n⚠️ {alerts[0]['message']}"
        
    messages_ref.add({
        "role": "assistant",
        "content": reply,
        "intent": "confirmation_response",
        "relatedTransactionId": transaction_id,
        "createdAt": SERVER_TIMESTAMP
    })

    print(f"[CONFIRM] uid={uid} tx={transaction_id} status=confirmed")

    return {
        "success": True,
        "message": "Transaction confirmed.",
        "data": {
            "transaction": {
                "id": transaction_id,
                "amount": amount,
                "category": category,
                "type": tx_type,
                "status": "confirmed",
                "source": tx_data.get("source"),
                "updatedAt": now_iso
            },
            "budgetUpdate": budget_update,
            "alerts": alerts
        }
    }


@router.post("/reject-transaction/{transaction_id}")
async def reject_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user)
):
    uid = current_user["uid"]
    db = get_firestore()
    
    # 1. Fetch transaction
    tx_ref = db.collection("users").document(uid).collection("transactions").document(transaction_id)
    tx_doc = tx_ref.get()
    
    if not tx_doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "TRANSACTION_NOT_FOUND",
                    "message": "Transaction not found."
                }
            }
        )
    
    tx_data = tx_doc.to_dict()
    
    if tx_data.get("status") != "pending":
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "INVALID_TRANSACTION_STATUS",
                    "message": "Transaction is not pending."
                }
            }
        )
    
    # 2. Update transaction
    tx_ref.update({
        "status": "rejected",
        "updatedAt": SERVER_TIMESTAMP
    })
    
    # 3. Update related notification
    notifications_ref = db.collection("users").document(uid).collection("notifications")
    matching_notifs = list(notifications_ref.where("transactionId", "==", transaction_id).stream())
    
    for notif in matching_notifs:
        notif.reference.update({
            "status": "rejected"
        })
        
    # 4. Save assistant message
    messages_ref = db.collection("users").document(uid).collection("messages")
    messages_ref.add({
        "role": "assistant",
        "content": "Transaction rejected. No kharcha was recorded.",
        "intent": "confirmation_response",
        "relatedTransactionId": transaction_id,
        "createdAt": SERVER_TIMESTAMP
    })

    print(f"[REJECT] uid={uid} tx={transaction_id} status=rejected")

    return {
        "success": True,
        "message": "Transaction rejected.",
        "data": {
            "transaction": {
                "id": transaction_id,
                "status": "rejected"
            }
        }
    }
