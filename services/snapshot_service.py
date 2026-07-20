"""
snapshot_service.py
====================
Daily Snapshot infrastructure — Step 9. See
backend/FINANCIAL_ENGINE_SPEC.md, "Step 9.0 — Daily Snapshot Philosophy"
through "Step 9.2 — How a Snapshot Comes Into Existence," for the full
contract this file implements.

This module owns nothing — it only assembles (spec Step 9.0's
ownership table). Every value it writes comes from a domain engine's
own already-existing public function, called exactly once each; this
file adds no new computation of its own (Compression Principle, Rule 7).

Public API:
    create_daily_snapshot(db, uid, date, generated_at=None) -> dict
"""

from datetime import date as date_cls, datetime, timezone

from services import financial_engine
from services import metrics_engine
from services import health_engine
from services import recommendation_engine
from services import behavior_engine
from services import behavior_state_repository as behavior_repo
from utils import get_month_key

SNAPSHOT_VERSION = "1.0.0"

_REQUIRED_GATHERED_KEYS = [
    "financial", "metrics", "health", "recommendation",
    "behaviorState", "behaviorSummary",
]


def _as_date(value):
    if isinstance(value, date_cls) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    return datetime.fromisoformat(value).date()


def month_key_for(snapshot_date) -> str:
    """Shared with services/scheduler_service.py's dry-run preview path,
    so both compute the same month_key the same way."""
    return get_month_key(
        datetime(snapshot_date.year, snapshot_date.month, snapshot_date.day, tzinfo=timezone.utc)
    )


def _snapshot_ref(db, uid: str, snapshot_date):
    return (
        db.collection("users").document(uid)
        .collection("dailySnapshots").document(snapshot_date.isoformat())
    )


def _gather(db, uid: str, month_key: str) -> dict:
    """Calls each domain engine's existing public read function exactly
    once. No new computation — pure reuse, per the Compression Principle."""
    return {
        "financial": financial_engine.get_summary(db, uid, month_key),
        "metrics": metrics_engine.get_metrics(db, uid, month_key),
        "health": health_engine.compute_overall_health(db, uid, month_key),
        "categoryHealth": health_engine.compute_category_health(db, uid, month_key),
        "recommendation": recommendation_engine.compute_recommendations(db, uid, month_key),
        "behaviorState": behavior_repo.load_state(db, uid),
        "behaviorSummary": behavior_engine.compute_behavior_summary(db, uid),
    }


def _is_complete(gathered: dict) -> bool:
    """
    The Snapshot Invariant, checked explicitly against the gathered data
    itself — never inferred from "nothing raised an exception" (spec
    Step 9.2's failure-behavior principle: "no exception" is not the
    same claim as "complete").
    """
    return all(gathered.get(key) is not None for key in _REQUIRED_GATHERED_KEYS)


def _build_snapshot(gathered: dict, snapshot_date, generated_at: str) -> dict:
    """Pure assembly — no calculation, no mutation, beyond field
    selection (spec Step 9.1's schema; Rule 9's determinism: no
    timestamp anywhere in here except the passed-in generated_at)."""
    financial = gathered["financial"]
    metrics = gathered["metrics"]
    overall_health = gathered["health"]["overallHealth"]
    category_health = gathered["categoryHealth"].get("categoryHealth") or {}
    recommendation = gathered["recommendation"]["primaryRecommendation"]
    behavior_state = gathered["behaviorState"]
    behavior_summary = gathered["behaviorSummary"]
    recovery_plan = metrics.get("recoveryPlan")
    spending_pace = metrics.get("spendingPace")
    recommended_daily_spend = metrics.get("recommendedDailySpend")

    return {
        "snapshotDate": snapshot_date.isoformat(),
        "generatedAt": generated_at,
        "snapshotVersion": SNAPSHOT_VERSION,
        "versions": {
            "financial": financial["metadata"]["engineVersion"],
            "metrics": metrics["metadata"]["metricsEngineVersion"],
            "health": gathered["health"]["metadata"]["healthEngineVersion"],
            "recommendation": gathered["recommendation"]["metadata"]["recommendationEngineVersion"],
            "behavior": behavior_summary["summaryVersion"],
        },
        "financial": {
            "income": financial["income"],
            "totalSpent": financial["totalSpent"],
            "remainingBudget": financial["remainingBudget"],
            "savingsPool": financial["savingsPool"],
        },
        "metrics": {
            "spendingPaceStatus": spending_pace["status"] if spending_pace else None,
            "recommendedDailySpendValue": recommended_daily_spend["value"] if recommended_daily_spend else None,
            "recoveryPlanPresent": recovery_plan is not None,
            "recoveryPossible": recovery_plan["recoveryPossible"] if recovery_plan else None,
        },
        "health": {
            "overallHealthStatus": overall_health["status"],
            "categoryHealth": {cat: info["status"] for cat, info in category_health.items()},
        },
        "recommendation": {
            "primaryRecommendationCode": recommendation["code"],
        },
        "behavior": {
            "state": {
                "logging": {
                    "currentStreak": behavior_state["logging"]["currentStreak"],
                    "bestStreak": behavior_state["logging"]["bestStreak"],
                },
                "spending": {
                    "currentHealthyStreak": behavior_state["spending"]["currentHealthyStreak"],
                    "currentOverspendingStreak": behavior_state["spending"]["currentOverspendingStreak"],
                },
                "saving": {
                    "currentProtectionStreak": behavior_state["saving"]["currentProtectionStreak"],
                },
                "recovery": {
                    "currentStreak": behavior_state["recovery"]["currentStreak"],
                    "totalResolved": behavior_state["recovery"]["totalResolved"],
                    "totalFailed": behavior_state["recovery"]["totalFailed"],
                },
            },
            "summary": {
                "status": behavior_summary["status"],
                "primaryReason": behavior_summary["primaryReason"],
                "confidence": behavior_summary["confidence"],
            },
        },
    }


def create_daily_snapshot(db, uid: str, date, generated_at: str = None) -> dict:
    """
    Creates and writes users/{uid}/dailySnapshots/{date}, per spec Steps
    9.0-9.2.

    Idempotent per date (Rule 5): a no-op returning the already-written
    document if one exists for this date — never overwrites, merges, or
    patches.

    All-or-nothing (Rule 3): raises ValueError, writing nothing, if the
    gathered data is incomplete. Never writes a partial snapshot.

    `date` may be a date, datetime, or ISO date string. `generated_at`
    defaults to the current moment if not given (tests should pass an
    explicit value — Rule 9 determinism).
    """
    snapshot_date = _as_date(date)
    ref = _snapshot_ref(db, uid, snapshot_date)

    existing = ref.get()
    if existing.exists:
        return existing.to_dict()

    gathered = _gather(db, uid, month_key_for(snapshot_date))

    if not _is_complete(gathered):
        missing = [key for key in _REQUIRED_GATHERED_KEYS if gathered.get(key) is None]
        raise ValueError(
            f"Cannot create snapshot for {snapshot_date.isoformat()}: "
            f"incomplete engine output, missing {missing}"
        )

    generated_at = generated_at or datetime.now(timezone.utc).isoformat()
    snapshot = _build_snapshot(gathered, snapshot_date, generated_at)

    ref.set(snapshot)
    return snapshot
