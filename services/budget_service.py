"""
budget_service.py
=================
Month-rollover logic and reminder event helpers.

Month rollover (run at start of each new month via APScheduler):
  - For each user, for each budget category:
      new_budget.limit = sum of CONFIRMED expenses last month in that category
      (can be 0 — never left null)
  - Reset is NOT needed here for transactions; transactions are stored with
    monthKey so filtering by monthKey naturally gives the right month's data.
  - The budget.spent field is reset to 0 for the new month's budget document.
  - Fires a "new_month_started" event stored in Firestore.

Pre-month-end reminder (run 1–2 days before month end via APScheduler):
  - For each user, if budget_confirmed_for_month == False for next month:
      Fires a "pre_new_month_budget_reminder" event stored in Firestore.

Events are written as documents in:
  users/{uid}/events/{eventId}
  {
    "type": "new_month_started" | "pre_new_month_budget_reminder",
    "monthKey": "2026-06",
    "newBudgets": {"Food": 500, "Transport": 200, ...},  # for new_month_started
    "isRead": false,
    "createdAt": SERVER_TIMESTAMP,
  }

These documents are consumable by:
  - Push notification system (poll /events or use Firestore listener)
  - Chat/assistant system (check for unread events on next chat call)
"""

import calendar
import logging
from datetime import datetime, timezone

from firebase_config import get_firestore
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

logger = logging.getLogger("bachatbot.budget_service")


# ── Budget circulation / overspend rebalancing ────────────────────────────────

def _compute_rebalance_transfers(db, uid, overspent_category, overspend, month_key):
    """
    Pure computation — no writes. Figures out where the overspend amount
    would come from (savings first, then other categories' unused buffer,
    most-remaining-first). Returns a list of transfer dicts, or [] if
    nothing is available to pull from.
    """
    # ── Declared income ──────────────────────────────────────────────────────
    try:
        income_map = (
            db.collection("users").document(uid).get().to_dict() or {}
        ).get("income") or {}
        declared_income = (
            float(income_map.get("inHand") or 0)
            + float(income_map.get("inBank") or 0)
            + float(income_map.get("onlineBanking") or 0)
        )
    except Exception:
        declared_income = 0.0

    # ── All budgets this month ───────────────────────────────────────────────
    all_docs = list(
        db.collection("users").document(uid)
        .collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )
    all_budgets = [{"_id": d.id, **d.to_dict()} for d in all_docs]

    total_limits = sum(float(b.get("limit") or 0) for b in all_budgets)
    savings = max(0.0, declared_income - total_limits) if declared_income > 0 else 0.0

    remaining_gap = overspend
    transfers = []  # list of {"from": str, "amount": float, "_donor_id": str|None, "_donor_old_limit": float}

    # Step 1: take from other categories first, most remaining budget first.
    # Savings/goal money is protected — only touched as a last resort below.
    if remaining_gap > 0:
        donors = [b for b in all_budgets if b.get("category") != overspent_category]
        donors.sort(
            key=lambda b: float(b.get("limit") or 0) - float(b.get("spent") or 0),
            reverse=True,
        )
        for donor in donors:
            if remaining_gap <= 0:
                break
            avail = float(donor.get("limit") or 0) - float(donor.get("spent") or 0)
            if avail <= 0:
                continue
            use = min(avail, remaining_gap)
            transfers.append({
                "from": donor.get("category", ""),
                "amount": use,
                "_donor_id": donor["_id"],
                "_donor_old_limit": float(donor.get("limit") or 0),
            })
            remaining_gap -= use

    # Step 2: only if categories combined weren't enough, use savings.
    # If there are active savings goals, this pool is the same unallocated
    # income they draw from — flag it so the confirmation dialog can warn
    # the user this would eat into goal money, not just generic "savings".
    if savings > 0 and remaining_gap > 0:
        use = min(savings, remaining_gap)
        affects_goals = []
        try:
            from services.goal_service import get_active_goal_names
            affects_goals = get_active_goal_names(db, uid)
        except Exception:
            pass
        transfers.append({
            "from": "savings",
            "amount": use,
            "_donor_id": None,
            "_donor_old_limit": 0,
            "affectsGoals": affects_goals,
        })
        remaining_gap -= use

    return transfers, remaining_gap


