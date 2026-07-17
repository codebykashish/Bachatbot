"""
financial_engine.py
====================
The Financial Engine — Phase 1 (Core Money Engine). See
backend/FINANCIAL_ENGINE_SPEC.md for the full contract this file
implements; this module must not drift from that spec without a deliberate
Phase 0 revision first.

Public API (spec Section 0) — everything else in this module is a private
helper and must never be imported/called directly by other code:

    recompute(db, uid, month_key=None, reason="manual")
    get_summary(db, uid, month_key=None)
    simulate_transaction(db, uid, category, amount, month_key=None)
    validate_transaction(db, uid, category, amount, month_key=None)
"""

import logging
import time
import uuid

from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from utils import get_current_month_key, sum_category_expense
from services.goal_service import get_active_goals, compute_goal_progress

logger = logging.getLogger(__name__)

ENGINE_VERSION = 1
SUMMARY_SCHEMA_VERSION = 1


class RecomputeReason:
    """
    Standard reason codes for recompute() calls — spec Section "Standard
    reason codes." Routes must use one of these, never a hand-typed string,
    so logs/decisionLogs stay analyzable across the whole app.
    """
    MANUAL = "MANUAL"
    SUMMARY_MISSING = "SUMMARY_MISSING"
    INCOME_UPDATED = "INCOME_UPDATED"
    BUDGET_CREATED = "BUDGET_CREATED"
    BUDGET_UPDATED = "BUDGET_UPDATED"
    BUDGET_DELETED = "BUDGET_DELETED"
    GOAL_CREATED = "GOAL_CREATED"
    GOAL_UPDATED = "GOAL_UPDATED"
    GOAL_DELETED = "GOAL_DELETED"
    TRANSACTION_CREATED = "TRANSACTION_CREATED"
    TRANSACTION_CONFIRMED = "TRANSACTION_CONFIRMED"
    TRANSACTION_EDITED = "TRANSACTION_EDITED"
    TRANSACTION_DELETED = "TRANSACTION_DELETED"
    MONTH_ROLLOVER = "MONTH_ROLLOVER"


# ─── Pipeline: Load Data ───────────────────────────────────────────────────

def _load_data(db, uid: str, month_key: str) -> dict:
    """
    Raw inputs only — income, budgets (limits only), confirmed transactions
    (via sum_category_expense), active goals. No derived values.

    Ground Truth Principle (spec Section 8): a budget's `spent` is not read
    from the stored counter on the budget document — that counter is
    derived data historically hand-maintained by scattered Increment()
    calls, which is exactly the drift/edit/delete bug the Transactions
    migration exists to eliminate. Instead, `spent` is summed fresh from
    confirmed, non-deleted transactions every recompute, so an edited or
    deleted transaction is reflected correctly with no special-case
    reversal logic anywhere.
    """
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
    budgets = []
    for b in budget_docs:
        bd = b.to_dict() or {}
        category = bd.get("category", "")
        budgets.append({
            "_id": b.id,
            "category": category,
            "limit": float(bd.get("limit") or 0),
            "spent": sum_category_expense(db, uid, category, month_key),
        })

    goals = get_active_goals(db, uid)

    return {"income": income, "budgets": budgets, "goals": goals}


# ─── Pipeline: Validate ────────────────────────────────────────────────────

def _validate(data: dict, decision_log: list) -> dict:
    if data["income"] < 0:
        decision_log.append("Negative income encountered — treated as 0.")
        data["income"] = 0.0
    for b in data["budgets"]:
        if b["limit"] < 0:
            decision_log.append(f"Negative limit on {b['category']} — treated as 0.")
            b["limit"] = 0.0
        if b["spent"] < 0:
            decision_log.append(f"Negative spent on {b['category']} — treated as 0.")
            b["spent"] = 0.0
    return data


# ─── Pipeline: Calculate Budgets ───────────────────────────────────────────

def _calculate_budgets(data: dict, decision_log: list):
    category_remaining = {}
    total_limit = 0.0
    total_spent = 0.0
    for b in data["budgets"]:
        remaining = max(0.0, b["limit"] - b["spent"])
        category_remaining[b["category"]] = {
            "limit": b["limit"],
            "spent": b["spent"],
            "remaining": remaining,
        }
        total_limit += b["limit"]
        total_spent += b["spent"]

    remaining_budget = max(0.0, total_limit - total_spent)
    decision_log.append(
        f"Budgets calculated — total limit Rs{total_limit:.2f}, "
        f"total spent Rs{total_spent:.2f}, remaining Rs{remaining_budget:.2f}."
    )
    return category_remaining, total_limit, total_spent, remaining_budget


