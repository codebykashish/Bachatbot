from fastapi import APIRouter, Depends, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import (
    get_current_month_key, get_days_remaining_in_month,
    serialize_doc, is_today,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from typing import Optional

router = APIRouter()


@router.get("/monthly-report")
async def get_monthly_report(
    monthKey: Optional[str] = Query(None, description="YYYY-MM. Defaults to current month."),
    current_user: dict = Depends(get_current_user),
):
    """
    Generate monthly report by aggregating transactions and budgets.
    Includes daily snapshot fields for the Home screen.
    Matches ENDPOINTS.md Endpoint 11 + optional daily snapshot.
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = monthKey or get_current_month_key()
    print(f"[REPORT] uid={uid} monthKey={month_key}")

    # ── Fetch all confirmed, non-deleted transactions for this month ─────
    tx_docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("monthKey", "==", month_key)
        .where("status", "==", "confirmed")
        .stream()
    )

    total_expense = 0.0
    total_income = 0.0
    category_breakdown = {}

    # Daily snapshot accumulators
    today_expense = 0.0
    today_category_totals = {}

    for doc in tx_docs:
        data = doc.to_dict()
        if data.get("isDeleted", False):
            continue

        amount = data.get("amount", 0.0)
        tx_type = data.get("type", "")
        category = data.get("category")
        created_at = data.get("createdAt")

        if tx_type == "expense":
            total_expense += amount
            if category:
                category_breakdown[category] = category_breakdown.get(category, 0.0) + amount

            # Check if this transaction is from today
            if is_today(created_at):
                today_expense += amount
                if category:
                    today_category_totals[category] = today_category_totals.get(category, 0.0) + amount

        elif tx_type == "income":
            total_income += amount

    net_savings = total_income - total_expense

    # ── Compute daily snapshot ───────────────────────────────────────────
    today_top_category = None
    if today_category_totals:
        today_top_category = max(today_category_totals, key=today_category_totals.get)

    if today_top_category and today_expense > 0:
        today_summary_text = f"Aaja Rs {int(today_expense)} {today_top_category} ma kharcha bhayo."
    elif today_expense > 0:
        today_summary_text = f"Aaja Rs {int(today_expense)} kharcha bhayo."
    else:
        today_summary_text = "Aaja kei kharcha bhayena."

    # ── Fetch budgets for this month → budget utilization ────────────────
    budget_docs = (
        db.collection("users").document(uid).collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )

    budget_utilization = {}
    total_remaining = 0.0
    for doc in budget_docs:
        bdata = doc.to_dict()
        cat = bdata.get("category", "")
        limit_val = bdata.get("limit", 0.0)
        spent_val = bdata.get("spent", 0.0)
        if limit_val > 0:
            budget_utilization[cat] = round((spent_val / limit_val) * 100)
            total_remaining += max(0.0, limit_val - spent_val)

    # ── Days remaining + survival budget ─────────────────────────────────
    days_remaining = get_days_remaining_in_month()
    survival_budget_per_day = round(total_remaining / days_remaining) if days_remaining > 0 else 0

    # ── Alert count for this month ───────────────────────────────────────
    alert_docs = list(
        db.collection("users").document(uid).collection("alerts")
        .where("monthKey", "==", month_key)
        .stream()
    )
    alert_count = len(alert_docs)

    # ── Build and save/cache report ──────────────────────────────────────
    report_data = {
        "monthKey": month_key,
        "totalExpense": total_expense,
        "totalIncome": total_income,
        "netSavings": net_savings,
        "categoryBreakdown": category_breakdown,
        "budgetUtilization": budget_utilization,
        "daysRemaining": days_remaining,
        "survivalBudgetPerDay": survival_budget_per_day,
        "alertCount": alert_count,
        # Daily snapshot (optional additional fields)
        "todayTotalExpense": today_expense,
        "todayTopCategory": today_top_category,
        "todaySummaryText": today_summary_text,
        "generatedAt": SERVER_TIMESTAMP,
    }

    report_ref = (
        db.collection("users").document(uid)
        .collection("monthlyReports").document(month_key)
    )
    report_ref.set(report_data)

    # Re-read to get the server timestamp resolved
    saved = report_ref.get().to_dict()

    print(
        f"[REPORT] totalExpense={total_expense} totalIncome={total_income} "
        f"netSavings={net_savings} cats={list(category_breakdown.keys())} "
        f"todayExpense={today_expense} todayTop={today_top_category}"
    )

    return {
        "success": True,
        "data": {
            "report": serialize_doc(saved),
        },
    }


# ── GET /daily-summary ──────────────────────────────────────────────────────

@router.get("/daily-summary")
async def get_daily_summary(
    current_user: dict = Depends(get_current_user),
):
    """
    Quick daily snapshot for the Home screen.
    Returns today's total expense, top category, and summary text.
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = get_current_month_key()
    print(f"[DAILY] uid={uid} monthKey={month_key}")

    # Fetch all confirmed, non-deleted transactions for this month
    tx_docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("monthKey", "==", month_key)
        .where("status", "==", "confirmed")
        .stream()
    )

    today_expense = 0.0
    today_income = 0.0
    today_categories = {}

    for doc in tx_docs:
        data = doc.to_dict()
        if data.get("isDeleted", False):
            continue

        created_at = data.get("createdAt")
        if not is_today(created_at):
            continue

        amount = data.get("amount", 0.0)
        tx_type = data.get("type", "")
        category = data.get("category")

        if tx_type == "expense":
            today_expense += amount
            if category:
                today_categories[category] = today_categories.get(category, 0.0) + amount
        elif tx_type == "income":
            today_income += amount

    top_cat = None
    if today_categories:
        top_cat = max(today_categories, key=today_categories.get)

    if top_cat and today_expense > 0:
        summary = f"Aaja Rs {int(today_expense)} {top_cat} ma kharcha bhayo."
    elif today_expense > 0:
        summary = f"Aaja Rs {int(today_expense)} kharcha bhayo."
    else:
        summary = "Aaja kei kharcha bhayena."

    print(f"[DAILY] todayExpense={today_expense} todayIncome={today_income} topCat={top_cat}")

    return {
        "success": True,
        "data": {
            "todayTotalExpense": today_expense,
            "todayTotalIncome": today_income,
            "todayTopCategory": top_cat,
            "todaySummaryText": summary,
            "categoryBreakdown": today_categories,
        },
    }