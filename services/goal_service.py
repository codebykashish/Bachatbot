"""
goal_service.py
================
Live progress computation for savings goals.

Core rule (agreed with the user): there is no manual "add savings" action
and no persisted contribution amount. A goal's progress is always computed
live from the same "unallocated income" pool already used elsewhere in the
app (income - total category budget limits — the same number shown as
"Savings" on the home screen). The only way to increase progress is to add
more income; the only way to decrease it is to allocate more of that
income into a category budget.

If the pool is smaller than what all active goals want combined, it's
split proportionally by each goal's remaining need, so no goal "steals"
more than its fair share and no category budget is ever touched.
"""


def get_available_pool(db, uid: str, month_key: str) -> float:
    """income - total category budget limits for month_key, floored at 0."""
    try:
        income_map = (
            db.collection("users").document(uid).get().to_dict() or {}
        ).get("income") or {}
        income_total = (
            float(income_map.get("inHand") or 0)
            + float(income_map.get("inBank") or 0)
            + float(income_map.get("onlineBanking") or 0)
        )
    except Exception:
        income_total = 0.0

    budget_docs = list(
        db.collection("users").document(uid).collection("budgets")
        .where("monthKey", "==", month_key)
        .stream()
    )
    total_limits = sum(float(b.to_dict().get("limit") or 0) for b in budget_docs)

    return max(0.0, income_total - total_limits)


def get_active_goals(db, uid: str) -> list[dict]:
    """Active, non-deleted goals with their Firestore doc id attached."""
    docs = db.collection("users").document(uid).collection("goals").stream()
    goals = []
    for doc in docs:
        data = doc.to_dict()
        if data.get("isDeleted", False):
            continue
        if data.get("status") == "completed":
            continue
        data["_id"] = doc.id
        goals.append(data)
    return goals


def compute_goal_progress(db, uid: str, month_key: str) -> dict:
    """
    Returns {goal_id: saved_amount} — how much of the available pool each
    active goal currently gets credited with, live. Never exceeds a goal's
    own targetAmount, and the sum never exceeds the available pool.

    Goals are grouped into priority tiers (lower number = higher priority,
    default 1). Higher tiers are fully funded before a lower tier sees
    anything ("earphones first, then lots of food"). Goals sharing the same
    tier split that tier's share proportionally to their own target, so two
    goals at the same priority grow side by side — this is also what makes
    the old flat behavior (everyone at the default tier) unchanged.
    """
    goals = get_active_goals(db, uid)
    if not goals:
        return {}

    available = get_available_pool(db, uid, month_key)
    if available <= 0:
        return {g["_id"]: 0.0 for g in goals}

    tiers: dict[int, list[dict]] = {}
    for g in goals:
        tier = int(g.get("priority") or 1)
        tiers.setdefault(tier, []).append(g)

    result: dict[str, float] = {}
    remaining = available
    for tier in sorted(tiers.keys()):
        tier_goals = tiers[tier]
        targets = {g["_id"]: float(g.get("targetAmount") or 0) for g in tier_goals}
        total_target = sum(targets.values())

        if total_target <= 0 or remaining <= 0:
            for gid in targets:
                result[gid] = 0.0
            continue

        if remaining >= total_target:
            result.update(targets)
            remaining -= total_target
        else:
            ratio = remaining / total_target
            for gid, amount in targets.items():
                result[gid] = round(amount * ratio, 2)
            remaining = 0.0

    return result


def get_active_goal_names(db, uid: str) -> list[str]:
    """Names of active goals with an unmet target — used to flag the
    overspend-rebalance confirmation when it would eat into goal money."""
    return [g.get("name", "Goal") for g in get_active_goals(db, uid)]
