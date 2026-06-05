from enum import Enum


class ExpenseCategoryEnum(str, Enum):
    FOOD = "Food"
    TRANSPORT = "Transport"
    RENT = "Rent"
    EDUCATION = "Education"
    SHOPPING = "Shopping"
    HEALTH = "Health"
    ENTERTAINMENT = "Entertainment"
    BILLS = "Bills"
    INCOME = "income"   # accepted for income-type notification transactions
    OTHER = "Other"


EXPENSE_CATEGORIES: list[str] = [
    "Food",
    "Transport",
    "Rent",
    "Education",
    "Shopping",
    "Health",
    "Entertainment",
    "Bills",
    "Other",
    "income",   # valid category for income-type notifications / transactions
]

DEFAULT_EXPENSE_CATEGORY = "Other"


def is_valid_expense_category(category: str) -> bool:
    """Check if a category string is valid for expenses or income notifications."""
    return category in EXPENSE_CATEGORIES


def normalize_expense_category(category: str) -> str:
    """
    Normalize a category string from an AI response or notification parser.

    Handles the literal string 'income' (and common variants) so that
    income-type notifications are never incorrectly coerced to 'Other'.
    Any other unrecognized value falls back to 'Other'.
    """
    if category in EXPENSE_CATEGORIES:
        return category

    # Case-insensitive exact match against the full list.
    for valid_cat in EXPENSE_CATEGORIES:
        if category.strip().lower() == valid_cat.lower():
            return valid_cat

    # Explicit income signal words — map to the canonical "income" label.
    if category.strip().lower() in ("income", "income_log", "salary", "salary_credit"):
        return "income"

    return DEFAULT_EXPENSE_CATEGORY