def _build_rebalance_message(overspent_category, overspend, transfers, covered_fully, remaining_gap):
    parts = []
    for t in transfers:
        label = "savings" if t["from"] == "savings" else t["from"]
        parts.append(f"Rs {int(t['amount'])} from {label}")
    sources_desc = " + ".join(parts)

    if covered_fully:
        return (
            f"⚠️ {overspent_category} budget exceeded by Rs {int(overspend)}! "
            f"Auto-adjusted: {sources_desc} transferred to cover it."
        )
    return (
        f"⚠️ {overspent_category} budget exceeded by Rs {int(overspend)}! "
        f"{sources_desc} transferred — Rs {int(remaining_gap)} still uncovered."
    )


def rebalance_on_overspend(db, uid, overspent_category, new_spent, old_limit, budget_doc_id, month_key):
    """
    Called immediately after budget.spent is incremented and new_spent > old_limit.

    Does NOT write anything. Computes which categories (or savings) would
    cover the overspend and stores it as a pending_rebalance doc awaiting
    user confirmation — the actual budget-limit changes only happen once
    /confirm-rebalance/{id} is called.

    Returns a dict describing the pending rebalance, or None if there is
    nothing available to pull from (nothing to confirm).
    """
    overspend = new_spent - old_limit
    if overspend <= 0:
        return None

    transfers, remaining_gap = _compute_rebalance_transfers(
        db, uid, overspent_category, overspend, month_key
    )
    if not transfers:
        return None  # nothing to pull from

    total_covered = sum(t["amount"] for t in transfers)
    covered_fully = remaining_gap <= 0

    # ── Store as a pending rebalance — no budget writes yet ──────────────────
    pending_ref = db.collection("users").document(uid).collection("pending_rebalances").document()
    pending_ref.set({
        "status": "pending",
        "overspentCategory": overspent_category,
        "budgetDocId": budget_doc_id,
        "oldLimit": old_limit,
        "overspend": overspend,
        "totalCovered": total_covered,
        "coveredFully": covered_fully,
        "remainingGap": remaining_gap,
        "monthKey": month_key,
        "transfers": [
            {
                "from": t["from"],
                "amount": t["amount"],
                "donorId": t["_donor_id"],
                "donorOldLimit": t["_donor_old_limit"],
                "affectsGoals": t.get("affectsGoals", []),
            }
            for t in transfers
        ],
        "createdAt": SERVER_TIMESTAMP,
    })

    logger.info(
        f"[REBALANCE] uid={uid} {overspent_category} overspent Rs {overspend:.0f} — "
        f"pending confirmation id={pending_ref.id}"
    )

    return {
        "pending": True,
        "rebalanceId": pending_ref.id,
        "category": overspent_category,
        "overspend": overspend,
        "totalCovered": total_covered,
        "coveredFully": covered_fully,
        "transfers": [
            {"from": t["from"], "amount": t["amount"], "affectsGoals": t.get("affectsGoals", [])}
            for t in transfers
        ],
    }


