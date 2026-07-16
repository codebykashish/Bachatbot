"""
test_financial_engine.py
=========================
Phase 1 acceptance scenarios for the Financial Engine — see
FINANCIAL_ENGINE_SPEC.md "Phase 1 — Test scenarios." These check the pure
math (no Firestore needed): _validate, _calculate_budgets,
_calculate_savings, _waterfall. Goal-impact math (compute_goal_progress)
depends on live Firestore data and is verified separately against a real
account, not simulated here.

Run directly: python tests/test_financial_engine.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.financial_engine import _validate, _calculate_budgets, _calculate_savings, _waterfall

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def make_data(income, budget_pairs):
    """budget_pairs: list of (category, limit, spent)"""
    return {
        "income": income,
        "budgets": [
            {"_id": cat, "category": cat, "limit": limit, "spent": spent}
            for cat, limit, spent in budget_pairs
        ],
        "goals": [],
    }


def scenario_1_clean_state():
    print("\nScenario 1 — Clean state (no transactions)")
    data = make_data(20000, [
        ("Food", 6000, 0), ("Transport", 2000, 0),
        ("Entertainment", 2000, 0), ("Rent", 8000, 0),
    ])
    log = []
    data = _validate(data, log)
    category_remaining, total_limit, total_spent, remaining_budget = _calculate_budgets(data, log)
    savings_pool = _calculate_savings(data, total_limit, log)

    check("total_limit == 18000", total_limit == 18000, f"got {total_limit}")
    check("total_spent == 0", total_spent == 0, f"got {total_spent}")
    check("remaining_budget == 18000", remaining_budget == 18000, f"got {remaining_budget}")
    check("savings_pool == 2000", savings_pool == 2000, f"got {savings_pool}")
    for cat, limit, _ in [("Food", 6000, 0), ("Transport", 2000, 0), ("Entertainment", 2000, 0), ("Rent", 8000, 0)]:
        check(f"{cat} remaining == limit", category_remaining[cat]["remaining"] == limit)
    return category_remaining, savings_pool


def scenario_2_normal_spend():
    print("\nScenario 2 — Spend Rs500 on Food (within budget)")
    data = make_data(20000, [
        ("Food", 6000, 500), ("Transport", 2000, 0),
        ("Entertainment", 2000, 0), ("Rent", 8000, 0),
    ])
    log = []
    data = _validate(data, log)
    category_remaining, total_limit, total_spent, remaining_budget = _calculate_budgets(data, log)
    savings_pool = _calculate_savings(data, total_limit, log)

    check("Food remaining == 5500", category_remaining["Food"]["remaining"] == 5500,
          f"got {category_remaining['Food']['remaining']}")
    check("total_spent == 500", total_spent == 500, f"got {total_spent}")
    check("savings_pool unchanged (== 2000)", savings_pool == 2000, f"got {savings_pool}")
    check("other categories untouched",
          category_remaining["Transport"]["remaining"] == 2000
          and category_remaining["Entertainment"]["remaining"] == 2000
          and category_remaining["Rent"]["remaining"] == 8000)


def scenario_3_overspend_with_buffer():
    print("\nScenario 3 — Overspend Food by Rs300, other categories have buffer")
    category_remaining = {
        "Food": {"limit": 6000, "spent": 6000, "remaining": 0},
        "Transport": {"limit": 2000, "spent": 0, "remaining": 2000},
        "Entertainment": {"limit": 2000, "spent": 0, "remaining": 2000},
        "Rent": {"limit": 8000, "spent": 0, "remaining": 8000},
    }
    savings_pool = 2000

    affordable, shortfall, plan = _waterfall(category_remaining, savings_pool, "Food", 300)

    check("affordable == True", affordable is True)
    check("shortfall == 0", shortfall == 0, f"got {shortfall}")
    check("rebalancing happened (plan has a non-Food source)",
          any(p["from"] != "Food" for p in plan), f"plan={plan}")
    check("savings untouched (no 'savings' entry in plan)",
          not any(p["from"] == "savings" for p in plan), f"plan={plan}")


def scenario_4_everything_exhausted():
    print("\nScenario 4 — Every category exhausted, spend again")
    category_remaining = {
        "Food": {"limit": 6000, "spent": 6000, "remaining": 0},
        "Transport": {"limit": 2000, "spent": 2000, "remaining": 0},
        "Entertainment": {"limit": 2000, "spent": 2000, "remaining": 0},
        "Rent": {"limit": 8000, "spent": 8000, "remaining": 0},
    }
    savings_pool = 2000

    affordable, shortfall, plan = _waterfall(category_remaining, savings_pool, "Food", 500)

    check("affordable == True (savings covers it)", affordable is True)
    check("shortfall == 0", shortfall == 0, f"got {shortfall}")
    check("savings used for the full amount",
          any(p["from"] == "savings" and p["amount"] == 500 for p in plan), f"plan={plan}")
    print("  [NOTE] Goal-progress reduction from this savings use is computed live by "
          "compute_goal_progress() against the Savings Pool — verify against a real "
          "account with an active goal; not simulated here since it requires Firestore.")


def scenario_4b_insufficient_everywhere():
    print("\nScenario 4b — Every category AND savings exhausted, spend again")
    category_remaining = {
        "Food": {"limit": 6000, "spent": 6000, "remaining": 0},
    }
    savings_pool = 0

    affordable, shortfall, plan = _waterfall(category_remaining, savings_pool, "Food", 500)

    check("affordable == False", affordable is False)
    check("shortfall == 500", shortfall == 500, f"got {shortfall}")
    check("plan is empty (nothing to draw from)", plan == [], f"plan={plan}")


if __name__ == "__main__":
    scenario_1_clean_state()
    scenario_2_normal_spend()
    scenario_3_overspend_with_buffer()
    scenario_4_everything_exhausted()
    scenario_4b_insufficient_everywhere()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) FAILED:")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All scenarios PASSED.")
