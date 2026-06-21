from fastapi import APIRouter, Depends, HTTPException, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import (
    get_current_month_key, serialize_doc,
    is_today, is_in_current_week, is_in_current_month,
    is_yesterday, is_last_week,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment
from typing import Optional
import logging

router = APIRouter()
logger = logging.getLogger(__name__)


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


@router.post("/alerts/{alert_id}/undo")
async def undo_alert(
    alert_id: str,
    current_user: dict = Depends(get_current_user),
):
    """
    Undo an alert — reverses the financial effect and soft-deletes the alert.
    - expense alerts: decrements budget.spent + soft-deletes the linked transaction.
    - income alerts:  reverses the income delta using stored incomeSource/incomeDelta fields.
    """
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
            detail={"success": False, "error": {"code": "ALERT_NOT_FOUND", "message": "Alert not found."}},
        )

    alert_data = doc.to_dict()

    if alert_data.get("isDeleted", False):
        return {"success": True, "message": "Already undone."}

    alert_type = (alert_data.get("type") or "expense").lower()
    category = alert_data.get("category", "")
    msg = "Undo successful."

    if alert_type == "expense":
        tx_id = alert_data.get("relatedTransactionId")
        if tx_id:
            tx_ref = (
                db.collection("users").document(uid)
                .collection("transactions").document(tx_id)
            )
            tx_doc = tx_ref.get()
            if tx_doc.exists and not tx_doc.to_dict().get("isDeleted", False):
                tx_data = tx_doc.to_dict()
                amount = float(tx_data.get("amount", 0.0))
                cat = tx_data.get("category", category)
                month_key = tx_data.get("monthKey", "")

                # Soft-delete transaction
                tx_ref.update({
                    "isDeleted": True,
                    "deletedAt": SERVER_TIMESTAMP,
                    "updatedAt": SERVER_TIMESTAMP,
                })

                # Reverse budget.spent
                if cat and month_key and amount > 0:
                    try:
                        budgets_ref = db.collection("users").document(uid).collection("budgets")
                        matching = list(
                            budgets_ref
                            .where("category", "==", cat)
                            .where("monthKey", "==", month_key)
                            .limit(1)
                            .stream()
                        )
                        if matching:
                            bref = matching[0].reference
                            bref.update({"spent": Increment(-amount), "updatedAt": SERVER_TIMESTAMP})
                            logger.info(f"[UNDO] uid={uid} reversed Rs {amount} from {cat} budget.spent")
                    except Exception as e:
                        logger.warning(f"[UNDO] budget reverse failed: {e}")

                msg = f"Expense of Rs {int(amount)} removed from {cat or 'budget'}."
        else:
            msg = f"Expense removed from {category}." if category else "Expense removed."

    elif alert_type == "income":
        income_source = alert_data.get("incomeSource")
        income_delta = float(alert_data.get("incomeDelta", 0.0))

        if income_source and income_delta > 0:
            user_ref = db.collection("users").document(uid)
            user_doc = user_ref.get()

            if not user_doc.exists:
                raise HTTPException(status_code=404, detail={"success": False, "error": {"code": "USER_NOT_FOUND", "message": "User not found."}})

            old_income = user_doc.to_dict().get("income", {})
            in_hand = float(old_income.get("inHand", 0.0))
            in_bank = float(old_income.get("inBank", 0.0))
            online = float(old_income.get("onlineBanking", 0.0))

            # Calculate what the income would be after reversing this delta
            if income_source == "inHand":
                new_in_hand = max(0.0, in_hand - income_delta)
                new_total = new_in_hand + in_bank + online
            elif income_source == "inBank":
                new_in_bank = max(0.0, in_bank - income_delta)
                new_total = in_hand + new_in_bank + online
            else:  # onlineBanking
                new_online = max(0.0, online - income_delta)
                new_total = in_hand + in_bank + new_online

            # Guard: income cannot drop below total allocated budget
            try:
                month_key_now = get_current_month_key()
                budgets_ref = db.collection("users").document(uid).collection("budgets")
                budget_docs = list(budgets_ref.where("monthKey", "==", month_key_now).stream())
                total_budgeted = sum(float(b.to_dict().get("limit", 0)) for b in budget_docs)

                if new_total < total_budgeted:
                    raise HTTPException(
                        status_code=400,
                        detail={
                            "success": False,
                            "error": {
                                "code": "INCOME_BELOW_BUDGET",
                                "message": (
                                    f"Cannot undo — income would drop to Rs {int(new_total)}, "
                                    f"which is below your total allocated budget of Rs {int(total_budgeted)}. "
                                    "Remove or reduce a category budget first."
                                ),
                            },
                        },
                    )
            except HTTPException:
                raise
            except Exception as e:
                logger.warning(f"[UNDO] budget validation failed (non-fatal): {e}")

            # Reverse the income
            try:
                if income_source == "inHand":
                    user_ref.update({"income.inHand": max(0.0, in_hand - income_delta), "income.updatedAt": SERVER_TIMESTAMP, "updatedAt": SERVER_TIMESTAMP})
                elif income_source == "inBank":
                    user_ref.update({"income.inBank": max(0.0, in_bank - income_delta), "income.updatedAt": SERVER_TIMESTAMP, "updatedAt": SERVER_TIMESTAMP})
                else:
                    user_ref.update({"income.onlineBanking": max(0.0, online - income_delta), "income.updatedAt": SERVER_TIMESTAMP, "updatedAt": SERVER_TIMESTAMP})
                logger.info(f"[UNDO] uid={uid} reversed Rs {income_delta} from income.{income_source}")
            except Exception as e:
                logger.warning(f"[UNDO] income reverse failed: {e}")

        msg = f"Rs {int(income_delta)} income entry reversed." if income_delta > 0 else "Income entry reversed."

    # Soft-delete the alert
    alert_ref.update({"isDeleted": True, "updatedAt": SERVER_TIMESTAMP})
    logger.info(f"[UNDO] uid={uid} alert {alert_id} soft-deleted")

    # Create a confirmation alert so it appears in the Activity feed
    try:
        confirm_category = category if alert_type == "expense" else None
        db.collection("users").document(uid).collection("alerts").document().set({
            "type": "undo_confirm",
            "message": msg,
            "category": confirm_category,
            "amount": 0,
            "severity": "low",
            "isRead": False,
            "isDeleted": False,
            "monthKey": get_current_month_key(),
            "relatedTransactionId": None,
            "createdAt": SERVER_TIMESTAMP,
        })
    except Exception as e:
        logger.warning(f"[UNDO] confirmation alert creation failed: {e}")

    return {"success": True, "message": msg}