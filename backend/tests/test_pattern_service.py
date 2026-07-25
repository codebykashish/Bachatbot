"""
test_pattern_service.py
==========================
Phase 17 acceptance scenarios for Pattern Spending Alerts — see
FINANCIAL_ENGINE_SPEC.md's "Phase 17 — Pattern Spending Alerts —
Design, FROZEN." Tests the pure decision core (_detect_anomaly,
_baseline_average, _daily_totals) directly against plain dicts —
no Firestore needed — the same convention test_financial_engine.py
uses for its own pure pipeline stages.

Run directly: python tests/test_pattern_service.py
"""

import sys
import os
from datetime import date, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import pattern_service as ps

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


TODAY = date(2026, 7, 22)


def days_back(n):
    return TODAY - timedelta(days=n)


def run():
    print("Pattern Service — test matrix")

    # 1. Fewer than the minimum trust threshold -- no anomaly possible,
    # even if today's spending would otherwise look enormous.
    daily_totals = {TODAY: 5000.0, days_back(1): 100.0}
    result1 = ps._detect_anomaly(daily_totals, TODAY, expense_count=2)
    check(
        "Fewer than 5 logged expenses ever -- no anomaly, not enough trust yet",
        result1 is None,
        f"got {result1}",
    )

    # 2. Enough history, but today's spending is normal (not 2x baseline)
    daily_totals2 = {TODAY: 220.0}
    for i in range(1, 11):
        daily_totals2[days_back(i)] = 200.0
    result2 = ps._detect_anomaly(daily_totals2, TODAY, expense_count=11)
    check(
        "Today's spending close to baseline -- no anomaly",
        result2 is None,
        f"got {result2}",
    )

    # 3. Enough history, today is a genuine 2x+ anomaly
    daily_totals3 = {TODAY: 500.0}
    for i in range(1, 11):
        daily_totals3[days_back(i)] = 200.0
    result3 = ps._detect_anomaly(daily_totals3, TODAY, expense_count=11)
    check(
        "Today at 2.5x baseline (Rs 500 vs Rs 200) IS a genuine anomaly",
        result3 is not None and result3["todayTotal"] == 500 and result3["baselineAverage"] == 200,
        f"got {result3}",
    )
    check(
        "Suggested daily amount spreads the overage over 3 days, never negative",
        result3 is not None and result3["suggestedDailyAmount"] == round(200 - (500 - 200) / 3),
        f"got {result3}",
    )
    check(
        "durationDays is the frozen 3-day correction window",
        result3 is not None and result3["durationDays"] == 3,
        f"got {result3}",
    )

    # 4. No spending logged today at all -- nothing to flag
    daily_totals4 = {days_back(i): 200.0 for i in range(1, 11)}
    result4 = ps._detect_anomaly(daily_totals4, TODAY, expense_count=10)
    check(
        "No spending today -- no anomaly (nothing to compare)",
        result4 is None,
        f"got {result4}",
    )

    # 5. Sparse category (fewer than 8 spending-days within the 30-day
    # window) still gets a baseline via the 10-spending-day fallback,
    # rather than being starved entirely.
    daily_totals5 = {TODAY: 1000.0, days_back(40): 100.0, days_back(45): 100.0,
                      days_back(50): 100.0, days_back(55): 100.0, days_back(60): 100.0}
    result5 = ps._detect_anomaly(daily_totals5, TODAY, expense_count=6)
    check(
        "Sparse category (spending-days older than 30 days) still gets a fallback baseline",
        result5 is not None and result5["baselineAverage"] == 100,
        f"got {result5}",
    )

    # 6. _baseline_average itself: window with >=8 spending-days in the
    # last 30 days uses ONLY that window, ignoring older/sparser history.
    daily_totals6 = {days_back(i): 200.0 for i in range(1, 9)}
    daily_totals6[days_back(50)] = 999999.0  # far outside the window, must be ignored
    baseline6 = ps._baseline_average(daily_totals6, TODAY)
    check(
        "30-day window with >=8 spending-days ignores older history entirely",
        baseline6 == 200.0,
        f"got {baseline6}",
    )

    # 7. _daily_totals groups multiple same-day transactions correctly.
    class FakeTs:
        def __init__(self, d):
            self._d = d
            self.tzinfo = None
        def date(self):
            return self._d
        def replace(self, tzinfo=None):
            self.tzinfo = tzinfo
            return self

    expenses = [
        {"amount": 100.0, "createdAt": FakeTs(TODAY)},
        {"amount": 150.0, "createdAt": FakeTs(TODAY)},
        {"amount": 50.0, "createdAt": FakeTs(days_back(1))},
    ]
    totals7 = ps._daily_totals(expenses)
    check(
        "Multiple same-day transactions sum into one daily total",
        totals7.get(TODAY) == 250.0 and totals7.get(days_back(1)) == 50.0,
        f"got {totals7}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Pattern Service scenarios passed.")


if __name__ == "__main__":
    run()
