from fastapi import APIRouter, Depends, HTTPException, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key, serialize_doc
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from typing import Optional

router = APIRouter()


@router.get("/alerts")
async def get_alerts(
    monthKey: Optional[str] = Query(None, description="YYYY-MM. Defaults to current month."),
    category: Optional[str] = Query(None, description="Filter by category."),
    isRead: Optional[bool] = Query(None, description="Filter by read status."),
    limit: int = Query(50, description="Max alerts to return."),
    current_user: dict = Depends(get_current_user),
):
    """
    Fetch alerts for the notification/alert screen.
    Matches ENDPOINTS.md Endpoint 12 exactly.
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = monthKey or get_current_month_key()
    print(f"[ALERTS] uid={uid} monthKey={month_key} category={category} isRead={isRead}")

    alerts_ref = (
        db.collection("users").document(uid).collection("alerts")
        .where("monthKey", "==", month_key)
    )

    docs = list(alerts_ref.stream())

    alerts = []
    unread_count = 0

    for doc in docs:
        data = doc.to_dict()

        # Skip soft-deleted alerts
        if data.get("isDeleted", False):
            continue

        # Filter by category if provided
        if category and data.get("category") != category:
            continue

        # Filter by isRead if provided
        if isRead is not None and data.get("isRead", False) != isRead:
            continue

        # Count unread
        if not data.get("isRead", False):
            unread_count += 1

        data["id"] = doc.id
        alerts.append(serialize_doc(data))

    # Sort by createdAt DESC (newest first)
    alerts.sort(key=lambda a: a.get("createdAt", ""), reverse=True)

    # Apply limit
    alerts = alerts[:limit]

    print(f"[ALERTS] Returning {len(alerts)} alerts, unreadCount={unread_count}")

    return {
        "success": True,
        "data": {
            "alerts": alerts,
            "unreadCount": unread_count
        }
    }


@router.patch("/alerts/{alert_id}/read")
async def mark_alert_read(
    alert_id: str,
    current_user: dict = Depends(get_current_user),
):
    """
    Mark a single alert as read.
    Matches ENDPOINTS.md Endpoint 13.
    """
    uid = current_user["uid"]
    db = get_firestore()

    alert_ref = db.collection("users").document(uid).collection("alerts").document(alert_id)
    doc = alert_ref.get()

    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "ALERT_NOT_FOUND",
                    "message": "Alert not found."
                }
            }
        )

    alert_ref.update({
        "isRead": True,
    })

    print(f"[ALERTS] uid={uid} marked alert {alert_id} as read")

    return {
        "success": True,
        "message": "Alert marked as read."
    }