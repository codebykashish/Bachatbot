"""
pattern_service.py
=====================
Pattern Spending Alerts — Phase 17. See backend/FINANCIAL_ENGINE_SPEC.md,
"Phase 17 — Pattern Spending Alerts — Design, FROZEN," for the full
contract this file implements.

Detects when today's spending in a category is unusually high compared
to the user's own recent baseline in that category, and — if so — asks
the Notification Engine to turn that into a real notification via
eligibility_engine.process_event(), the same public API every other
event in this app resolves through. This module owns detection only:
it never persists a notification, never generates wording, never
delivers (that's eligibility_engine.py -> notification_generator.py ->
notification_repository.py -> delivery_service.py, same as everywhere
else).

Deliberately the first caller of eligibility_engine.process_event()
from a live route rather than the nightly scheduler diff — required by
this feature's own "immediate, tied to the transaction" trigger timing,
which a once-a-day diff cannot satisfy.

Public API:
    check_spending_pattern(db, uid, category, today=None) -> dict | None
"""

from datetime import date, datetime, timezone

from services import eligibility_engine as elig

# Minimum trust gate (spec Phase 17 Design) — fewer than this many
# expenses ever logged in a category means there isn't enough of a
# pattern to call anything "unusual" yet. Permissive end of the agreed
# "5-8 logged expenses" range.
_MIN_EXPENSES_TO_TRUST = 5

# Baseline window (spec Phase 17 Design) — last 30 calendar days if
# that window has enough spending-days in it, else fall back to the
# most recent 10 spending-days regardless of calendar window, so a
# real but sparse category still gets a baseline instead of being
# starved by the 30-day cutoff.
_BASELINE_WINDOW_DAYS = 30
_MIN_SPENDING_DAYS_IN_WINDOW = 8
_FALLBACK_SPENDING_DAYS = 10

# Flag if today's total is at least this many times the baseline
# average — rough heuristic, tunable later (same spirit as
# metrics_engine.py's first-cut pressure thresholds).
_ANOMALY_MULTIPLIER = 2.0

# Spread the correction over this many days when suggesting a lower
# daily target, rather than a single "stop spending" message.
_SUGGESTED_CORRECTION_DAYS = 3

# Bounds the read instead of an unbounded per-category history fetch —
# generous for personal-finance-app transaction volume, matches this
# codebase's existing client-side date-filtering convention (utils.py's
# is_today/is_in_current_month etc.) rather than a new server-side
# range query needing its own composite Firestore index.
_MAX_TRANSACTIONS_FETCHED = 200


def _as_utc_date(timestamp) -> date | None:
    """Same tolerant timestamp handling as utils.py's is_today/
    is_in_current_month — accepts a real Firestore timestamp (has
    .date()) or bare None; never raises on a malformed value."""
    if timestamp is None:
        return None
    if not hasattr(timestamp, "date"):
        return None
    if getattr(timestamp, "tzinfo", None) is None:
        timestamp = timestamp.replace(tzinfo=timezone.utc)
    return timestamp.date()


def _recent_category_expenses(db, uid: str, category: str) -> list[dict]:
    """
    Equality filters only (category/type/status), no order_by -- adding
    order_by on top of three equality filters requires a new Firestore
    composite index (confirmed against the real project: the query
    failed with FailedPrecondition until this was simplified), while
    utils.py's sum_category_expense already proves equality-only
    multi-field queries need no new index. Sorted/capped in Python
    instead -- personal-finance transaction volume per category makes
    this a non-issue.
    """
    docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("category", "==", category)
        .where("type", "==", "expense")
        .where("status", "==", "confirmed")
        .stream()
    )
    expenses = [d.to_dict() for d in docs if not (d.to_dict() or {}).get("isDeleted", False)]
    expenses.sort(key=lambda tx: _as_utc_date(tx.get("createdAt")) or date.min, reverse=True)
    return expenses[:_MAX_TRANSACTIONS_FETCHED]


