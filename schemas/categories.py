from enum import Enum

class ExpenseCategoryEnum(str, Enum):
    FOOD = "Food"
    TRANSPORTATION = "Transportation"
    RENT = "Rent"
    ENTERTAINMENT = "Entertainment"
    MISCELLANEOUS = "Miscellaneous"
    
EXPENSE_CATEGORIES: list[str] = [ "Food",
    "Transportation",
    "Rent",
    "Entertainment",
    "Miscellaneous",
]

DEFAULT_EXPENSE_CATEGORY = "Miscellaneous"

class IncomeSourceEnum(str, Enum):
    SALARY = 'Salary'
    FREELANCE = 'Freelance'
    GIFT = 'Gift'
    BUSINESS = 'Business'
    OTHER = 'Other'

INCOME_SOURCES: list[str] = [
    "Salary",
    "Freelance",
    "Gift",
    "Business",
    "Other",
]

DEFAULT_INCOME_SOURCE = 'Other'

class SavingMethodEnum(str, Enum):
    BANK_DEPOSIT = "Bank Deposit"
    CASH = "Cash"
    INVESTMENT = "Investment"
    DIGITAL_WALLET = "Digital Wallet"
    OTHER = "Other"

SAVING_METHODS: list[str] = [
    "Bank Deposit",
    "Cash",
    "Investment",
    "Digital Wallet",
    "Other",
]

DEFAULT_SAVING_METHOD = "Other"

def is_valid_expense_category(category: str) -> bool:
    """Check if a category string is valid for expenses."""
    return category in EXPENSE_CATEGORIES

def is_valid_income_source(source: str) -> bool:
    """Check if a source string is valid for income."""
    return source in INCOME_SOURCES

def is_valid_saving_method(method: str) -> bool:
    """Check if a method string is valid for savings."""
    return method in SAVING_METHODS

def normalize_expense_category(category: str) -> str:
    """
    Normalize expense category from AI response.
    If AI returns something unrecognized, fall back to Miscellaneous.
    """
    if category in EXPENSE_CATEGORIES:
        return category
    
    for valid_cat in EXPENSE_CATEGORIES:
        if category.strip().lower() == valid_cat.lower():
            return valid_cat
        
    return DEFAULT_EXPENSE_CATEGORY

def normalize_income_source(source: str) -> str:
    """
    Normalize income source from AI response.
    If AI returns something unrecognized, fall back to Other.
    """
    if source in INCOME_SOURCES:
        return source
    
    for valid_source in INCOME_SOURCES:
        if source.strip().lower() == valid_source.lower():
            return valid_source
        
    return DEFAULT_INCOME_SOURCE

def normalize_saving_method(method: str) -> str:
    """
    Normalize saving method from AI response.
    If AI returns something unrecognized, fall back to Other.
    """
    if method in SAVING_METHODS:
        return method
    
    for valid_method in SAVING_METHODS:
        if method.strip().lower() == valid_method.lower():
            return valid_method
        
    return DEFAULT_SAVING_METHOD