# ─── Pipeline: Calculate Savings ───────────────────────────────────────────

def _calculate_savings(data: dict, total_limit: float, decision_log: list) -> float:
    savings_pool = max(0.0, data["income"] - total_limit)
    decision_log.append(
        f"Savings Pool = Rs{data['income']:.2f} income - "
        f"Rs{total_limit:.2f} allocated = Rs{savings_pool:.2f}."
    )
    return savings_pool


# ─── Pipeline: Apply Rebalancing ───────────────────────────────────────────

def _apply_rebalancing(decision_log: list) -> dict:
    """
    Phase 1 note: the category -> other-categories -> savings waterfall is
    still applied at commit time by the existing routes (chat.py,
    transactions.py, confirm.py, routes/budgets.py), which persist the
    result directly into each budget's limit/spent. By the time recompute
    runs, categoryRemaining already reflects any rebalance that already
    happened, so this step is a pass-through today. It stays a named
    pipeline step so that once those routes are migrated to call the Engine
    instead of doing their own math, there is an obvious place to plug the
    real waterfall in without reshaping the pipeline.
    """
    decision_log.append("No rebalance applied by recompute (already committed at transaction time).")
    return {"moved": []}


# ─── Pipeline: Calculate Goal Impact ───────────────────────────────────────

def _calculate_goal_impact(db, uid: str, month_key: str, data: dict, savings_pool: float, decision_log: list) -> list:
    if not data["goals"]:
        decision_log.append("No active goals.")
        return []

    progress = compute_goal_progress(db, uid, month_key)
    goal_progress = []
    for g in data["goals"]:
        target = float(g.get("targetAmount") or 0)
        months = int(g.get("timeframeMonths") or 1)
        saved = progress.get(g["_id"], 0.0)
        goal_progress.append({
            "id": g["_id"],
            "name": g.get("name", "Goal"),
            "priority": int(g.get("priority") or 1),
            "targetAmount": target,
            "timeframeMonths": months,
            "saved": saved,                 # kept for internal/audit use
            "savedSoFar": saved,             # alias — what the API response uses
            "remaining": max(0.0, target - saved),
            "percent": round(min(100, (saved / target) * 100), 1) if target > 0 else 0,
            "percentComplete": round(min(100, (saved / target) * 100), 1) if target > 0 else 0,
            "monthlyTarget": round(target / months, 2) if months > 0 else 0,
            "status": "completed" if saved >= target and target > 0 else g.get("status", "active"),
        })
    decision_log.append(
        f"Computed progress for {len(goal_progress)} active goal(s) "
        f"against Savings Pool Rs{savings_pool:.2f}."
    )
    return goal_progress


# ─── Pipeline: Build + Save Summary ────────────────────────────────────────

def _build_summary(data, category_remaining, total_spent, remaining_budget,
                    savings_pool, rebalance_result, goal_progress, reason,
                    decision_log, recompute_id, duration_ms) -> dict:
    return {
        "income": data["income"],
        "totalSpent": total_spent,
        "remainingBudget": remaining_budget,
        "categoryRemaining": category_remaining,
        "savingsPool": savings_pool,
        "goalProgress": goal_progress,
        "rebalanceResult": rebalance_result,
        "metadata": {
            "version": SUMMARY_SCHEMA_VERSION,
            "engineVersion": ENGINE_VERSION,
            "recomputeId": recompute_id,
            "reason": reason,
            "durationMs": duration_ms,
            "decisionLog": decision_log,
        },
    }


def _save_summary(db, uid: str, month_key: str, summary: dict):
    ref = (
        db.collection("users").document(uid)
        .collection("financialSummary").document(month_key)
    )
    payload = dict(summary)
    payload["metadata"] = dict(summary["metadata"])
    payload["metadata"]["recomputedAt"] = SERVER_TIMESTAMP
    payload["lastUpdated"] = SERVER_TIMESTAMP
    ref.set(payload)
    return ref


# ═══════════════════════════════════════════════════════════════════════════
# Public API — spec Section 0. Nothing above this line is called by other
# modules directly.
# ═══════════════════════════════════════════════════════════════════════════

