"""
notification_service.py
=======================
Helper utilities for notification-based transaction handling.

Key hook: resolve_category_from_receiver_name
  - Currently always returns None (no mapping configured).
  - In the future, plug in a name→category mapping table here
    (e.g. from Firestore config, or a hardcoded dict) without touching
    any other part of the codebase.

Parse helper: parse_esewa_receiver_name
  - Extracts the receiver name from a raw eSewa / Khalti notification string.
  - Example: "eSewa 100 transferred to Sandar Momo" → "Sandar Momo"
"""

import re


# ── Name → Category mapping hook ──────────────────────────────────────────────

# Future: populate this dict from a Firestore config collection, or from an
# admin panel. For now it is empty — no assumptions are made.
_RECEIVER_CATEGORY_MAP: dict[str, str] = {}


def resolve_category_from_receiver_name(receiver_name: str | None) -> str | None:
    """
    Given a receiver/merchant name, return a suggested expense category
    (e.g. 'Food', 'Transport') or None if no mapping is known.

    This function is the single extension point for name→category mapping.
    Currently always returns None. To add mappings, update _RECEIVER_CATEGORY_MAP
    above — the format is {"Sandar Momo": "Food", "Bus Stand": "Transport", ...}.
    Keys are matched case-insensitively.

    Args:
        receiver_name: The merchant / receiver name parsed from the notification.

    Returns:
        A valid EXPENSE_CATEGORIES string, or None.
    """
    if not receiver_name:
        return None

    cleaned = receiver_name.strip().lower()
    for name, category in _RECEIVER_CATEGORY_MAP.items():
        if name.lower() == cleaned:
            return category

    # Partial / substring match as a secondary heuristic (disabled by default)
    # Uncomment the block below if you want fuzzy matching later:
    # for name, category in _RECEIVER_CATEGORY_MAP.items():
    #     if name.lower() in cleaned or cleaned in name.lower():
    #         return category

    return None


# ── Raw notification text parser ───────────────────────────────────────────────

# Patterns for common Nepali payment apps
_TRANSFER_PATTERNS = [
    # "eSewa 100 transferred to Sandar Momo"
    re.compile(r"transferred\s+to\s+(.+?)(?:\.|,|$)", re.IGNORECASE),
    # "Payment of Rs 100 to Sandar Momo"
    re.compile(r"(?:payment|paid|sent)\s+(?:of\s+)?(?:rs\.?\s*\d+\s+)?to\s+(.+?)(?:\.|,|$)", re.IGNORECASE),
    # "Khalti: Rs 100 sent to Sandar Momo successfully"
    re.compile(r"sent\s+to\s+(.+?)(?:\s+successfully|\.|,|$)", re.IGNORECASE),
    # "Merchant: Sandar Momo"
    re.compile(r"merchant[:\s]+(.+?)(?:\.|,|$)", re.IGNORECASE),
    # "To: Sandar Momo" (some bank notifications)
    re.compile(r"^To[:\s]+(.+?)(?:\.|,|$)", re.IGNORECASE | re.MULTILINE),
]


def parse_receiver_name(raw_text: str) -> str | None:
    """
    Attempt to extract the receiver / merchant name from a raw notification string.

    Args:
        raw_text: The full raw notification text, e.g.
                  "eSewa 100 transferred to Sandar Momo"

    Returns:
        Extracted receiver name string, or None if not found.
    """
    if not raw_text:
        return None

    for pattern in _TRANSFER_PATTERNS:
        m = pattern.search(raw_text)
        if m:
            name = m.group(1).strip().rstrip(".,;!?")
            if name:
                return name

    return None
