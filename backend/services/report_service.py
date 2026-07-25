from firebase_config import get_firestore
from schemas.categories import EXPENSE_CATEGORIES
from utils import (
    get_current_month_key,
    sum_category_expense,
    fetch_budget,
    sum_month_expense
)
from services.financial_engine import get_summary

def get_missing_budget_categories(db, uid: str, month_key: str) -> list[str]:
    """
    Returns a list of categories that don't have a budget set for the given month.
    A budget is considered missing if no document exists or limit is 0.
    """
    try:
        budget_docs = (
            db.collection("users").document(uid)
            .collection("budgets")
            .where("monthKey", "==", month_key)
            .stream()
        )
        
        # Categories that HAVE a budget set (> 0)
        existing_cats = {
            d.to_dict().get("category") 
            for d in budget_docs 
            if d.to_dict().get("limit", 0) > 0
        }
        
        # Missing are those in EXPENSE_CATEGORIES but NOT in existing_cats
        missing = [c for c in EXPENSE_CATEGORIES if c not in existing_cats]
        return missing
    except Exception as e:
        print(f"[REPORT_SERVICE] Error in get_missing_budget_categories: {e}")
        return []

def get_top_spending_category(db, uid: str, month_key: str) -> dict:
    """
    Finds the category with the highest spending in the given month.
    Returns e.g. {"category": "Food", "amount": 1500} or None.

    Reads from the Financial Engine's summary instead of independently
    re-scanning and re-summing transactions — this used to be a second,
    parallel aggregation of the exact same data the Engine already
    computes (`categoryRemaining[cat].spent`).
    """
    try:
        summary = get_summary(db, uid, month_key)
        category_remaining = summary.get("categoryRemaining", {}) or {}
        if not category_remaining:
            return None

        top_cat, top_data = max(
            category_remaining.items(), key=lambda kv: kv[1].get("spent", 0.0)
        )
        if top_data.get("spent", 0.0) <= 0:
            return None
        return {"category": top_cat, "amount": top_data.get("spent", 0.0)}
    except Exception as e:
        print(f"[REPORT_SERVICE] Error in get_top_spending_category: {e}")
        return None

def get_spend_alerts(db, uid: str, month_key: str) -> dict:
    """
    Returns spending insights:
    - highestCategory and highestAmount
    - overBudgetCategories: list of categories exceeding their budget

    Reads from the Financial Engine's summary for both. Previously this
    read budgets.spent (the deprecated mutable counter — the docstring
    even used to note it "might be slightly out of sync" and worked
    around that locally instead of fixing the root cause); now it reads
    categoryRemaining, which the Engine already derives from confirmed
    transactions, so there's nothing left to be out of sync with.
    """
    try:
        summary = get_summary(db, uid, month_key)
        category_remaining = summary.get("categoryRemaining", {}) or {}

        top = None
        if category_remaining:
            top_cat, top_data = max(
                category_remaining.items(), key=lambda kv: kv[1].get("spent", 0.0)
            )
            if top_data.get("spent", 0.0) > 0:
                top = {"category": top_cat, "amount": top_data.get("spent", 0.0)}

        over_budget = [
            {
                "category": cat,
                "spent": data.get("spent", 0.0),
                "budget": data.get("limit", 0.0),
            }
            for cat, data in category_remaining.items()
            if data.get("limit", 0.0) > 0 and data.get("spent", 0.0) > data.get("limit", 0.0)
        ]

        return {
            "highestCategory": top["category"] if top else None,
            "highestAmount": top["amount"] if top else 0,
            "overBudgetCategories": over_budget,
        }
    except Exception as e:
        print(f"[REPORT_SERVICE] Error in get_spend_alerts: {e}")
        return {
            "highestCategory": None,
            "highestAmount": 0,
            "overBudgetCategories": []
        }
