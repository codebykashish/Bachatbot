from fastapi import APIRouter, Depends, Query
from firebase_config import get_firestore
from auth import get_current_user
from utils import (
    get_current_month_key, get_days_remaining_in_month,
    get_days_passed_in_month, get_total_days_in_month,
    serialize_doc, is_today, is_yesterday,
)
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from datetime import datetime, timezone, timedelta
from typing import Optional
import calendar

router = APIRouter()


@router.get("/monthly-report")
async def get_monthly_report(
    monthKey: Optional[str] = Query(None, description="YYYY-MM. Defaults to current month."),
    view: Optional[str] = Query("month", description="'today' | 'week' (last 7 days) | 'month' (default)."),
    current_user: dict = Depends(get_current_user),
):
    """
    Generate monthly report by aggregating transactions and budgets.
    Includes daily snapshot fields for the Home screen.
    Matches ENDPOINTS.md Endpoint 11 + optional daily snapshot + insights.

    Query params:
    - monthKey: YYYY-MM (default current month)
    - view: "today" | "week" | "month" — scopes totals/categoryBreakdown/dailyBreakdown
    """
    uid = current_user["uid"]
    db = get_firestore()

    month_key = monthKey or get_current_month_key()
    view_normalized = (view or "").strip().lower()
    use_week_filter = view_normalized == "week"
    use_today_filter = view_normalized == "today"

    print(f"[REPORT] uid={uid} monthKey={month_key} view={view_normalized}")

    # ── Week filter boundaries ───────────────────────────────────────────
    week_start = None
    if use_week_filter:
        now = datetime.now(timezone.utc)
        week_start = now - timedelta(days=6)  # last 7 days including today

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

    # Per-day totals + per-day-per-category breakdown — powers the Reports
    # screen's bar chart for week/month view. Keyed by ISO date string so
    # the frontend can slice by category client-side with no extra fetch.
    daily_totals = {}
    daily_by_category = {}

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

        # If today view, skip anything not from today
        if use_today_filter and not is_today(created_at):
            continue

        if tx_type == "expense":
            total_expense += amount
            if category:
                category_breakdown[category] = category_breakdown.get(category, 0.0) + amount

            if created_at is not None:
                try:
                    date_str = created_at.date().isoformat() if hasattr(created_at, "date") else None
                except Exception:
                    date_str = None
                if date_str:
                    daily_totals[date_str] = daily_totals.get(date_str, 0.0) + amount
                    if category:
                        cat_map = daily_by_category.setdefault(date_str, {})
                        cat_map[category] = cat_map.get(category, 0.0) + amount

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

    # ── Daily breakdown for the bar chart — one entry per day, with a
    # per-category split, so the frontend can switch category filters
    # instantly with no extra fetch. Not needed for "today" view (that
    # tab shows categoryBreakdown directly as category-bars instead).
    daily_breakdown = []
    if use_week_filter:
        now = datetime.now(timezone.utc)
        for i in range(6, -1, -1):
            d = (now - timedelta(days=i)).date()
            date_str = d.isoformat()
            daily_breakdown.append({
                "date": date_str,
                "label": d.strftime("%a"),  # Sun, Mon, ...
                "dayNum": d.day,
                "total": round(daily_totals.get(date_str, 0.0), 2),
                "categories": {k: round(v, 2) for k, v in daily_by_category.get(date_str, {}).items()},
            })
    elif not use_today_filter:
        year, month_num = int(month_key[:4]), int(month_key[5:])
        total_days_in_month = calendar.monthrange(year, month_num)[1]
        for day in range(1, total_days_in_month + 1):
            date_str = f"{month_key}-{day:02d}"
            daily_breakdown.append({
                "date": date_str,
                "label": str(day),
                "dayNum": day,
                "total": round(daily_totals.get(date_str, 0.0), 2),
                "categories": {k: round(v, 2) for k, v in daily_by_category.get(date_str, {}).items()},
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
        "dailyBreakdown": daily_breakdown,
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


# ── GET /monthly-report/year-summary ────────────────────────────────────────

@router.get("/monthly-report/year-summary")
async def get_year_summary(
    year: Optional[int] = Query(None, description="Calendar year, e.g. 2026. Defaults to current year."),
    current_user: dict = Depends(get_current_user),
):
    """
    One total expense per calendar month, for the Reports screen's month
    strip. A single range query on monthKey (lexically sortable as
    "YYYY-MM") rather than 12 separate /monthly-report calls -- the strip
    needs one number per month, not each month's full category/daily
    breakdown.
    """
    uid = current_user["uid"]
    db = get_firestore()

    target_year = year or datetime.now(timezone.utc).year

    # Filters only on `status` (already indexed everywhere else in this
    # codebase) and does the year/month narrowing in Python -- a second
    # `monthKey` range filter would need a new composite Firestore index
    # that doesn't exist yet, same tradeoff pattern_service.py already
    # makes rather than requiring new infra for a read this small.
    tx_docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("status", "==", "confirmed")
        .stream()
    )

    totals = {f"{target_year}-{m:02d}": 0.0 for m in range(1, 13)}
    for doc in tx_docs:
        data = doc.to_dict()
        if data.get("isDeleted", False):
            continue
        if data.get("type") != "expense":
            continue
        month_key = data.get("monthKey")
        if month_key in totals:
            totals[month_key] += data.get("amount", 0.0)

    return {
        "success": True,
        "data": {
            "year": target_year,
            "months": totals,
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