def apply_pending_rebalance(db, uid, rebalance_id):
    """
    Confirms a pending rebalance: applies the previously computed budget
    changes (increase the overspent category, decrease donor categories)
    and creates the "budget_rebalanced" alert. Returns the result dict,
    or None if the rebalance was not found or already resolved.
    """
    pending_ref = db.collection("users").document(uid).collection("pending_rebalances").document(rebalance_id)
    doc = pending_ref.get()
    if not doc.exists:
        return None
    data = doc.to_dict()
    if data.get("status") != "pending":
        return None

    overspent_category = data["overspentCategory"]
    old_limit = data["oldLimit"]
    overspend = data["overspend"]
    total_covered = data["totalCovered"]
    covered_fully = data["coveredFully"]
    remaining_gap = data["remainingGap"]
    month_key = data["monthKey"]
    transfers = data["transfers"]
    new_limit = old_limit + total_covered

    db.collection("users").document(uid).collection("budgets").document(data["budgetDocId"]).update({
        "limit": new_limit,
        "updatedAt": SERVER_TIMESTAMP,
    })
    for t in transfers:
        if t["donorId"]:
            db.collection("users").document(uid).collection("budgets").document(t["donorId"]).update({
                "limit": t["donorOldLimit"] - t["amount"],
                "updatedAt": SERVER_TIMESTAMP,
            })

    msg = _build_rebalance_message(overspent_category, overspend, transfers, covered_fully, remaining_gap)

    try:
        db.collection("users").document(uid).collection("alerts").document().set({
            "type": "budget_rebalanced",
            "message": msg,
            "category": overspent_category,
            "severity": "high",
            "isRead": False,
            "isDeleted": False,
            "monthKey": month_key,
            "createdAt": SERVER_TIMESTAMP,
        })
    except Exception as e:
        logger.warning(f"[REBALANCE] alert creation failed: {e}")

    pending_ref.update({"status": "confirmed", "updatedAt": SERVER_TIMESTAMP})
    logger.info(f"[REBALANCE] uid={uid} confirmed id={rebalance_id} covered Rs {total_covered:.0f}")

    return {
        "overspend": overspend,
        "totalCovered": total_covered,
        "coveredFully": covered_fully,
        "newLimit": new_limit,
        "transfers": [{"from": t["from"], "amount": t["amount"]} for t in transfers],
        "message": msg,
    }


def reject_pending_rebalance(db, uid, rebalance_id):
    """
    Rejects a pending rebalance: no budget-limit changes are made anywhere.
    The overspent category simply stays over its limit. Creates an
    informational alert so the decision is still visible in Activity.
    Returns the alert info, or None if not found / already resolved.
    """
    pending_ref = db.collection("users").document(uid).collection("pending_rebalances").document(rebalance_id)
    doc = pending_ref.get()
    if not doc.exists:
        return None
    data = doc.to_dict()
    if data.get("status") != "pending":
        return None

    overspent_category = data["overspentCategory"]
    overspend = data["overspend"]
    month_key = data["monthKey"]

    msg = (
        f"{overspent_category} is Rs {int(overspend)} over budget. "
        f"No budget was moved from other categories."
    )

    try:
        db.collection("users").document(uid).collection("alerts").document().set({
            "type": "budget_overspent",
            "message": msg,
            "category": overspent_category,
            "severity": "medium",
            "isRead": False,
            "isDeleted": False,
            "monthKey": month_key,
            "createdAt": SERVER_TIMESTAMP,
        })
    except Exception as e:
        logger.warning(f"[REBALANCE] reject alert creation failed: {e}")

    pending_ref.update({"status": "rejected", "updatedAt": SERVER_TIMESTAMP})
    logger.info(f"[REBALANCE] uid={uid} rejected id={rebalance_id}")

    return {"category": overspent_category, "overspend": overspend, "message": msg}


# ── Helpers ────────────────────────────────────────────────────────────────────

def _get_previous_month_key(year: int, month: int) -> str:
    """Return the YYYY-MM string for the month before (year, month)."""
    if month == 1:
        return f"{year - 1}-12"
    return f"{year}-{month - 1:02d}"


def _sum_confirmed_expense_by_category(db, uid: str, month_key: str) -> dict[str, float]:
    """
    Return a dict {category: total_confirmed_expense_amount} for the given
    user and month_key. Only confirmed, non-deleted expense transactions are counted.
    """
    docs = (
        db.collection("users").document(uid)
        .collection("transactions")
        .where("monthKey", "==", month_key)
        .where("type", "==", "expense")
        .where("status", "==", "confirmed")
        .stream()
    )
    totals: dict[str, float] = {}
    for doc in docs:
        data = doc.to_dict()
        if data.get("isDeleted", False):
            continue
        cat = data.get("category")
        amt = float(data.get("amount", 0.0))
        if cat:
            totals[cat] = totals.get(cat, 0.0) + amt
    return totals


