"""
test_behavior_state_repository.py
==================================
Phase 4.5, Step 2 acceptance scenarios for the BehaviorState Repository
— see FINANCIAL_ENGINE_SPEC.md's "Firestore paths — frozen" and
"Behavior State Model." Pure data-access tests against a minimal fake
Firestore client (no real project needed) — this module has no business
logic to exercise, only read/write/merge/append semantics.

Run directly: python tests/test_behavior_state_repository.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from google.cloud.firestore_v1 import ArrayUnion

from services import behavior_state_repository as repo

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


# ─── Minimal fake Firestore — just enough surface for the repository ───────

def _apply(data, patch):
    for key, value in patch.items():
        if isinstance(value, ArrayUnion):
            data[key] = data.get(key, []) + [v for v in value.values if v not in data.get(key, [])]
        elif "." in key:
            # dotted-path merge, e.g. "logging.currentStreak"
            head, _, tail = key.partition(".")
            data.setdefault(head, {})[tail] = value
        else:
            data[key] = value
    return data


class FakeSnapshot:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class FakeDocRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return FakeSnapshot(self._store.get(self._key))

    def set(self, data, merge=False):
        if merge and self._key in self._store:
            self._store[self._key] = _apply(dict(self._store[self._key]), data)
        else:
            self._store[self._key] = dict(data)

    def update(self, patch):
        # Mirrors real Firestore's update(): dotted keys resolve as nested
        # field paths, unlike set(merge=True) which stores them literally.
        self._store[self._key] = _apply(dict(self._store[self._key]), patch)


class FakeCollectionRef:
    def __init__(self, store, prefix):
        self._store = store
        self._prefix = prefix

    def document(self, doc_id):
        return FakeDocRef(self._store, f"{self._prefix}/{doc_id}")


class FakeUserDocRef:
    def __init__(self, store, uid):
        self._store = store
        self._uid = uid

    def collection(self, name):
        return FakeCollectionRef(self._store, f"users/{self._uid}/{name}")


class FakeDB:
    def __init__(self):
        self._store = {}

    def collection(self, name):
        assert name == "users"
        return _UsersCollection(self._store)


class _UsersCollection:
    def __init__(self, store):
        self._store = store

    def document(self, uid):
        return FakeUserDocRef(self._store, uid)


def run():
    print("BehaviorState Repository — test matrix")
    db = FakeDB()
    uid = "test-uid"

    # 1. load_state before initialize -> frozen default shape, no write happens
    state = repo.load_state(db, uid)
    check(
        "load_state() before initialize() returns default shape",
        state == repo._default_state(),
        f"got {state}",
    )
    check(
        "load_state() before initialize() performs no write",
        db._store == {},
        f"store not empty: {db._store}",
    )

    # 2. initialize() creates both documents with default shapes
    repo.initialize(db, uid)
    check(
        "initialize() creates behaviorState/current with default shape",
        db._store.get(f"users/{uid}/behaviorState/current") == repo._default_state(),
    )
    check(
        "initialize() creates behaviorHistory/current with default shape",
        db._store.get(f"users/{uid}/behaviorHistory/current") == repo._default_history(),
    )

    # 3. initialize() is idempotent — an existing document is never overwritten
    repo.update_state(db, uid, {"logging.currentStreak": 5})
    repo.initialize(db, uid)
    check(
        "initialize() does not overwrite an already-initialized behaviorState",
        repo.load_state(db, uid)["logging"]["currentStreak"] == 5,
        f"got {repo.load_state(db, uid)}",
    )

    # 4. update_state() merges a single nested field without touching siblings
    before = repo.load_state(db, uid)
    repo.update_state(db, uid, {"logging.bestStreak": 5})
    after = repo.load_state(db, uid)
    check(
        "update_state() updates only the targeted field",
        after["logging"]["bestStreak"] == 5 and after["logging"]["currentStreak"] == 5,
        f"got {after}",
    )
    check(
        "update_state() leaves other top-level sections untouched",
        after["spending"] == before["spending"] and after["saving"] == before["saving"],
        f"got {after}",
    )

    # 5. save_state() overwrites the whole document
    repo.save_state(db, uid, repo._default_state())
    check(
        "save_state() fully overwrites behaviorState",
        repo.load_state(db, uid) == repo._default_state(),
        f"got {repo.load_state(db, uid)}",
    )

    # 6. append_milestone() accumulates, never replaces
    repo.append_milestone(db, uid, {"code": "FIRST_HEALTHY_WEEK", "unlockedAt": "2026-07-19"})
    repo.append_milestone(db, uid, {"code": "CONSISTENT_LOGGER", "unlockedAt": "2026-07-20"})
    history = repo.load_history(db, uid)
    check(
        "append_milestone() accumulates milestones in order, none overwritten",
        [m["code"] for m in history["milestones"]] == ["FIRST_HEALTHY_WEEK", "CONSISTENT_LOGGER"],
        f"got {history['milestones']}",
    )

    # 7. append_recovery_attempt() accumulates independently of milestones
    repo.append_recovery_attempt(db, uid, {"startedOn": "2026-07-01", "resolvedOn": "2026-07-05", "outcome": "resolved"})
    history = repo.load_history(db, uid)
    check(
        "append_recovery_attempt() accumulates without disturbing milestones",
        len(history["recoveryAttempts"]) == 1 and len(history["milestones"]) == 2,
        f"got {history}",
    )

    # 8. Repository has no business-logic surface — only the frozen data-access functions
    import inspect
    public_functions = {
        name for name, obj in vars(repo).items()
        if not name.startswith("_") and inspect.isfunction(obj) and obj.__module__ == repo.__name__
    }
    expected = {"initialize", "load_state", "save_state", "update_state", "load_history", "append_milestone", "append_recovery_attempt"}
    check(
        "Repository's public surface matches exactly the frozen data-access API",
        public_functions == expected,
        f"got {public_functions}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All BehaviorState Repository scenarios passed.")


if __name__ == "__main__":
    run()
