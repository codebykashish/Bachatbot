from fastapi import APIRouter, Depends, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import (
    get_current_month_key, get_days_remaining_in_month,
    serialize_doc, is_today,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from datetime import datetime, timezone
from typing import Optional

router = APIRouter()


@router.get("/monthly-report")
async def get_monthly_report(
    monthKey: Optional[str] = Query(None, description="YYYY-MM. Defaults to current month."),
    view: Optional[str] = Query("month", description="'month' (default) or 'week' (last 7 days)."),
    current_user: dict = Depends(get_current_user),
):
    """
    Generate monthly report by aggregating transactions and budgets.
    Includes daily snapshot fields for the Home screen.
    Matches ENDPOINTS.md Endpoint 11 + optional daily snapshot + insights.

    Query params:
    - monthKey: YYYY-MM (default current month)
    - view: "month" | "week" — if "week", only include last 7 days of transactions
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = monthKey or get_current_month_key()
    use_week_filter = (view or "").strip().lower() == "week"

    print(f"[REPORT] uid={uid} monthKey={month_key} view={'week' if use_week_filter else 'month'}")

    # ── Week filter boundaries ───────────────────────────────────────────
    week_start = None
    if use_week_filter:
        from datetime import timedelta
        now = datetime.now(timezone.utc)
        week_start = now - timedelta(days=6)  # last 7 days including today

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

        # If week view, skip transactions outside the 7-day window
        if use_week_filter and week_start and created_at:
            try:
                if hasattr(created_at, "replace"):
                    ts = created_at if created_at.tzinfo else created_at.replace(tzinfo=timezone.utc)
                    if ts < week_start:
                        continue
            except Exception:
                pass  # include if we can't determine the date

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

    # ── Fetch budgets for this month → budget utilization + insights ─────
    budget_docs_list = list(
        db.collection("users").document(uid).collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )

    budget_utilization = {}
    total_remaining = 0.0
    # Build budget lookup for insights: {category: {limit, spent_from_budget}}
    budget_lookup = {}

    for doc in budget_docs_list:
        bdata = doc.to_dict()
        cat = bdata.get("category", "")
        limit_val = bdata.get("limit", 0.0)
        spent_val = bdata.get("spent", 0.0)
        if limit_val > 0:
            budget_utilization[cat] = round((spent_val / limit_val) * 100)
            total_remaining += max(0.0, limit_val - spent_val)
        budget_lookup[cat] = {"limit": limit_val, "spent": spent_val}

    # ── Insights ─────────────────────────────────────────────────────────
    # Per-category insights (only for categories that have a budget)
    category_insights = {}
    any_overspent = False
    any_high = False
    total_budget_limit = 0.0
    total_budget_spent = 0.0

    for cat, binfo in budget_lookup.items():
        blimit = binfo["limit"]
        # Use actual transaction-based spending from categoryBreakdown for this period
        bspent = category_breakdown.get(cat, 0.0)
        total_budget_limit += blimit
        total_budget_spent += bspent

        if blimit <= 0:
            category_insights[cat] = {
                "status": "ok",
                "spent": bspent,
                "limit": blimit,
            }
            continue

        pct = (bspent / blimit) * 100

        if pct > 100:
            status = "overspent"
            any_overspent = True
        elif pct > 80:
            status = "high"
            any_high = True
        elif pct <= 50:
            status = "low"
        else:
            status = "ok"

        # Special case: exactly at limit
        if bspent == blimit and blimit > 0:
            status = "exact"

        category_insights[cat] = {
            "status": status,
            "spent": bspent,
            "limit": blimit,
        }

    # Overall status
    if any_overspent:
        overall_status = "overspent"
    elif any_high:
        overall_status = "high"
    elif total_budget_limit > 0 and total_budget_spent <= total_budget_limit * 0.5:
        overall_status = "low"
    else:
        overall_status = "ok"

    insights = {
        "overallStatus": overall_status,
        "categories": category_insights,
    }

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
        "insights": insights,
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
        f"insights={overall_status} view={'week' if use_week_filter else 'month'} "
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