def _get_all_budget_categories(db, uid: str, month_key: str) -> set[str]:
    """Return the set of all category names that had a budget in month_key."""
    docs = (
        db.collection("users").document(uid)
        .collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )
    return {doc.to_dict().get("category") for doc in docs if doc.to_dict().get("category")}


# ── Budget confirmation flag ───────────────────────────────────────────────────

def get_budget_month_meta(db, uid: str, month_key: str) -> dict:
    """
    Fetch the budget-month metadata doc for a user+month.
    Returns dict with at least {"budgetConfirmedForMonth": bool}.
    Creates the doc with defaults if it doesn't exist.
    """
    ref = (
        db.collection("users").document(uid)
        .collection("budgetMonthMeta").document(month_key)
    )
    doc = ref.get()
    if doc.exists:
        return doc.to_dict()
    # Default: not confirmed
    data = {
        "monthKey": month_key,
        "budgetConfirmedForMonth": False,
        "createdAt": SERVER_TIMESTAMP,
    }
    ref.set(data)
    return {"budgetConfirmedForMonth": False, "monthKey": month_key}


def set_budget_confirmed_for_month(db, uid: str, month_key: str, confirmed: bool = True):
    """
    Mark budget as confirmed (or not) for a given user+month.
    """
    ref = (
        db.collection("users").document(uid)
        .collection("budgetMonthMeta").document(month_key)
    )
    ref.set({
        "monthKey": month_key,
        "budgetConfirmedForMonth": confirmed,
        "updatedAt": SERVER_TIMESTAMP,
    }, merge=True)
    logger.info(f"[BUDGET_META] uid={uid} month={month_key} confirmed={confirmed}")


# ── Month rollover ─────────────────────────────────────────────────────────────

def perform_month_rollover_for_user(db, uid: str, new_month_key: str):
    """
    Execute the month rollover for a single user:

    1. Compute last month's confirmed spending per category.
    2. For each category (union of: last month's budgets + last month's spending):
       - Create/update a budget doc for new_month_key with:
           limit = last_month_spent[category]  (can be 0, never null)
           spent = 0.0  (reset)
    3. Store a "new_month_started" event in users/{uid}/events.
    4. Set budgetConfirmedForMonth = False for new_month_key.

    Args:
        db: Firestore client
        uid: User's Firebase uid
        new_month_key: The new month in "YYYY-MM" format (e.g. "2026-06")
    """
    # Parse new month to compute previous month key
    year, month = int(new_month_key[:4]), int(new_month_key[5:])
    prev_month_key = _get_previous_month_key(year, month)

    logger.info(f"[ROLLOVER] uid={uid} prev={prev_month_key} new={new_month_key}")

    # 1. Last month's confirmed spending per category
    last_month_spent = _sum_confirmed_expense_by_category(db, uid, prev_month_key)

    # 2. Also include categories that had a budget last month even if $0 spent
    prev_budget_cats = _get_all_budget_categories(db, uid, prev_month_key)
    all_cats = set(last_month_spent.keys()) | prev_budget_cats

    if not all_cats:
        logger.info(f"[ROLLOVER] uid={uid} — no categories found, skipping budget creation")

    budgets_ref = db.collection("users").document(uid).collection("budgets")
    new_budgets: dict[str, float] = {}

    for cat in all_cats:
        spent_last_month = last_month_spent.get(cat, 0.0)
        new_limit = spent_last_month  # rule: new budget = last month actual spend

        # Check if a budget for this category+new_month already exists
        existing = list(
            budgets_ref
            .where("category", "==", cat)
            .where("monthKey", "==", new_month_key)
            .limit(1)
            .stream()
        )

        if existing:
            # Update only if the user hasn't already manually set it
            existing[0].reference.update({
                "limit": new_limit,
                "spent": 0.0,
                "updatedAt": SERVER_TIMESTAMP,
            })
            logger.info(f"[ROLLOVER] uid={uid} updated {cat} limit={new_limit}")
        else:
            # Create new budget for the new month
            new_ref = budgets_ref.document()
            new_ref.set({
                "category": cat,
                "limit": new_limit,
                "spent": 0.0,
                "alertThreshold": 80,
                "monthKey": new_month_key,
                "createdAt": SERVER_TIMESTAMP,
                "updatedAt": SERVER_TIMESTAMP,
            })
            logger.info(f"[ROLLOVER] uid={uid} created {cat} limit={new_limit}")

        new_budgets[cat] = new_limit

    # 3. Fire "new_month_started" event
    try:
        event_ref = (
            db.collection("users").document(uid)
            .collection("events").document()
        )
        event_ref.set({
            "type": "new_month_started",
            "monthKey": new_month_key,
            "newBudgets": new_budgets,
            "previousMonthKey": prev_month_key,
            "isRead": False,
            "createdAt": SERVER_TIMESTAMP,
        })
        logger.info(f"[ROLLOVER] uid={uid} fired new_month_started event id={event_ref.id}")
    except Exception as e:
        logger.error(f"[ROLLOVER] Failed to write new_month_started event for uid={uid}: {e}")

    # 4. Mark budget as NOT confirmed for the new month (user must confirm)
    try:
        set_budget_confirmed_for_month(db, uid, new_month_key, confirmed=False)
    except Exception as e:
        logger.error(f"[ROLLOVER] Failed to set budgetMonthMeta for uid={uid}: {e}")


