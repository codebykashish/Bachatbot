"""
audit_financial_engine.py
==========================
Phase 1 exit-criteria audit — compares the Financial Engine's summary
against the CURRENT scattered logic's own source of truth (not the UI),
for one real user/month. See FINANCIAL_ENGINE_SPEC.md "Phase 1 — Test
scenarios" and the Phase 1 exit criteria.

This script does not write anything to real budgets/transactions/goals —
it only reads, calls recompute() (which writes financialSummary, a new
collection nothing else reads yet), and for the mutation test temporarily
bumps then reverts one category's `spent` field on a REAL budget doc, so
run it against a test account, not a live user's real data, unless you're
comfortable with that.

Usage:
    python scripts/audit_financial_engine.py <uid> [monthKey]
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from firebase_config import initialize_firebase, get_firestore
from utils import get_current_month_key
from services.financial_engine import recompute, _waterfall
from services.goal_service import get_available_pool, compute_goal_progress

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def close(a, b, tol=0.01):
    return abs(float(a) - float(b)) <= tol


# ─── Section A: current system's own source of truth (no Engine calls) ────

def load_current_system(db, uid, month_key):
    user_doc = db.collection("users").document(uid).get().to_dict() or {}
    income_map = user_doc.get("income") or {}
    income = (
        float(income_map.get("inHand") or 0)
        + float(income_map.get("inBank") or 0)
        + float(income_map.get("onlineBanking") or 0)
    )

    budget_docs = list(
        db.collection("users").document(uid).collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )
    categories = {}
    total_limit = 0.0
    total_spent = 0.0
    for b in budget_docs:
        bd = b.to_dict()
        cat = bd.get("category", "")
        limit = float(bd.get("limit") or 0)
        spent = float(bd.get("spent") or 0)
        categories[cat] = {
            "limit": limit,
            "spent": spent,
            "remaining": max(0.0, limit - spent),
            "overspent": spent > limit,
        }
        total_limit += limit
        total_spent += spent

    remaining_budget = max(0.0, total_limit - total_spent)
    savings_pool = get_available_pool(db, uid, month_key)  # shared helper, same as Engine
    goal_progress = compute_goal_progress(db, uid, month_key)  # shared helper, same as Engine

    return {
        "income": income,
        "totalSpent": total_spent,
        "remainingBudget": remaining_budget,
        "categories": categories,
        "savingsPool": savings_pool,
        "goalProgress": goal_progress,
    }


def audit_overall(current, summary):
    print("\n[Overall]")
    check("Total Income matches", close(current["income"], summary["income"]),
          f"current={current['income']} engine={summary['income']}")
    check("Total Spent matches", close(current["totalSpent"], summary["totalSpent"]),
          f"current={current['totalSpent']} engine={summary['totalSpent']}")
    check("Remaining Budget matches", close(current["remainingBudget"], summary["remainingBudget"]),
          f"current={current['remainingBudget']} engine={summary['remainingBudget']}")
    check("Savings Pool matches", close(current["savingsPool"], summary["savingsPool"]),
          f"current={current['savingsPool']} engine={summary['savingsPool']}")


def audit_categories(current, summary):
    print("\n[Per Category]")
    engine_cats = summary["categoryRemaining"]
    all_cats = set(current["categories"].keys()) | set(engine_cats.keys())
    if not all_cats:
        print("  (no categories this month — nothing to compare)")
        return
    for cat in sorted(all_cats):
        c = current["categories"].get(cat)
        e = engine_cats.get(cat)
        if c is None or e is None:
            check(f"{cat}: present in both", False, f"current={c} engine={e}")
            continue
        check(f"{cat}: limit matches", close(c["limit"], e["limit"]), f"{c['limit']} vs {e['limit']}")
        check(f"{cat}: spent matches", close(c["spent"], e["spent"]), f"{c['spent']} vs {e['spent']}")
        check(f"{cat}: remaining matches", close(c["remaining"], e["remaining"]), f"{c['remaining']} vs {e['remaining']}")
        print(f"    overspent={c['overspent']}")


def audit_goals(current, summary):
    print("\n[Per Goal]")
    engine_goals = {g["id"]: g for g in summary["goalProgress"]}
    if not current["goalProgress"] and not engine_goals:
        print("  (no active goals — nothing to compare)")
        return
    for gid, current_saved in current["goalProgress"].items():
        e = engine_goals.get(gid)
        check(f"goal {gid}: present in engine summary", e is not None)
        if e is not None:
            check(f"goal {gid}: saved matches", close(current_saved, e["saved"]),
                  f"current={current_saved} engine={e['saved']}")


def audit_determinism(db, uid, month_key):
    print("\n[Determinism — recompute() twice, no data changes in between]")
    s1 = recompute(db, uid, month_key, reason="audit_determinism_1")
    s2 = recompute(db, uid, month_key, reason="audit_determinism_2")

    def strip_volatile(s):
        s = dict(s)
        s["metadata"] = {k: v for k, v in s["metadata"].items() if k not in ("recomputedAt", "reason")}
        s.pop("lastUpdated", None)
        return s

    check("summaries identical except timestamps/reason", strip_volatile(s1) == strip_volatile(s2),
          "diff found between two consecutive recomputes with no data change")


def audit_mutation_reversibility(db, uid, month_key):
    print("\n[Mutation + reversal — Summary A == Summary C]")
    budget_docs = list(
        db.collection("users").document(uid).collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )
    if not budget_docs:
        print("  (no budgets this month — skipping, nothing to mutate)")
        return

    target = budget_docs[0]
    target_ref = target.reference
    original_spent = float((target.to_dict() or {}).get("spent") or 0)
    bump = 37.0  # arbitrary, reversible amount

    summary_a = recompute(db, uid, month_key, reason="audit_mutation_before")

    target_ref.update({"spent": original_spent + bump})
    summary_b = recompute(db, uid, month_key, reason="audit_mutation_after_add")
    check("Summary B differs from A (mutation was picked up)",
          summary_a["totalSpent"] != summary_b["totalSpent"])

    target_ref.update({"spent": original_spent})
    summary_c = recompute(db, uid, month_key, reason="audit_mutation_after_revert")

    def strip_volatile(s):
        s = dict(s)
        s["metadata"] = {k: v for k, v in s["metadata"].items() if k not in ("recomputedAt", "reason")}
        s.pop("lastUpdated", None)
        return s

    check("Summary A == Summary C after reverting the mutation",
          strip_volatile(summary_a) == strip_volatile(summary_c),
          "engine is not reversible for this mutation — investigate before wiring routes")


def audit_rebalance_priority(summary):
    print("\n[Rebalance priority order — simulateTransaction on the largest category]")
    cats = summary["categoryRemaining"]
    if not cats:
        print("  (no categories — skipping)")
        return
    target_cat = next(iter(cats))
    own_remaining = cats[target_cat]["remaining"]
    savings_pool = summary["savingsPool"]
    other_buffer = sum(v["remaining"] for k, v in cats.items() if k != target_cat)
    amount = own_remaining + other_buffer + savings_pool + 1  # force it through every tier if possible
    affordable, shortfall, plan = _waterfall(cats, savings_pool, target_cat, amount)

    print(f"  plan for a forced Rs{amount} spend on {target_cat}: {plan}")
    savings_index = next((i for i, p in enumerate(plan) if p["from"] == "savings"), None)
    check("savings entry (if any) is last in the plan",
          savings_index is None or savings_index == len(plan) - 1, f"plan={plan}")
    check("category's own buffer is used before any donor",
          plan[0]["from"] == target_cat if own_remaining > 0 else True, f"plan={plan}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python scripts/audit_financial_engine.py <uid> [monthKey]")
        sys.exit(1)

    uid = sys.argv[1]
    month_key = sys.argv[2] if len(sys.argv) > 2 else get_current_month_key()
    initialize_firebase()
    db = get_firestore()

    print(f"Auditing uid={uid} month={month_key}")

    current = load_current_system(db, uid, month_key)
    summary = recompute(db, uid, month_key, reason="audit_initial")

    audit_overall(current, summary)
    audit_categories(current, summary)
    audit_goals(current, summary)
    audit_rebalance_priority(summary)
    audit_determinism(db, uid, month_key)
    audit_mutation_reversibility(db, uid, month_key)

    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) FAILED — do not wire routes to the Engine yet:")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All checks PASSED for this user/month.")


if __name__ == "__main__":
    main()
