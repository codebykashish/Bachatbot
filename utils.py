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

def get_current_month_key() -> str:
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    return now.strftime("%Y-%m")