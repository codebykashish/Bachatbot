from datetime import datetime, timezone
import calendar


def get_month_key(dt: datetime = None) -> str:
    """
    Returns monthKey string like "2026-04"
    If no datetime given, returns current month
    """
    if dt is None:
        dt = datetime.now(timezone.utc)
    return dt.strftime("%Y-%m")


def get_current_month_key() -> str:
    """Returns current month key"""
    return get_month_key()


def get_days_remaining_in_month() -> int:
    """
    Returns how many days are remaining in current month
    Including today
    """
    today = datetime.now(timezone.utc)
    total_days = calendar.monthrange(today.year, today.month)[1]
    days_remaining = total_days - today.day + 1  # +1 includes today
    return max(days_remaining, 1)  # never return 0


def get_days_passed_in_month() -> int:
    """
    Returns how many days have passed in current month
    """
    today = datetime.now(timezone.utc)
    return today.day


def get_total_days_in_month() -> int:
    """Returns total days in current month"""
    today = datetime.now(timezone.utc)
    return calendar.monthrange(today.year, today.month)[1]


def timestamp_to_iso(timestamp) -> str:
    """
    Converts Firestore timestamp to ISO string
    Handles both Firestore DatetimeWithNanoseconds and regular datetime
    """
    if timestamp is None:
        return None
    
    if hasattr(timestamp, 'isoformat'):
        # Already a datetime object
        if timestamp.tzinfo is None:
            # Add UTC timezone if missing
            timestamp = timestamp.replace(tzinfo=timezone.utc)
        return timestamp.isoformat()
    
    # If it's something else, try to convert
    try:
        return str(timestamp)
    except:
        return None


def serialize_doc(doc_dict: dict) -> dict:
    """
    Takes a Firestore document dict
    Converts all timestamps to ISO strings
    Returns clean dict safe for JSON response
    """
    result = {}
    for key, value in doc_dict.items():
        if hasattr(value, 'isoformat'):
            # It's a timestamp/datetime
            result[key] = timestamp_to_iso(value)
        elif isinstance(value, dict):
            # Recursively handle nested dicts (like onboarding, preferences)
            result[key] = serialize_doc(value)
        else:
            result[key] = value
    return result


# ── Agentic query helpers ────────────────────────────────────────────────────

def sum_month_expense(db, uid: str, month_key: str) -> float:
    """Sum all confirmed expense transactions for the given month."""
    docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("monthKey", "==", month_key)
        .where("type", "==", "expense")
        .where("status", "==", "confirmed")
        .stream()
    )
    total = 0.0
    for doc in docs:
        data = doc.to_dict()
        if not data.get("isDeleted", False):
            total += data.get("amount", 0.0)
    return total


def sum_category_expense(db, uid: str, category: str, month_key: str) -> float:
    """Sum all confirmed expense transactions for a category in the given month."""
    docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("monthKey", "==", month_key)
        .where("type", "==", "expense")
        .where("status", "==", "confirmed")
        .where("category", "==", category)
        .stream()
    )
    total = 0.0
    for doc in docs:
        data = doc.to_dict()
        if not data.get("isDeleted", False):
            total += data.get("amount", 0.0)
    return total


def fetch_budget(db, uid: str, category: str, month_key: str):
    """
    Fetch the budget document for a given category + monthKey.
    Returns dict with 'id' included, or None if not found.
    """
    docs = list(
        db.collection("users").document(uid).collection("budgets")
        .where("category", "==", category)
        .where("monthKey", "==", month_key)
        .limit(1)
        .stream()
    )
    if not docs:
        return None
    data = docs[0].to_dict()
    data["id"] = docs[0].id
    return data


def sum_month_income(db, uid: str, month_key: str) -> float:
    """Sum all confirmed income transactions for the given month."""
    docs = (
        db.collection("users").document(uid).collection("transactions")
        .where("monthKey", "==", month_key)
        .where("type", "==", "income")
        .where("status", "==", "confirmed")
        .stream()
    )
    total = 0.0
    for doc in docs:
        data = doc.to_dict()
        if not data.get("isDeleted", False):
            total += data.get("amount", 0.0)
    return total


# ── Date helpers for filtering ───────────────────────────────────────────────

def is_today(timestamp) -> bool:
    """Check if a Firestore timestamp falls on today (UTC)."""
    if timestamp is None:
        return False
    try:
        now = datetime.now(timezone.utc)
        if hasattr(timestamp, "date"):
            ts_date = timestamp.date() if timestamp.tzinfo else timestamp.replace(tzinfo=timezone.utc).date()
        else:
            return False
        return ts_date == now.date()
    except Exception:
        return False


