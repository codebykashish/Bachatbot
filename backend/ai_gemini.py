import os
import json
import logging
import google.generativeai as genai
from google.api_core.exceptions import ResourceExhausted, ServiceUnavailable, InternalServerError, DeadlineExceeded
from ai_prompts import SYSTEM_PROMPT, _NOTIFICATION_PROMPT

logger = logging.getLogger("bachatbot.ai_gemini")

def call_gemini_chat(
    user_message: str,
    first_name: str = "User",
    is_first_message: bool = False,
    missing_budget_categories: list[str] | None = None,
    history: list[dict] | None = None,
    overall_health_status: str | None = None,
    top_risk_category: str | None = None,
    at_risk_goal: dict | None = None,
    financial_context: dict | None = None,
) -> str:
    """
    Calls Gemini API with the given context and returns the raw response text.
    Raises exceptions on rate limit, quota, timeout, etc., which should be caught by the orchestrator.
    """
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise ValueError("GEMINI_API_KEY is not set.")
        
    genai.configure(api_key=api_key)

    at_risk_goal_line = "none"
    if at_risk_goal and at_risk_goal.get("name"):
        shortfall = at_risk_goal.get("shortfall")
        at_risk_goal_line = (
            f"{at_risk_goal['name']} short by Rs {round(shortfall)}"
            if isinstance(shortfall, (int, float))
            else at_risk_goal["name"]
        )

    context_block = (
        f"\n--- USER CONTEXT ---\n"
        f"FirstName: {first_name}\n"
        f"FirstMessage: {str(is_first_message).lower()}\n"
        f"MissingBudgetCategories: {json.dumps(missing_budget_categories or [])}\n"
        f"HealthStatus: {overall_health_status or 'unknown'}\n"
        f"TopRiskCategory: {top_risk_category or 'none'}\n"
        f"AtRiskGoal: {at_risk_goal_line}\n"
        f"--- END CONTEXT ---\n"
    )

    # Build the FinancialContext block from real engine data
    fin_block = ""
    if financial_context:
        fc = financial_context
        budgets = fc.get("budgets", [])
        budget_lines = []
        for b in budgets:
            cat = b.get("category", "")
            limit = int(b.get("limit", 0))
            spent = int(b.get("spent", 0))
            remaining = int(b.get("remaining", 0))
            pct = round(b.get("percentUsed", 0), 1)
            budget_lines.append(f"  {cat}: limit Rs {limit} | spent Rs {spent} | remaining Rs {remaining} | {pct}%")
        budgets_str = "\n".join(budget_lines) if budget_lines else "  (no budgets set)"
        fin_block = (
            f"\n--- FINANCIAL CONTEXT (month: {fc.get('monthKey', '?')}) ---\n"
            f"Income: Rs {int(fc.get('totalIncome', 0))} "
            f"(InHand: {int(fc.get('inHand', 0))} | InBank: {int(fc.get('inBank', 0))} | Online: {int(fc.get('onlineBanking', 0))})\n"
            f"Unallocated Income: Rs {int(fc.get('unallocated', 0))} (income not yet assigned to any budget)\n"
            f"Total Spent This Month: Rs {int(fc.get('totalSpent', 0))}\n"
            f"Days Remaining: {fc.get('daysRemaining', '?')}\n"
            f"Recommended Daily Spend: Rs {int(fc.get('recommendedDailySpend', 0))} "
            f"(to stay within remaining budget for {fc.get('daysRemaining', '?')} days)\n"
            f"Budgets:\n{budgets_str}\n"
            f"--- END FINANCIAL CONTEXT ---\n"
        )

    instruction = f"{SYSTEM_PROMPT}\n{context_block}{fin_block}"

    request_model = genai.GenerativeModel(
        "gemini-2.5-flash",
        system_instruction=instruction,
    )

    contents = []
    if history:
        for msg in history:
            role = msg.get("role")
            parts = msg.get("parts")
            if role and parts:
                contents.append({"role": role, "parts": parts})

    contents.append({"role": "user", "parts": [{"text": user_message}]})

    # This call can raise ResourceExhausted, etc.
    response = request_model.generate_content(contents)
    return response.text


def call_gemini_notification(notification_text: str) -> str:
    """
    Calls Gemini for parsing notification text.
    """
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise ValueError("GEMINI_API_KEY is not set.")
        
    genai.configure(api_key=api_key)
    
    prompt = f"{_NOTIFICATION_PROMPT}\n\nInput: \"{notification_text}\"\nOutput:"
    
    # We use gemini-2.5-flash standard for this simple extraction
    model = genai.GenerativeModel("gemini-2.5-flash")
    response = model.generate_content(prompt)
    return response.text
