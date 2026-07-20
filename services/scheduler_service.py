"""
scheduler_service.py
======================
Daily Snapshot Scheduler — Step 11. See backend/FINANCIAL_ENGINE_SPEC.md,
"Step 11.0 — Scheduler Philosophy" through "Step 11.2 — Failure &
Recovery Policy," for the full contract this file implements.

This module owns orchestration only — it never computes Financial,
Metrics, Health, Recommendation, or Behavior; never compares snapshots
itself; never classifies events. Every step is a call to
services/snapshot_service.py or services/diff_generator.py, both
already frozen; this file adds exactly one new capability of its own
(persisting events) plus catch-up range determination.

Public API:
    run_daily_snapshot_job(db, today=None, dry_run=False) -> dict
"""

import logging
from datetime import date as date_cls, datetime, timedelta, timezone

from services import snapshot_service
from services import diff_generator
from services import health_engine
from services import metrics_engine
from services import behavior_state_repository as behavior_repo
from services import eligibility_engine
from services.behavior_engine import (
    LOGGING_TIMEZONE, record_spending_activity, record_recovery_activity,
)

logger = logging.getLogger(__name__)

# First cut, tunable (spec Step 11.2) -- an outage longer than this is a
# named operational incident, never silently truncated or absorbed.
MAX_CATCHUP_DAYS = 30


def _today_local(now=None):
    """Reuses Logging Behavior's own day-boundary clock (Asia/Kathmandu)
    — one project, one definition of 'day' (spec Step 11.2), never a
    second SNAPSHOT_TIMEZONE invented alongside it."""
    moment = now or datetime.now(timezone.utc)
    return moment.astimezone(LOGGING_TIMEZONE).date()


def _as_date(value):
    if isinstance(value, date_cls) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    return datetime.fromisoformat(value).date()


def get_active_users(db):
    """Every user document — no 'active' filter exists yet anywhere in
    this codebase, so every user is processed each run."""
    return [doc.id for doc in db.collection("users").stream()]


def _get_last_snapshot_date(db, uid):
    """The most recent existing dailySnapshots document's date, or None
    if this user has never had one — used to derive the catch-up range
    without any separate progress-tracking state (spec Step 11.2)."""
    docs = list(
        db.collection("users").document(uid).collection("dailySnapshots")
        .order_by("snapshotDate", direction="DESCENDING").limit(1).stream()
    )
    if not docs:
        return None
    return _as_date(docs[0].to_dict()["snapshotDate"])


def _catch_up_range(db, uid, today):
    """
    Returns (dates, skipped_reason). `dates` is the ordered list of
    calendar days to process this run; if the gap exceeds
    MAX_CATCHUP_DAYS, `dates` is [] and `skipped_reason` explains why —
    the whole user is skipped this run, never silently truncated to a
    partial catch-up (spec Step 11.2).

    Deliberately starts from the LAST EXISTING snapshot's own date, not
    the day after it — a day whose snapshot exists but whose events were
    lost (a crash between the two steps) gets a chance to have its
    events regenerated on this run, rather than being silently skipped
    forever. Both create_daily_snapshot() and event persistence are
    idempotent, so reprocessing an already-complete day is a safe no-op.
    """
    last = _get_last_snapshot_date(db, uid)
    start = last if last is not None else today
    gap = (today - start).days
    if gap > MAX_CATCHUP_DAYS:
        return [], f"gap of {gap} days exceeds MAX_CATCHUP_DAYS ({MAX_CATCHUP_DAYS})"
    return [start + timedelta(days=i) for i in range(gap + 1)], None


def _milestones_unlocked_on(db, uid, date):
    """behaviorHistory.milestones[] filtered to this date — the third
    input generate_events() needs, per Step 9.1's Option C. Never reads
    the snapshot for this; milestones live only in behaviorHistory."""
    history = behavior_repo.load_history(db, uid)
    date_str = date.isoformat()
    return [m for m in history["milestones"] if m.get("unlockedAt") == date_str]


def persist_events(db, uid, events):
    """Upserts by eventId — deterministic IDs (Step 10.3) make calling
    this twice for the same events safe, never a duplicate."""
    events_collection = db.collection("users").document(uid).collection("events")
    for event in events:
        events_collection.document(event["eventId"]).set(event)


