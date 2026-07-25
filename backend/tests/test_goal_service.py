"""
test_goal_service.py
=======================
Phase 18 acceptance scenarios for the shared tier-splitting waterfall
and its two callers (compute_goal_progress's current pool,
compute_projected_goal_progress's projected pool) — see
FINANCIAL_ENGINE_SPEC.md's "Phase 18 — Goal Risk — Design, FROZEN."

Run directly: python tests/test_goal_service.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import goal_service as gs

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fake Firestore — just enough for get_active_goals() ──────────

class FakeSnapshot:
    def __init__(self, data, doc_id):
        self._data = data
        self.id = doc_id

    def to_dict(self):
        return dict(self._data)


class FakeCollectionRef:
    def __init__(self, docs):
        self._docs = docs

    def stream(self):
        return [FakeSnapshot(d, d["_id"]) for d in self._docs]


class FakeUserDocRef:
    def __init__(self, goals):
        self._goals = goals

    def collection(self, name):
        assert name == "goals"
        return FakeCollectionRef(self._goals)


class FakeDB:
    def __init__(self, goals):
        self._goals = goals

    def collection(self, name):
        assert name == "users"
        return self

    def document(self, uid):
        return FakeUserDocRef(self._goals)


def run():
    print("Goal Service — test matrix")

    goal_a = {"_id": "a", "name": "Earphones", "targetAmount": 3000.0, "priority": 1, "status": "active"}
    goal_b = {"_id": "b", "name": "Laptop", "targetAmount": 50000.0, "priority": 2, "status": "active"}
    goal_c = {"_id": "c", "name": "Trip", "targetAmount": 10000.0, "priority": 2, "status": "active"}
    goal_completed = {"_id": "d", "name": "Old goal", "targetAmount": 500.0, "priority": 1, "status": "completed"}

    # 1. Empty goals -> empty result, no division by zero
    check(
        "No goals -> empty distribution",
        gs._distribute_pool_across_tiers([], 1000.0) == {},
    )

    # 2. Zero/negative pool -> every goal gets 0, never negative
    result2 = gs._distribute_pool_across_tiers([goal_a, goal_b], 0.0)
    check(
        "Zero pool -> every goal gets exactly 0.0",
        result2 == {"a": 0.0, "b": 0.0},
        f"got {result2}",
    )

    # 3. Single tier, pool covers it fully -> exact target amounts
    result3 = gs._distribute_pool_across_tiers([goal_a], 5000.0)
    check(
        "Pool exceeds single goal's target -> fully funded at its target, not the whole pool",
        result3 == {"a": 3000.0},
        f"got {result3}",
    )

    # 4. Higher-priority tier fully funded before lower tier sees anything
    result4 = gs._distribute_pool_across_tiers([goal_a, goal_b], 3000.0)
    check(
        "Pool exactly covers tier-1 goal -> tier-2 goal gets 0.0, not starved silently (explicit 0)",
        result4 == {"a": 3000.0, "b": 0.0},
        f"got {result4}",
    )

    # 5. Same-tier goals split proportionally to their own target
    result5 = gs._distribute_pool_across_tiers([goal_b, goal_c], 6000.0)
    # b:c targets are 50000:10000 = 5:1 -> b gets 5000, c gets 1000
    check(
        "Same-tier goals split proportionally by target size (5:1 ratio)",
        result5 == {"b": 5000.0, "c": 1000.0},
        f"got {result5}",
    )

    # 6. Insufficient pool for tier 1 alone -> partial funding, proportional even within a single-goal tier
    result6 = gs._distribute_pool_across_tiers([goal_a], 1500.0)
    check(
        "Pool insufficient for tier's total target -> proportional partial funding",
        result6 == {"a": 1500.0},
        f"got {result6}",
    )

    # 7. compute_projected_goal_progress reuses the same waterfall, fed a projected pool
    db = FakeDB([goal_a, goal_b, goal_completed])
    result7 = gs.compute_projected_goal_progress(db, "u1", 3000.0)
    check(
        "compute_projected_goal_progress excludes completed goals (via get_active_goals) and funds tier-1 fully",
        result7 == {"a": 3000.0, "b": 0.0} and "d" not in result7,
        f"got {result7}",
    )

    # 8. compute_projected_goal_progress with no active goals -> empty, not an error
    db_empty = FakeDB([goal_completed])
    result8 = gs.compute_projected_goal_progress(db_empty, "u1", 5000.0)
    check(
        "compute_projected_goal_progress with only completed goals -> empty dict",
        result8 == {},
        f"got {result8}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Goal Service scenarios passed.")


if __name__ == "__main__":
    run()
