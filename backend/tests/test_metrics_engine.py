"""
test_metrics_engine.py
=========================
Phase 2.1 (Days Remaining), Phase 2.2 (Budget Utilization), and Phase 2.3
(Recommended Daily Spend) acceptance scenarios for the Metrics Engine —
see FINANCIAL_ENGINE_SPEC.md. Pure math, no Firestore needed — every
case pins explicit inputs so the test never depends on real data or the
day it happens to run.

Run directly: python tests/test_metrics_engine.py
"""

import sys
import os
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.metrics_engine import (
    compute_days_remaining,
    compute_budget_utilization,
    compute_recommended_daily_spend,
    compute_category_daily_target,
    compute_spending_pace,
    compute_recovery_plan,
    compute_category_pressure,
    compute_projected_savings,
)

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def d(year, month, day):
    return datetime(year, month, day, tzinfo=timezone.utc)


def run():
    print("Days Remaining — edge cases")

    check(
        "July 1 -> 31",
        compute_days_remaining("2026-07", d(2026, 7, 1)) == 31,
        f"got {compute_days_remaining('2026-07', d(2026, 7, 1))}",
    )
    check(
        "July 15 -> 17",
        compute_days_remaining("2026-07", d(2026, 7, 15)) == 17,
        f"got {compute_days_remaining('2026-07', d(2026, 7, 15))}",
    )
    check(
        "July 18 -> 14",
        compute_days_remaining("2026-07", d(2026, 7, 18)) == 14,
        f"got {compute_days_remaining('2026-07', d(2026, 7, 18))}",
    )
    check(
        "July 31 (last day) -> 1, never 0",
        compute_days_remaining("2026-07", d(2026, 7, 31)) == 1,
        f"got {compute_days_remaining('2026-07', d(2026, 7, 31))}",
    )
    check(
        "February 28, non-leap year (2026) -> 1",
        compute_days_remaining("2026-02", d(2026, 2, 28)) == 1,
        f"got {compute_days_remaining('2026-02', d(2026, 2, 28))}",
    )
    check(
        "February 29, leap year (2028) -> 1",
        compute_days_remaining("2028-02", d(2028, 2, 29)) == 1,
        f"got {compute_days_remaining('2028-02', d(2028, 2, 29))}",
    )
    check(
        "February 1, leap year (2028) -> 29",
        compute_days_remaining("2028-02", d(2028, 2, 1)) == 29,
        f"got {compute_days_remaining('2028-02', d(2028, 2, 1))}",
    )
    check(
        "Month rollover: July 31 and August 1 are each correct independently",
        compute_days_remaining("2026-07", d(2026, 7, 31)) == 1
        and compute_days_remaining("2026-08", d(2026, 8, 1)) == 31,
        f"got July31={compute_days_remaining('2026-07', d(2026, 7, 31))}, "
        f"Aug1={compute_days_remaining('2026-08', d(2026, 8, 1))}",
    )
    check(
        "Requested monthKey is not the current month -> 0",
        compute_days_remaining("2026-06", d(2026, 7, 15)) == 0,
        f"got {compute_days_remaining('2026-06', d(2026, 7, 15))}",
    )

    print()
    print("Budget Utilization — edge cases")

    def util(cat, spent, limit):
        return compute_budget_utilization({cat: {"spent": spent, "limit": limit}})[cat]["utilization"]

    check("50/100 -> 50%", util("X", 50, 100) == 50.0, f"got {util('X', 50, 100)}")
    check("0/100 -> 0%", util("X", 0, 100) == 0.0, f"got {util('X', 0, 100)}")
    check("100/100 -> 100%", util("X", 100, 100) == 100.0, f"got {util('X', 100, 100)}")
    check("120/100 -> 120% (not clamped)", util("X", 120, 100) == 120.0, f"got {util('X', 120, 100)}")
    check("0/0 -> 0% (limit==0 rule)", util("X", 0, 0) == 0.0, f"got {util('X', 0, 0)}")
    check("1/0 -> 0% (limit==0 rule, spent irrelevant)", util("X", 1, 0) == 0.0, f"got {util('X', 1, 0)}")
    check(
        "Multi-category input keeps each category independent",
        compute_budget_utilization({
            "Food": {"spent": 1800, "limit": 3000},
            "Shopping": {"spent": 0, "limit": 0},
        }) == {"Food": {"utilization": 60.0}, "Shopping": {"utilization": 0.0}},
    )

    print()
    print("Recommended Daily Spend — edge cases")

    def rds(category_remaining, days_remaining):
        return compute_recommended_daily_spend(category_remaining, days_remaining)

    check(
        "Remaining 1200, Days 12 -> 100/day",
        rds({"Food": {"limit": 1200, "remaining": 1200}}, 12) == {"value": 100.0, "confidence": "medium"},
        f"got {rds({'Food': {'limit': 1200, 'remaining': 1200}}, 12)}",
    )
    check(
        "Remaining 0, Days 10 -> 0/day",
        rds({"Food": {"limit": 100, "remaining": 0}}, 10) == {"value": 0.0, "confidence": "medium"},
        f"got {rds({'Food': {'limit': 100, 'remaining': 0}}, 10)}",
    )
    check(
        "Remaining -500 (synthetic), Days 5 -> 0/day, never negative",
        rds({"Food": {"limit": 100, "remaining": -500}}, 5) == {"value": 0.0, "confidence": "medium"},
        f"got {rds({'Food': {'limit': 100, 'remaining': -500}}, 5)}",
    )
    check(
        "No budgets at all -> null",
        rds({"Food": {"limit": 0, "remaining": 0}}, 10) is None,
        f"got {rds({'Food': {'limit': 0, 'remaining': 0}}, 10)}",
    )
    check(
        "Empty categoryRemaining -> null",
        rds({}, 10) is None,
        f"got {rds({}, 10)}",
    )
    check(
        "Remaining 1500, Days 1 -> 1500/day",
        rds({"Food": {"limit": 1500, "remaining": 1500}}, 1) == {"value": 1500.0, "confidence": "medium"},
        f"got {rds({'Food': {'limit': 1500, 'remaining': 1500}}, 1)}",
    )
    check(
        "Multi-category sums only budgeted categories, ignores limit==0 ones",
        rds({
            "Food": {"limit": 3000, "remaining": 700},
            "Shopping": {"limit": 0, "remaining": 0},
        }, 14) == {"value": 50.0, "confidence": "medium"},
        f"got {rds({'Food': {'limit': 3000, 'remaining': 700}, 'Shopping': {'limit': 0, 'remaining': 0}}, 14)}",
    )
    check(
        "daysRemaining == 0 (non-current month) -> null, not a division error",
        rds({"Food": {"limit": 100, "remaining": 50}}, 0) is None,
        f"got {rds({'Food': {'limit': 100, 'remaining': 50}}, 0)}",
    )

    print()
    print("Category Daily Target — edge cases")

    check(
        "Normal category with buffer -> remaining/daysRemaining exactly",
        compute_category_daily_target({"Food": {"limit": 1000, "remaining": 280}}, 14)
        == {"Food": {"value": 20.0, "confidence": "medium"}},
        f"got {compute_category_daily_target({'Food': {'limit': 1000, 'remaining': 280}}, 14)}",
    )
    check(
        "Exhausted category -> 0, included (not omitted)",
        compute_category_daily_target({"Food": {"limit": 1000, "remaining": 0}}, 14)
        == {"Food": {"value": 0.0, "confidence": "medium"}},
        f"got {compute_category_daily_target({'Food': {'limit': 1000, 'remaining': 0}}, 14)}",
    )
    check(
        "Unbudgeted category -> omitted entirely from the map",
        compute_category_daily_target(
            {"Food": {"limit": 1000, "remaining": 280}, "Shopping": {"limit": 0, "remaining": 0}}, 14
        ) == {"Food": {"value": 20.0, "confidence": "medium"}},
        f"got {compute_category_daily_target({'Food': {'limit': 1000, 'remaining': 280}, 'Shopping': {'limit': 0, 'remaining': 0}}, 14)}",
    )
    check(
        "No budgeted categories at all -> null",
        compute_category_daily_target({"Shopping": {"limit": 0, "remaining": 0}}, 14) is None,
        f"got {compute_category_daily_target({'Shopping': {'limit': 0, 'remaining': 0}}, 14)}",
    )
    check(
        "daysRemaining <= 0 -> null, not a division error",
        compute_category_daily_target({"Food": {"limit": 1000, "remaining": 280}}, 0) is None,
        f"got {compute_category_daily_target({'Food': {'limit': 1000, 'remaining': 280}}, 0)}",
    )
    check(
        "Multiple categories -> independent values",
        compute_category_daily_target(
            {"Food": {"limit": 1000, "remaining": 280}, "Transport": {"limit": 1000, "remaining": 560}}, 14
        ) == {
            "Food": {"value": 20.0, "confidence": "medium"},
            "Transport": {"value": 40.0, "confidence": "medium"},
        },
        f"got {compute_category_daily_target({'Food': {'limit': 1000, 'remaining': 280}, 'Transport': {'limit': 1000, 'remaining': 560}}, 14)}",
    )

    print()
    print("Spending Pace — edge cases")

    check(
        "Day 15/30, Spent 500/Budget 1000 -> on_pace",
        compute_spending_pace(500, 1000, 15, 30)["status"] == "on_pace",
        f"got {compute_spending_pace(500, 1000, 15, 30)}",
    )
    check(
        "Day 20/30, Spent 500/Budget 1000 -> ahead",
        compute_spending_pace(500, 1000, 20, 30)["status"] == "ahead",
        f"got {compute_spending_pace(500, 1000, 20, 30)}",
    )
    check(
        "Day 10/30, Spent 700/Budget 1000 -> too_fast",
        compute_spending_pace(700, 1000, 10, 30)["status"] == "too_fast",
        f"got {compute_spending_pace(700, 1000, 10, 30)}",
    )
    check(
        "No budget -> null",
        compute_spending_pace(500, 0, 15, 30) is None,
        f"got {compute_spending_pace(500, 0, 15, 30)}",
    )
    check(
        "Over budget: Spent 1200/Budget 1000 (120%), Day 15/30 -> too_fast, not clamped",
        compute_spending_pace(1200, 1000, 15, 30)["status"] == "too_fast"
        and compute_spending_pace(1200, 1000, 15, 30)["difference"] == 0.7,
        f"got {compute_spending_pace(1200, 1000, 15, 30)}",
    )
    check(
        "Confidence is always high",
        compute_spending_pace(500, 1000, 15, 30)["confidence"] == "high",
        f"got {compute_spending_pace(500, 1000, 15, 30)}",
    )
    check(
        "totalDays == 0 -> null, not a division error",
        compute_spending_pace(500, 1000, 15, 0) is None,
        f"got {compute_spending_pace(500, 1000, 15, 0)}",
    )

    print()
    print("Recovery Plan — edge cases")

    def rp(category_remaining, days_remaining, total_budget, total_days, rds, pace):
        return compute_recovery_plan(category_remaining, days_remaining, total_budget, total_days, rds, pace)

    check(
        "Normal month (on pace, no exhausted, no significant drop) -> null",
        rp(
            {"Food": {"limit": 1000, "remaining": 500, "spent": 500}},
            15, 1000, 30,
            {"value": 33.33, "confidence": "medium"},
            {"difference": 0.0, "status": "on_pace", "confidence": "high"},
        ) is None,
    )
    check(
        "Spending Pace too_fast -> plan exists, minor severity (no category exhausted)",
        rp(
            {"Food": {"limit": 1000, "remaining": 300, "spent": 700}},
            10, 1000, 30,
            {"value": 30.0, "confidence": "medium"},
            {"difference": 0.3, "status": "too_fast", "confidence": "high"},
        ) == {
            "needed": True, "dailyTarget": 30, "durationDays": 10,
            "affectedCategories": [], "severity": "minor",
            "recoveryPossible": True, "confidence": "medium",
        },
    )
    check(
        "One budgeted category exhausted -> plan exists, medium severity",
        rp(
            {
                "Food": {"limit": 1000, "remaining": 0, "spent": 1000},
                "Transport": {"limit": 500, "remaining": 200, "spent": 300},
            },
            10, 1500, 30,
            {"value": 20.0, "confidence": "medium"},
            {"difference": 0.0, "status": "on_pace", "confidence": "high"},
        ) == {
            "needed": True, "dailyTarget": 20, "durationDays": 10,
            "affectedCategories": ["Food"], "severity": "medium",
            "recoveryPossible": True, "confidence": "medium",
        },
    )
    check(
        "No budgets at all (recommendedDailySpend is None) -> null",
        rp({}, 10, 0, 30, None, None) is None,
    )
    check(
        "Last day of the month (daysRemaining<=1) -> null regardless of triggers",
        rp(
            {"Food": {"limit": 1000, "remaining": 100, "spent": 900}},
            1, 1000, 30,
            {"value": 100.0, "confidence": "medium"},
            {"difference": 0.5, "status": "too_fast", "confidence": "high"},
        ) is None,
    )
    check(
        "Two or more budgeted categories exhausted -> high severity",
        rp(
            {
                "Food": {"limit": 1000, "remaining": 0, "spent": 1000},
                "Transport": {"limit": 500, "remaining": 0, "spent": 500},
                "Shopping": {"limit": 300, "remaining": 100, "spent": 200},
            },
            10, 1800, 30,
            {"value": 10.0, "confidence": "medium"},
            {"difference": 0.0, "status": "on_pace", "confidence": "high"},
        )["severity"] == "high",
    )
    check(
        "Every budgeted category exhausted -> high severity, recoveryPossible False, dailyTarget 0",
        rp(
            {"Food": {"limit": 1000, "remaining": 0, "spent": 1000}},
            10, 1000, 30,
            {"value": 0.0, "confidence": "medium"},
            {"difference": 0.0, "status": "on_pace", "confidence": "high"},
        ) == {
            "needed": True, "dailyTarget": 0, "durationDays": 10,
            "affectedCategories": ["Food"], "severity": "high",
            "recoveryPossible": False, "confidence": "medium",
        },
    )
    check(
        "Recommended Daily Spend significantly below baseline (no exhausted, not too_fast) -> plan exists",
        rp(
            {"Food": {"limit": 1000, "remaining": 100, "spent": 900}},
            20, 1000, 30,
            {"value": 5.0, "confidence": "medium"},
            {"difference": 0.02, "status": "on_pace", "confidence": "high"},
        ) is not None,
    )

    print()
    print("Category Pressure — edge cases")

    check(
        "Perfect pace (budget progress == time progress) -> normal",
        compute_category_pressure(
            {"Food": {"limit": 1000, "spent": 500}}, 15, 30, 1000
        )["byCategory"]["Food"]["status"] == "normal",
    )
    check(
        "Ahead (budget progress well below time progress) -> low",
        compute_category_pressure(
            {"Food": {"limit": 1000, "spent": 200}}, 15, 30, 1000
        )["byCategory"]["Food"]["status"] == "low",
    )
    check(
        "Behind (budget progress well above time progress) -> high",
        compute_category_pressure(
            {"Food": {"limit": 1000, "spent": 900}}, 15, 30, 1000
        )["byCategory"]["Food"]["status"] == "high",
    )
    check(
        "Over budget -> high, not clamped",
        compute_category_pressure(
            {"Food": {"limit": 1000, "spent": 1500}}, 15, 30, 1000
        )["byCategory"]["Food"] == {
            "pressure": 1.0, "status": "high", "confidence": "high", "material": True,
        },
    )
    check(
        "No budget set at all -> null",
        compute_category_pressure({"Food": {"limit": 0, "spent": 0}}, 15, 30, 0) is None,
    )
    check(
        "Multiple categories: independent calculations + priorityOrder ranks highest pressure first",
        compute_category_pressure(
            {
                "Food": {"limit": 1000, "spent": 900},
                "Transport": {"limit": 1000, "spent": 200},
            },
            15, 30, 2000,
        ) == {
            "byCategory": {
                "Food": {"pressure": 0.4, "status": "high", "confidence": "high", "material": True},
                "Transport": {"pressure": -0.3, "status": "low", "confidence": "high", "material": True},
            },
            "priorityOrder": ["Food", "Transport"],
        },
    )
    check(
        "Materiality threshold: a category under HEALTH_MATERIALITY_THRESHOLD of totalBudget is not material",
        compute_category_pressure(
            {"Entertainment": {"limit": 100, "spent": 105}}, 15, 30, 5000
        )["byCategory"]["Entertainment"]["material"] is False,
        f"got {compute_category_pressure({'Entertainment': {'limit': 100, 'spent': 105}}, 15, 30, 5000)}",
    )
    check(
        "Materiality threshold: a category at/above HEALTH_MATERIALITY_THRESHOLD of totalBudget is material",
        compute_category_pressure(
            {"Food": {"limit": 300, "spent": 100}}, 15, 30, 5000
        )["byCategory"]["Food"]["material"] is True,
        f"got {compute_category_pressure({'Food': {'limit': 300, 'spent': 100}}, 15, 30, 5000)}",
    )

    print()
    print("Projected Savings — edge cases")

    def pace(budget_progress, time_progress):
        return {
            "difference": budget_progress - time_progress,
            "status": "on_pace",
            "confidence": "high",
            "budgetProgress": budget_progress,
            "timeProgress": time_progress,
        }

    check(
        "Spending exactly on pace -> value == savingsPool exactly",
        compute_projected_savings(pace(0.5, 0.5), 1000, 500)["value"] == 500,
        f"got {compute_projected_savings(pace(0.5, 0.5), 1000, 500)}",
    )
    check(
        "Spending faster than pace -> value decreases below savingsPool",
        compute_projected_savings(pace(0.7, 0.5), 1000, 500)["value"] < 500,
        f"got {compute_projected_savings(pace(0.7, 0.5), 1000, 500)}",
    )
    check(
        "Spending slower than pace -> value increases above savingsPool",
        compute_projected_savings(pace(0.3, 0.5), 1000, 500)["value"] > 500,
        f"got {compute_projected_savings(pace(0.3, 0.5), 1000, 500)}",
    )
    check(
        "No budgets at all (spendingPace is None) -> null",
        compute_projected_savings(None, 0, 500) is None,
        f"got {compute_projected_savings(None, 0, 500)}",
    )
    check(
        "Overspent month -> value can go negative, not clamped",
        compute_projected_savings(pace(1.5, 0.5), 1000, 500)["value"] == -1500,
        f"got {compute_projected_savings(pace(1.5, 0.5), 1000, 500)}",
    )
    check(
        "First day of the month (small timeProgress) -> confidence low",
        compute_projected_savings(pace(0.03, 1 / 30), 1000, 500)["confidence"] == "low",
        f"got {compute_projected_savings(pace(0.03, 1 / 30), 1000, 500)}",
    )
    check(
        "Last day of the month (timeProgress==1.0) -> confidence medium, "
        "value converges to savingsPool + remainingBudget",
        compute_projected_savings(pace(0.8, 1.0), 1000, 500) == {
            "value": 700.0, "confidence": "medium", "assumption": "current_spending_continues",
        },
        f"got {compute_projected_savings(pace(0.8, 1.0), 1000, 500)}",
    )
    check(
        "Confidence is never high",
        compute_projected_savings(pace(0.5, 0.5), 1000, 500)["confidence"] in ("low", "medium")
        and compute_projected_savings(pace(0.8, 1.0), 1000, 500)["confidence"] in ("low", "medium"),
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Days Remaining scenarios passed.")


if __name__ == "__main__":
    run()
