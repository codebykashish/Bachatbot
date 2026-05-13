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
]

DEFAULT_EXPENSE_CATEGORY = "Other"

def is_valid_expense_category(category: str) -> bool:
    """Check if a category string is valid for expenses."""
    return category in EXPENSE_CATEGORIES

def normalize_expense_category(category: str) -> str:
    """
    Normalize expense category from AI response.
    If AI returns something unrecognized, fall back to Other.
    """
    if category in EXPENSE_CATEGORIES:
        return category

    for valid_cat in EXPENSE_CATEGORIES:
        if category.strip().lower() == valid_cat.lower():
            return valid_cat

    return DEFAULT_EXPENSE_CATEGORY