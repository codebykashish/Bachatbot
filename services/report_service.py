from firebase_config import get_firestore
from schemas.categories import EXPENSE_CATEGORIES
from utils import (
    get_current_month_key,
    sum_category_expense,
    fetch_budget,
    sum_month_expense
)

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
    """
    try:
        docs = (
            db.collection("users").document(uid)
            .collection("transactions")
            .where("monthKey", "==", month_key)
            .where("type", "==", "expense")
            .where("status", "==", "confirmed")
            .stream()
        )
        
        category_totals = {}
        for doc in docs:
            data = doc.to_dict()
            if data.get("isDeleted", False):
                continue
            cat = data.get("category", "Other")
            amt = float(data.get("amount", 0.0))
            category_totals[cat] = category_totals.get(cat, 0.0) + amt
            
        if not category_totals:
            return None
            
        top_cat = max(category_totals, key=category_totals.get)
        return {
            "category": top_cat,
            "amount": category_totals[top_cat]
        }
    except Exception as e:
        print(f"[REPORT_SERVICE] Error in get_top_spending_category: {e}")
        return None

def get_spend_alerts(db, uid: str, month_key: str) -> dict:
    """
    Returns spending insights:
    - highestCategory and highestAmount
    - overBudgetCategories: list of categories exceeding their budget
    """
    try:
        top = get_top_spending_category(db, uid, month_key)
        
        # Get all budgets for the month
        budget_docs = (
            db.collection("users").document(uid)
            .collection("budgets")
            .where("monthKey", "==", month_key)
            .stream()
        )
        
        over_budget = []
        for doc in budget_docs:
            b_data = doc.to_dict()
            limit = float(b_data.get("limit", 0.0))
            if limit <= 0:
                continue
                
            cat = b_data.get("category")
            # We use sum_category_expense to be accurate vs b_data.get("spent") which might be slightly out of sync
            spent = sum_category_expense(db, uid, cat, month_key)
            
            if spent > limit:
                over_budget.append({
                    "category": cat,
                    "spent": spent,
                    "budget": limit
                })
                
        return {
            "highestCategory": top["category"] if top else None,
            "highestAmount": top["amount"] if top else 0,
            "overBudgetCategories": over_budget
        }
    except Exception as e:
        print(f"[REPORT_SERVICE] Error in get_spend_alerts: {e}")
        return {
            "highestCategory": None,
            "highestAmount": 0,
            "overBudgetCategories": []
        }
