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
    instruction = f"{SYSTEM_PROMPT}\n{context_block}"

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
