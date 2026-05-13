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