def recompute(db, uid: str, month_key: str = None, reason: str = RecomputeReason.MANUAL) -> dict:
    """
    Rebuilds users/{uid}/financialSummary/{monthKey} from raw data. The
    only operation allowed to write to financialSummary (spec Section 4).
    """
    month_key = month_key or get_current_month_key()
    recompute_id = uuid.uuid4().hex[:12]
    started_at = time.perf_counter()
    decision_log = []

    data = _load_data(db, uid, month_key)
    decision_log.append(
        f"Loaded data for {uid}/{month_key}: income Rs{data['income']:.2f}, "
        f"{len(data['budgets'])} budget(s), {len(data['goals'])} active goal(s)."
    )

    data = _validate(data, decision_log)
    category_remaining, total_limit, total_spent, remaining_budget = _calculate_budgets(data, decision_log)
    savings_pool = _calculate_savings(data, total_limit, decision_log)
    rebalance_result = _apply_rebalancing(decision_log)
    goal_progress = _calculate_goal_impact(db, uid, month_key, data, savings_pool, decision_log)

    duration_ms = round((time.perf_counter() - started_at) * 1000, 2)
    summary = _build_summary(
        data, category_remaining, total_spent, remaining_budget,
        savings_pool, rebalance_result, goal_progress, reason, decision_log,
        recompute_id, duration_ms,
    )
    _save_summary(db, uid, month_key, summary)
    logger.info(f"[ENGINE] recompute id={recompute_id} uid={uid} month={month_key} reason={reason} duration={duration_ms}ms")
    return summary


def get_summary(db, uid: str, month_key: str = None) -> dict:
    """
    Returns the current financialSummary — the only way anything reads
    calculated values (spec Section 0). Self-heals by recomputing if no
    summary exists yet (e.g. first call for a brand-new month).
    """
    month_key = month_key or get_current_month_key()
    doc = (
        db.collection("users").document(uid)
        .collection("financialSummary").document(month_key).get()
    )
    if not doc.exists:
        return recompute(db, uid, month_key, reason=RecomputeReason.SUMMARY_MISSING)
    return doc.to_dict()


def _waterfall(category_remaining: dict, savings_pool: float, category: str, amount: float):
    """
    Pure hypothetical waterfall: the category's own buffer first, then other
    categories' buffer (largest remaining first), then the Savings Pool as
    last resort — the Money Priority Rule (spec Section 1). No writes.
    Returns (affordable, shortfall, plan).
    """
    plan = []
    remaining_need = amount

    own_remaining = category_remaining.get(category, {}).get("remaining", 0.0)
    use_own = min(own_remaining, remaining_need)
    if use_own > 0:
        plan.append({"from": category, "amount": round(use_own, 2)})
        remaining_need -= use_own

    if remaining_need > 0:
        donors = sorted(
            (item for item in category_remaining.items() if item[0] != category),
            key=lambda item: item[1].get("remaining", 0.0),
            reverse=True,
        )
        for donor_category, donor in donors:
            if remaining_need <= 0:
                break
            avail = donor.get("remaining", 0.0)
            if avail <= 0:
                continue
            use = min(avail, remaining_need)
            plan.append({"from": donor_category, "amount": round(use, 2)})
            remaining_need -= use

    if remaining_need > 0 and savings_pool > 0:
        use = min(savings_pool, remaining_need)
        plan.append({"from": "savings", "amount": round(use, 2)})
        remaining_need -= use

    affordable = remaining_need <= 0.0001
    return affordable, max(0.0, round(remaining_need, 2)), plan


def validate_transaction(db, uid: str, category: str, amount: float, month_key: str = None) -> dict:
    """
    Fast affordability guard — enough combined category buffer + Savings
    Pool to cover this, without building the full hypothetical summary.
    """
    summary = get_summary(db, uid, month_key)
    affordable, shortfall, _ = _waterfall(
        summary["categoryRemaining"], summary["savingsPool"], category, amount,
    )
    return {"affordable": affordable, "shortfall": shortfall}


def simulate_transaction(db, uid: str, category: str, amount: float, month_key: str = None) -> dict:
    """
    Answers "what would happen if the user spends Rs X right now?" without
    committing anything (spec Section 0).
    """
    summary = get_summary(db, uid, month_key)
    affordable, shortfall, plan = _waterfall(
        summary["categoryRemaining"], summary["savingsPool"], category, amount,
    )

    savings_used = next((p["amount"] for p in plan if p["from"] == "savings"), 0.0)
    goals_affected = (
        [g["name"] for g in summary["goalProgress"] if g["saved"] > 0]
        if savings_used > 0 else []
    )

    return {
        "affordable": affordable,
        "shortfall": shortfall,
        "plan": plan,
        "savingsUsed": savings_used,
        "goalsAffected": goals_affected,
    }