def _daily_totals(expenses: list[dict]) -> dict:
    """{date: total} for every day represented in `expenses`, oldest
    transactions included -- callers slice/filter by date afterward."""
    totals: dict = {}
    for tx in expenses:
        day = _as_utc_date(tx.get("createdAt"))
        if day is None:
            continue
        totals[day] = totals.get(day, 0.0) + float(tx.get("amount") or 0)
    return totals


def _baseline_average(daily_totals: dict, today: date) -> float | None:
    window_start = date.fromordinal(today.toordinal() - _BASELINE_WINDOW_DAYS)
    in_window = {d: v for d, v in daily_totals.items() if window_start <= d < today}

    if len(in_window) >= _MIN_SPENDING_DAYS_IN_WINDOW:
        chosen = in_window
    else:
        # Fewer spending-days than the window requires -- fall back to
        # the most recent spending-days overall (may reach further back
        # than 30 days), still gated by _MIN_EXPENSES_TO_TRUST upstream.
        before_today = {d: v for d, v in daily_totals.items() if d < today}
        most_recent_days = sorted(before_today.keys(), reverse=True)[:_FALLBACK_SPENDING_DAYS]
        chosen = {d: before_today[d] for d in most_recent_days}

    if not chosen:
        return None
    return sum(chosen.values()) / len(chosen)


def _practical_round(value: float) -> float:
    """Same rounding convention as metrics_engine.py's own
    _practical_round -- nearest whole currency unit, never a
    misleadingly precise decimal for a suggestion that's already a
    rough heuristic."""
    return round(value)


def _detect_anomaly(daily_totals: dict, today: date, expense_count: int) -> dict | None:
    """
    Pure decision core (spec Phase 17 Design) -- given already-fetched
    daily totals for one category, decides whether today is a genuine
    anomaly and, if so, returns the payload to notify with (everything
    except `category`, which the caller already knows). Takes no
    Firestore dependency so it can be tested directly against plain
    dicts, the same convention financial_engine.py's own pure pipeline
    stages (_calculate_budgets etc.) are tested with.
    """
    if expense_count < _MIN_EXPENSES_TO_TRUST:
        return None

    today_total = daily_totals.get(today, 0.0)
    if today_total <= 0:
        return None

    baseline_average = _baseline_average(daily_totals, today)
    if not baseline_average or baseline_average <= 0:
        return None

    if today_total < baseline_average * _ANOMALY_MULTIPLIER:
        return None

    overage = today_total - baseline_average
    suggested_daily = max(0.0, baseline_average - overage / _SUGGESTED_CORRECTION_DAYS)

    return {
        "todayTotal": _practical_round(today_total),
        "baselineAverage": _practical_round(baseline_average),
        "suggestedDailyAmount": _practical_round(suggested_daily),
        "durationDays": _SUGGESTED_CORRECTION_DAYS,
    }


def check_spending_pattern(db, uid: str, category: str, today: date = None) -> dict | None:
    """
    Runs the Phase 17 anomaly check for one category, right after that
    category's budget increment. Returns the resulting notification if
    today's spending is a genuine anomaly AND the Notification Engine's
    own waterfall accepts it (dedup, preferences, frequency all still
    apply -- this function never bypasses any of them); returns None
    if there's no anomaly, not enough history to trust yet, or the
    Engine itself declines the event (e.g. already informed today, or
    the user has muted Budget Alerts).
    """
    today = today or datetime.now(timezone.utc).date()

    expenses = _recent_category_expenses(db, uid, category)
    daily_totals = _daily_totals(expenses)

    payload = _detect_anomaly(daily_totals, today, len(expenses))
    if payload is None:
        return None
    payload["category"] = category

    event = {
        "eventId": f"{uid}:{today.isoformat()}:unusual_spending:{category}",
        "event": "UNUSUAL_SPENDING_DETECTED",
        "payload": payload,
    }

    result = elig.process_event(db, uid, event)
    return result if result and result.get("eligible") is not False else None