def process_day(db, uid, date, dry_run=False):
    """
    The heart of the pipeline (spec Step 11.1): ensures `date`'s
    snapshot exists, then generates and persists events for the
    (date-1, date) transition if a previous snapshot exists.

    Always attempts both steps regardless of whether they were already
    done — both are idempotent, so redoing a completed step is a safe
    no-op (Step 11.2's "no separate progress tracker" refinement).

    In dry_run mode, nothing is written: a not-yet-existing snapshot is
    computed in memory only (reusing snapshot_service's own gather/build
    functions), and any events found are reported, never persisted.

    Spending and Recovery Behavior (spec 4.5.2/4.5.4) are evaluated for
    `date` here, before the snapshot is created — never after. Since a
    snapshot is immutable once written (Rule 5), this is the only
    window in which today's own evaluation can be reflected in today's
    own snapshot; evaluating afterward would defer that day's streak
    change to only be visible starting in tomorrow's snapshot. This
    means Health/Metrics are read here once for the evaluation, and
    read again moments later inside create_daily_snapshot()'s own
    gather step — a small, deliberate duplication, accepted for the
    same reason Step 9.2 already accepted bounded read-consistency
    imprecision elsewhere: these are historical observations, not an
    audit log requiring perfect atomicity across the two reads.
    """
    stats = {
        "date": date.isoformat(), "snapshotCreated": False,
        "eventsGenerated": 0, "eventTypes": [], "notificationsCreated": 0,
        "success": True, "error": None,
    }

    try:
        ref = snapshot_service._snapshot_ref(db, uid, date)
        existing = ref.get()

        if existing.exists:
            snapshot = existing.to_dict()
        else:
            month_key = snapshot_service.month_key_for(date)
            health_result = health_engine.compute_overall_health(db, uid, month_key)
            metrics_result = metrics_engine.get_metrics(db, uid, month_key)
            overall_status = health_result["overallHealth"]["status"]
            recovery_plan = metrics_result.get("recoveryPlan")
            recovery_present = recovery_plan is not None
            recovery_possible = recovery_plan["recoveryPossible"] if recovery_plan else True

            record_spending_activity(db, uid, overall_status, date)
            record_recovery_activity(db, uid, recovery_present, recovery_possible, date)

            if dry_run:
                gathered = snapshot_service._gather(db, uid, month_key)
                if not snapshot_service._is_complete(gathered):
                    stats["success"] = False
                    stats["error"] = "incomplete engine output"
                    return stats
                snapshot = snapshot_service._build_snapshot(
                    gathered, date, datetime.now(timezone.utc).isoformat()
                )
            else:
                snapshot = snapshot_service.create_daily_snapshot(db, uid, date)
                stats["snapshotCreated"] = True

        previous_doc = snapshot_service._snapshot_ref(db, uid, date - timedelta(days=1)).get()
        if previous_doc.exists:
            milestones_today = _milestones_unlocked_on(db, uid, date)
            events = diff_generator.generate_events(uid, previous_doc.to_dict(), snapshot, milestones_today)
            stats["eventsGenerated"] = len(events)
            stats["eventTypes"] = [e["event"] for e in events]
            if not dry_run and events:
                persist_events(db, uid, events)
                # Notification Engine wiring (spec 5.9's own review found
                # this missing entirely, then closed it): every persisted
                # event is offered to the Eligibility Waterfall, which
                # decides whether it becomes a notification at all --
                # this scheduler never makes that decision itself.
                for event in events:
                    try:
                        result = eligibility_engine.process_event(db, uid, event)
                        if result is not None and result.get("eligible") is not False:
                            stats["notificationsCreated"] += 1
                    except Exception as exc:
                        logger.warning(
                            "[SCHEDULER] uid=%s notification pipeline failed for event=%s: %s",
                            uid, event.get("event"), exc,
                        )

    except Exception as exc:
        stats["success"] = False
        stats["error"] = str(exc)

    return stats