def is_in_current_week(timestamp) -> bool:
    """Check if a Firestore timestamp falls within the current ISO week (UTC)."""
    if timestamp is None:
        return False
    try:
        now = datetime.now(timezone.utc)
        if hasattr(timestamp, "isocalendar"):
            if timestamp.tzinfo is None:
                timestamp = timestamp.replace(tzinfo=timezone.utc)
            ts_year, ts_week, _ = timestamp.isocalendar()
            now_year, now_week, _ = now.isocalendar()
            return ts_year == now_year and ts_week == now_week
        return False
    except Exception:
        return False


def is_in_current_month(timestamp) -> bool:
    """Check if a Firestore timestamp falls within the current month (UTC)."""
    if timestamp is None:
        return False
    try:
        now = datetime.now(timezone.utc)
        if hasattr(timestamp, "year"):
            if timestamp.tzinfo is None:
                timestamp = timestamp.replace(tzinfo=timezone.utc)
            return timestamp.year == now.year and timestamp.month == now.month
        return False
    except Exception:
        return False


def get_today_date_range():
    """
    Returns (start_of_today_utc, end_of_today_utc) as timezone-aware datetimes.
    start = midnight today UTC, end = now (UTC).
    """
    now = datetime.now(timezone.utc)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return start, now


def get_week_date_range():
    """
    Returns (7_days_ago_midnight_utc, now_utc) as timezone-aware datetimes.
    Covers the last 7 full days including today.
    """
    from datetime import timedelta
    now = datetime.now(timezone.utc)
    start = (now - timedelta(days=6)).replace(hour=0, minute=0, second=0, microsecond=0)
    return start, now


# ── Temporal month-key resolver ──────────────────────────────────────────────

# Month-name lookup: English full/abbreviated + Nepali romanized
_MONTH_NAME_MAP = {
    "january": 1,   "jan": 1,
    "february": 2,  "feb": 2,
    "march": 3,     "mar": 3,
    "april": 4,     "apr": 4,
    "may": 5,
    "june": 6,      "jun": 6,
    "july": 7,      "jul": 7,
    "august": 8,    "aug": 8,
    "september": 9, "sep": 9,  "sept": 9,
    "october": 10,  "oct": 10,
    "november": 11, "nov": 11,
    "december": 12, "dec": 12,
}

# Phrases that mean "previous month"
_LAST_MONTH_KEYWORDS = [
    "last month", "previous month", "prev month",
    "pahila ko mahina", "aghillo mahina", "gata mahina",
    "hijo ko mahina",
]


def resolve_month_key(raw: str) -> str:
    """
    Convert a temporal keyword, month name, or YYYY-MM string into a
    valid 'YYYY-MM' month key.

    Supported inputs:
      - "last month" / "previous month" / Nepali equivalents → previous calendar month
      - Month name ("January", "march", "apr") → that month in the current year
        (or prior year if the month hasn't occurred yet this year)
      - "YYYY-MM" pass-through (e.g. "2026-03")
      - None / empty / unrecognized → current month

    Returns:
        str: A 'YYYY-MM' string.
    """
    if not raw or not isinstance(raw, str):
        return get_current_month_key()

    cleaned = raw.strip().lower()

    # ── Direct YYYY-MM format ────────────────────────────────────────────
    if len(cleaned) == 7 and cleaned[4] == "-":
        try:
            y, m = int(cleaned[:4]), int(cleaned[5:])
            if 1 <= m <= 12 and 2000 <= y <= 2100:
                return cleaned
        except ValueError:
            pass

    # ── "Last month" / "previous month" keywords ─────────────────────────
    for phrase in _LAST_MONTH_KEYWORDS:
        if phrase in cleaned:
            now = datetime.now(timezone.utc)
            if now.month == 1:
                return f"{now.year - 1}-12"
            return f"{now.year}-{now.month - 1:02d}"

    # ── Specific month name ("April", "jan", "march") ────────────────────
    for name, month_num in _MONTH_NAME_MAP.items():
        if name in cleaned:
            now = datetime.now(timezone.utc)
            # If the month hasn't occurred yet this year, use last year
            year = now.year if month_num <= now.month else now.year - 1
            return f"{year}-{month_num:02d}"

    # ── Fallback: return as-is if it looks like a monthKey, else current ──
    return get_current_month_key()