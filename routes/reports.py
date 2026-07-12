from fastapi import APIRouter, Depends, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import (
    get_current_month_key, get_days_remaining_in_month,
    get_days_passed_in_month, get_total_days_in_month,
    serialize_doc, is_today, is_yesterday,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from datetime import datetime, timezone
from typing import Optional
import calendar

router = APIRouter()


@router.get("/monthly-report")
async def get_monthly_report(
    monthKey: Optional[str] = Query(None, description="YYYY-MM. Defaults to current month."),
    view: Optional[str] = Query("month", description="'month' (default) or 'week' (last 7 days)."),
    weekOfMonth: Optional[int] = Query(None, ge=1, le=4, description="1-4 — filters the report to just that week bucket within monthKey."),
    current_user: dict = Depends(get_current_user),
):
    """
    Generate monthly report by aggregating transactions and budgets.
    Includes daily snapshot fields for the Home screen.
    Matches ENDPOINTS.md Endpoint 11 + optional daily snapshot + insights.

    Query params:
    - monthKey: YYYY-MM (default current month)
    - view: "month" | "week" — if "week", only include last 7 days of transactions
    - weekOfMonth: 1-4 — restricts the report to that week's day range within
      monthKey (days 1-7 / 8-14 / 15-21 / 22-end). Independent of `view`.
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = monthKey or get_current_month_key()
    use_week_filter = (view or "").strip().lower() == "week"

    print(f"[REPORT] uid={uid} monthKey={month_key} view={'week' if use_week_filter else 'month'} weekOfMonth={weekOfMonth}")

    # ── Week filter boundaries ───────────────────────────────────────────
    week_start = None
    if use_week_filter:
        from datetime import timedelta
        now = datetime.now(timezone.utc)
        week_start = now - timedelta(days=6)  # last 7 days including today

    # ── Week-of-month day range (independent of the last-7-days filter) ──
    week_of_month_range = None
    if weekOfMonth:
        wy, wm = int(month_key[:4]), int(month_key[5:])
        wtotal_days = calendar.monthrange(wy, wm)[1]
        wbucket_ranges = [(1, 7), (8, 14), (15, 21), (22, wtotal_days)]
        week_of_month_range = wbucket_ranges[weekOfMonth - 1]

    # ── Fetch confirmed, non-deleted transactions ─────────────────────────
    # Week view spans the last 7 days, which can cross a month boundary —
    # querying by monthKey would silently drop older-month days in that
    # window, so week view queries across all months and relies on the
    # week_start cutoff below instead.
    base_query = db.collection("users").document(uid).collection("transactions").where("status", "==", "confirmed")
    tx_docs = (
        base_query.stream()
        if use_week_filter
        else base_query.where("monthKey", "==", month_key).stream()
    )

    total_expense = 0.0
    total_income = 0.0
    category_breakdown = {}

    # Daily snapshot accumulators
    today_expense = 0.0
    today_category_totals = {}
    yesterday_expense = 0.0
    yesterday_income = 0.0
    yesterday_category_totals = {}

    # Weekly breakdown within the selected month — 4 buckets (days 1-7,
    # 8-14, 15-21, 22-end), only meaningful in month view since week view
    # transactions aren't confined to a single calendar month.
    week_bucket_expense = [0.0, 0.0, 0.0, 0.0]
    week_bucket_income = [0.0, 0.0, 0.0, 0.0]

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

        # If a specific week-of-month was requested, skip days outside it
        if week_of_month_range and created_at is not None:
            try:
                day = created_at.day
                if not (week_of_month_range[0] <= day <= week_of_month_range[1]):
                    continue
            except Exception:
                pass

        # Weekly breakdown bucket (month view only)
        if not use_week_filter and created_at is not None:
            try:
                day = created_at.day
                bucket_idx = min(3, (day - 1) // 7)
                if tx_type == "expense":
                    week_bucket_expense[bucket_idx] += amount
                elif tx_type == "income":
                    week_bucket_income[bucket_idx] += amount
            except Exception:
                pass

        if tx_type == "expense":
            total_expense += amount
            if category:
                category_breakdown[category] = category_breakdown.get(category, 0.0) + amount

            # Check if this transaction is from today
            if is_today(created_at):
                today_expense += amount
                if category:
                    today_category_totals[category] = today_category_totals.get(category, 0.0) + amount
            elif is_yesterday(created_at):
                yesterday_expense += amount
                if category:
                    yesterday_category_totals[category] = yesterday_category_totals.get(category, 0.0) + amount

        elif tx_type == "income":
            total_income += amount
            if is_yesterday(created_at):
                yesterday_income += amount

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

    yesterday_top_category = None
    if yesterday_category_totals:
        yesterday_top_category = max(yesterday_category_totals, key=yesterday_category_totals.get)

    if yesterday_top_category and yesterday_expense > 0:
        yesterday_summary_text = f"You spent Rs {int(yesterday_expense)} on {yesterday_top_category} yesterday."
    elif yesterday_expense > 0:
        yesterday_summary_text = f"You spent Rs {int(yesterday_expense)} yesterday."
    else:
        yesterday_summary_text = "No spending yesterday."

    # ── Fetch budgets for this month → budget utilization + insights ─────
    budget_docs_list = list(
        db.collection("users").document(uid).collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )

    budget_utilization = {}
    total_remaining = 0.0
    total_budget_limit = 0.0  # Used for income card value
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
        total_budget_limit += limit_val   # sum all budgets for income card
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

    # ── Weekly breakdown labels (month view only) ─────────────────────────
    weekly_breakdown = []
    if not use_week_filter:
        year, month_num = int(month_key[:4]), int(month_key[5:])
        total_days_in_month = calendar.monthrange(year, month_num)[1]
        bucket_ranges = [(1, 7), (8, 14), (15, 21), (22, total_days_in_month)]
        month_abbrev = calendar.month_abbr[month_num]
        for i, (start_day, end_day) in enumerate(bucket_ranges):
            weekly_breakdown.append({
                "week": i + 1,
                "label": f"Week {i + 1}",
                "dateRange": f"{month_abbrev} {start_day}-{end_day}",
                "totalExpense": round(week_bucket_expense[i], 2),
                "totalIncome": round(week_bucket_income[i], 2),
            })

    # ── Days remaining + survival budget ─────────────────────────────────
    days_remaining = get_days_remaining_in_month()
    survival_budget_per_day = round(total_remaining / days_remaining) if days_remaining > 0 else 0

    # ── Pace warning: spending faster than the month is passing ──────────
    pace_warning_text = None
    if total_budget_limit > 0:
        pct_used = (total_budget_spent / total_budget_limit) * 100
        days_passed = get_days_passed_in_month()
        total_days = get_total_days_in_month()
        pct_month_elapsed = (days_passed / total_days) * 100 if total_days > 0 else 0
        if pct_used - pct_month_elapsed > 15:
            pace_warning_text = (
                f"Rs {int(total_budget_spent)} of Rs {int(total_budget_limit)} spent. "
                f"Only Rs {int(total_remaining)} left for the next {days_remaining} days."
            )

    # ── Alert count for this month ───────────────────────────────────────
    alert_docs = list(
        db.collection("users").document(uid).collection("alerts")
        .where("monthKey", "==", month_key)
        .stream()
    )
    alert_count = len(alert_docs)

    # ── Build and save/cache report ──────────────────────────────────────
    # incomeCardValue = totalBudget + totalIncomeTx
    # This is what the Income card on the home screen should display.
    income_card_value = total_budget_limit + total_income

    report_data = {
        "monthKey": month_key,
        "totalExpense": total_expense,
        "totalIncome": total_income,
        "totalBudget": total_budget_limit,
        "incomeCardValue": income_card_value,   # ← Income card = budgets + incomes
        "netSavings": net_savings,
        "categoryBreakdown": category_breakdown,
        "budgetUtilization": budget_utilization,
        "insights": insights,
        "weeklyBreakdown": weekly_breakdown,
        "daysRemaining": days_remaining,
        "survivalBudgetPerDay": survival_budget_per_day,
        "alertCount": alert_count,
        # Daily snapshot (optional additional fields)
        "todayTotalExpense": today_expense,
        "todayTopCategory": today_top_category,
        "todaySummaryText": today_summary_text,
        "yesterdayTotalExpense": yesterday_expense,
        "yesterdayTotalIncome": yesterday_income,
        "yesterdayTopCategory": yesterday_top_category,
        "yesterdaySummaryText": yesterday_summary_text,
        "paceWarningText": pace_warning_text,
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