def process_user(db, uid, today, dry_run=False):
    """Rule 2: this is the per-user isolation boundary — a failure here
    (caught by run_daily_snapshot_job) never stops other users. Within
    it, each day is its own isolation boundary too (process_day never
    raises past itself), so one bad historical day doesn't block later
    days for this same user."""
    dates, skipped_reason = _catch_up_range(db, uid, today)

    if skipped_reason:
        logger.warning("[SCHEDULER] user=%s skipped: %s", uid, skipped_reason)
        return {
            "uid": uid, "success": False, "skipped": True, "reason": skipped_reason,
            "daysProcessed": 0, "snapshotsCreated": 0, "eventsGenerated": 0,
            "notificationsCreated": 0, "days": [],
        }

    day_stats = [process_day(db, uid, date, dry_run=dry_run) for date in dates]
    success = all(d["success"] for d in day_stats)

    result = {
        "uid": uid,
        "success": success,
        "skipped": False,
        "reason": None,
        "daysProcessed": len(day_stats),
        "snapshotsCreated": sum(1 for d in day_stats if d["snapshotCreated"]),
        "eventsGenerated": sum(d["eventsGenerated"] for d in day_stats),
        "notificationsCreated": sum(d["notificationsCreated"] for d in day_stats),
        "days": day_stats,
    }
    logger.info(
        "[SCHEDULER] user=%s days=%d snapshotsCreated=%d eventsGenerated=%d success=%s",
        uid, result["daysProcessed"], result["snapshotsCreated"], result["eventsGenerated"], success,
    )
    return result


def run_daily_snapshot_job(db, today=None, dry_run: bool = False) -> dict:
    """
    The only public entry point (spec Step 11.0-11.2). Takes a database
    handle and a date — nothing else, no business objects. Returns a
    run summary; its only side effects are writes to `dailySnapshots/`
    and `events/` (none at all in dry_run mode).

    `today` defaults to *yesterday* in LOGGING_TIMEZONE if not given —
    not the current calendar day. The job is meant to run shortly after
    a day ends (e.g. 00:30), so "the day considered complete and ready
    to snapshot" is always the one that just fully elapsed, never the
    barely-started day the clock currently reads (Rule 6: no assumption
    about midnight — this default is what actually makes that rule
    true, regardless of whether the job fires at 00:05, 00:20, or 01:00).
    Pass an explicit `today` to snapshot any other specific date.
    """
    today = _as_date(today) if today is not None else _today_local() - timedelta(days=1)
    logger.info("[SCHEDULER] Started — date=%s dry_run=%s", today.isoformat(), dry_run)

    users = get_active_users(db)
    user_results = []
    for uid in users:
        try:
            user_results.append(process_user(db, uid, today, dry_run=dry_run))
        except Exception as exc:
            logger.exception("[SCHEDULER] user=%s failed unexpectedly", uid)
            user_results.append({
                "uid": uid, "success": False, "skipped": False, "reason": str(exc),
                "daysProcessed": 0, "snapshotsCreated": 0, "eventsGenerated": 0,
                "notificationsCreated": 0, "days": [],
            })

    summary = {
        "date": today.isoformat(),
        "dryRun": dry_run,
        "usersProcessed": len(users),
        "usersSucceeded": sum(1 for r in user_results if r["success"]),
        "usersFailed": sum(1 for r in user_results if not r["success"] and not r["skipped"]),
        "usersSkipped": sum(1 for r in user_results if r["skipped"]),
        "snapshotsCreated": sum(r["snapshotsCreated"] for r in user_results),
        "eventsGenerated": sum(r["eventsGenerated"] for r in user_results),
        "notificationsCreated": sum(r["notificationsCreated"] for r in user_results),
        "users": user_results,
    }
    logger.info(
        "[SCHEDULER] Finished — users=%d succeeded=%d failed=%d skipped=%d "
        "snapshotsCreated=%d eventsGenerated=%d notificationsCreated=%d",
        summary["usersProcessed"], summary["usersSucceeded"], summary["usersFailed"],
        summary["usersSkipped"], summary["snapshotsCreated"], summary["eventsGenerated"],
        summary["notificationsCreated"],
    )
    return summary
