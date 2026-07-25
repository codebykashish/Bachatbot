import os
import json
import logging
import requests
from ai_prompts import SYSTEM_PROMPT, _NOTIFICATION_PROMPT

logger = logging.getLogger("bachatbot.ai_ollama")

def call_ollama_chat(
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
    Calls Ollama API with the given context and returns the raw response text.
    Uses OLLAMA_BASE_URL and OLLAMA_MODEL from .env.
    Raises exceptions (like requests.exceptions.RequestException) on network errors.
    """
    base_url = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
    model_name = os.getenv("OLLAMA_MODEL", "gemma4:e2b")

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

    messages = [
        {"role": "system", "content": instruction}
    ]

    if history:
        for msg in history:
            role = msg.get("role")
            # Gemini history might use 'model' instead of 'assistant'
            if role == "model":
                role = "assistant"
                
            parts = msg.get("parts")
            if role and parts:
                text_content = ""
                for part in parts:
                    text_content += part.get("text", "")
                messages.append({"role": role, "content": text_content})

    messages.append({"role": "user", "content": user_message})

    payload = {
        "model": model_name,
        "messages": messages,
        "stream": False
    }

    response = requests.post(
        f"{base_url}/api/chat",
        json=payload,
        timeout=120 # Increased timeout for local models
    )
    
    response.raise_for_status()
    result = response.json()
    
    return result.get("message", {}).get("content", "")


def call_ollama_notification(notification_text: str) -> str:
    """
    Calls Ollama for parsing notification text.
    """
    base_url = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
    model_name = os.getenv("OLLAMA_MODEL", "gemma4:e2b")
    
    prompt = f"{_NOTIFICATION_PROMPT}\n\nInput: \"{notification_text}\"\nOutput:"
    
    payload = {
        "model": model_name,
        "prompt": prompt,
        "stream": False
    }
    
    response = requests.post(
        f"{base_url}/api/generate",
        json=payload,
        timeout=120
    )
    
    response.raise_for_status()
    result = response.json()
    return result.get("response", "")