def run_month_rollover():
    """
    Scheduled job: runs on the 1st of every month.
    Iterates over all users and performs month rollover.
    """
    db = get_firestore()
    now = datetime.now(timezone.utc)
    new_month_key = now.strftime("%Y-%m")

    logger.info(f"[ROLLOVER] Starting month rollover for {new_month_key}")

    try:
        users = db.collection("users").stream()
        count = 0
        for user_doc in users:
            uid = user_doc.id
            try:
                perform_month_rollover_for_user(db, uid, new_month_key)
                count += 1
            except Exception as e:
                logger.error(f"[ROLLOVER] Failed for uid={uid}: {e}")
        logger.info(f"[ROLLOVER] Done. Processed {count} users.")
    except Exception as e:
        logger.error(f"[ROLLOVER] Fatal error: {e}")


# ── Pre-month-end reminder ─────────────────────────────────────────────────────

def run_pre_month_end_reminder():
    """
    Scheduled job: runs 1–2 days before month end.
    For each user, if upcoming month's budget is not confirmed, fire a reminder event.
    """
    db = get_firestore()
    now = datetime.now(timezone.utc)
    current_month_key = now.strftime("%Y-%m")

    # Compute next month key
    if now.month == 12:
        next_month_key = f"{now.year + 1}-01"
    else:
        next_month_key = f"{now.year}-{now.month + 1:02d}"

    logger.info(f"[REMINDER] Running pre-month-end check. nextMonth={next_month_key}")

    try:
        users = db.collection("users").stream()
        count = 0
        for user_doc in users:
            uid = user_doc.id
            try:
                meta = get_budget_month_meta(db, uid, next_month_key)
                if not meta.get("budgetConfirmedForMonth", False):
                    # Fire reminder event
                    event_ref = (
                        db.collection("users").document(uid)
                        .collection("events").document()
                    )
                    event_ref.set({
                        "type": "pre_new_month_budget_reminder",
                        "monthKey": next_month_key,
                        "currentMonthKey": current_month_key,
                        "isRead": False,
                        "createdAt": SERVER_TIMESTAMP,
                    })
                    count += 1
                    logger.info(f"[REMINDER] Fired reminder for uid={uid} → {next_month_key}")
            except Exception as e:
                logger.error(f"[REMINDER] Failed for uid={uid}: {e}")
        logger.info(f"[REMINDER] Done. Reminded {count} users.")
    except Exception as e:
        logger.error(f"[REMINDER] Fatal error: {e}")
