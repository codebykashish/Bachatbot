from fastapi import APIRouter, Depends, HTTPException, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import (
    get_current_month_key, serialize_doc,
    is_today, is_in_current_week, is_in_current_month,
    is_yesterday, is_last_week,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from typing import Optional

router = APIRouter()


@router.get("/alerts")
async def get_alerts(
    tx_type: Optional[str] = Query(None, alias="type", description="expense or income"),
    monthKey: Optional[str] = Query(None, description="YYYY-MM. Defaults to current month."),
    category: Optional[str] = Query(None, description="Filter by category."),
    dateRange: Optional[str] = Query(None, description="today | week | month | all"),
    isRead: Optional[bool] = Query(None, description="Filter by read status."),
    limit: int = Query(50, description="Max alerts to return."),
    current_user: dict = Depends(get_current_user),
):
    """
    Fetch alerts for the notification/alert screen.
    Ordered newest-first. Supports category, type, and dateRange filters.
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = monthKey or get_current_month_key()
    effective_range = dateRange or "all"

    print(f"[ALERTS] uid={uid} monthKey={month_key} category={category} dateRange={effective_range} isRead={isRead}")

    # For cross-month date ranges (yesterday/last_week) we must NOT scope by monthKey
    # because "yesterday" at the start of a new month would be in the previous monthKey.
    # For "today", "week", "month", "all" we keep the monthKey scope for performance.
    cross_month_ranges = ("yesterday", "last_week")
    if effective_range in cross_month_ranges:
        alerts_ref = db.collection("users").document(uid).collection("alerts")
    else:
        alerts_ref = (
            db.collection("users").document(uid).collection("alerts")
            .where("monthKey", "==", month_key)
        )

    docs = list(alerts_ref.stream())

    alerts = []
    unread_count = 0

    for doc in docs:
        data = doc.to_dict()

        # Skip soft-deleted
        if data.get("isDeleted", False):
            continue

        # Filter by tx_type
        if tx_type == "expense":
            # Treat None/missing type as "expense" for legacy data
            t = data.get("type")
            if t not in ("expense", None, "transaction_saved"):
                continue
        elif tx_type == "income":
            if data.get("type") != "income":
                continue

        # Filter by category
        if category and data.get("category") != category:
            continue

        # Filter by isRead
        if isRead is not None and data.get("isRead", False) != isRead:
            continue

        # Filter by dateRange
        created_at = data.get("createdAt")
        if effective_range == "today" and not is_today(created_at):
            continue
        elif effective_range == "yesterday" and not is_yesterday(created_at):
            continue
        elif effective_range == "week" and not is_in_current_week(created_at):
            continue
        elif effective_range == "last_week" and not is_last_week(created_at):
            continue
        elif effective_range == "month" and not is_in_current_month(created_at):
            continue
        # "all" → no extra time filter

        # Count unread (across all filtered results)
        if not data.get("isRead", False):
            unread_count += 1

        data["id"] = doc.id
        alerts.append(serialize_doc(data))

    # Sort newest first
    alerts.sort(key=lambda a: a.get("createdAt", ""), reverse=True)

    # Apply limit
    alerts = alerts[:limit]

    print(f"[ALERTS] Returning {len(alerts)} alerts, unreadCount={unread_count}")

    return {
        "success": True,
        "data": {
            "alerts": alerts,
            "unreadCount": unread_count,
        },
    }


@router.patch("/alerts/{alert_id}/read")
async def mark_alert_read(
    alert_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Mark a single alert as read."""
    uid = current_user["uid"]
    db = get_firestore()

    alert_ref = (
        db.collection("users").document(uid)
        .collection("alerts").document(alert_id)
    )
    doc = alert_ref.get()

    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "ALERT_NOT_FOUND",
                    "message": "Alert not found.",
                },
            },
        )

    alert_ref.update({"isRead": True})
    print(f"[ALERTS] uid={uid} marked alert {alert_id} as read")

    return {
        "success": True,
        "message": "Alert marked as read.",
    }