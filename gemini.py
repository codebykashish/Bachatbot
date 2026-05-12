import google.generativeai as genai
import os
from dotenv import load_dotenv
from pathlib import Path
import json
import re

print("\n" + "="*50)
print("[GEMINI] Starting initialization...")
print("="*50)

print(f"[DEBUG] Current working directory: {os.getcwd()}")

# Load .env
env_path = Path(__file__).parent / ".env"
print(f"[DEBUG] Looking for .env at: {env_path}")
print(f"[DEBUG] .env exists: {env_path.exists()}")

load_dotenv(override=True)

api_key = os.getenv("GEMINI_API_KEY")
print(f"[DEBUG] GEMINI_API_KEY loaded: {api_key is not None}")
if api_key:
    print(f"[DEBUG] API Key (first 20 chars): {api_key[:20]}...")
else:
    print("[DEBUG] [ERROR] API Key is NONE!")

if api_key:
    genai.configure(api_key=api_key)
    print("[DEBUG] [OK] Gemini configured successfully")
else:
    print("[DEBUG] [ERROR] Cannot configure Gemini - no API key")

model = genai.GenerativeModel("gemini-2.5-flash")
print("[DEBUG] [OK] Model initialized")
print("="*50 + "\n")

from schemas.categories import (
    EXPENSE_CATEGORIES,
    normalize_expense_category,
)

EXPENSE_CATEGORY_OPTIONS = " | ".join(f'"{c}"' for c in EXPENSE_CATEGORIES)

SYSTEM_PROMPT = f"""
You are BachatBot, a smart expense tracking assistant for Nepal.
You understand Nepali and English mixed language (Nepali romanized).

Your job is to understand what the user says and extract financial information.

Always respond in this format:

[Your friendly reply to user]

DATA{{
  "intent": "expense_log" | "income_log" | "set_budget" | "query_month_total" | "query_category_spend" | "query_budget_status" | "general_chat" | "greeting",
  "amount": 250 | null,
  "limit": 8000 | null,
  "category": {EXPENSE_CATEGORY_OPTIONS} | null,
  "type": "expense" | "income" | null,
  "monthKey": "2026-05" | null,
  "description": "original user message"
}}DATA

INTENTS:
- expense_log: User logs an expense (e.g. "Momo 250", "bus ma 30 gayo")
- income_log: User logs income (e.g. "Salary aayo 45000", "5000 paisa aayo")
- set_budget: User wants to set/update a budget for a category (e.g. "Food budget 8000 set gara")
- query_month_total: User asks total spending this month (e.g. "Yo mahina kati kharcha bhayo?")
- query_category_spend: User asks spending in a specific category (e.g. "Food ma kati spend gareko chu?")
- query_budget_status: User asks budget status for a category (e.g. "Food budget kati cha?")
- general_chat: General conversation
- greeting: Hello/hi/namaste

Rules:
- If user says expense related thing → intent = expense_log, type = "expense"
- If user says income related thing → intent = income_log, type = "income"
- If user wants to set a budget → intent = set_budget. Put the budget amount in "limit" (NOT in "amount"). "amount" should be null.
- If user asks total spending → intent = query_month_total
- If user asks spending in a category → intent = query_category_spend
- If user asks budget status → intent = query_budget_status
- If user is just chatting → intent = general_chat
- If user says hello/hi/namaste → intent = greeting
- Always respond friendly in Nepali or English based on user language
- For Nepal context: momo=Food, bus/tempo=Transportation, salary/tlab=income
- Category must be exactly one of: {EXPENSE_CATEGORY_OPTIONS}
- For income_log, category can be null (income doesn't need expense category)
- Amount and limit must be a number only, no Rs or rupees text
- monthKey should be null unless user specifies a specific month

Examples:

User: "Momo 250"
Reply: Rs 250 Food ma save gareko chu ✅
DATA{{"intent": "expense_log", "amount": 250, "limit": null, "category": "Food", "type": "expense", "monthKey": null, "description": "Momo 250"}}DATA

User: "Salary aayo 45000"
Reply: Rs 45000 income record gareko chu ✅
DATA{{"intent": "income_log", "amount": 45000, "limit": null, "category": null, "type": "income", "monthKey": null, "description": "Salary aayo 45000"}}DATA

User: "Food budget 8000 set gara yo mahina"
Reply: Food budget Rs 8000 set gardai chu.
DATA{{"intent": "set_budget", "amount": null, "limit": 8000, "category": "Food", "type": null, "monthKey": null, "description": "Food budget 8000 set gara yo mahina"}}DATA

User: "Food ma kati spend gareko chu?"
Reply: Timro Food ko spend check gardai chu.
DATA{{"intent": "query_category_spend", "amount": null, "limit": null, "category": "Food", "type": null, "monthKey": null, "description": "Food ma kati spend gareko chu?"}}DATA

User: "Yo mahina total kharcha kati bhayo?"
Reply: Yo mahina ko total kharcha check gardai chu.
DATA{{"intent": "query_month_total", "amount": null, "limit": null, "category": null, "type": null, "monthKey": null, "description": "Yo mahina total kharcha kati bhayo?"}}DATA

User: "Food budget kati cha?"
Reply: Food budget status check gardai chu.
DATA{{"intent": "query_budget_status", "amount": null, "limit": null, "category": "Food", "type": null, "monthKey": null, "description": "Food budget kati cha?"}}DATA

User: "Hello"
Reply: Namaste! Ma BachatBot chu. Timro kharcha track garna ready chu 😊
DATA{{"intent": "greeting", "amount": null, "limit": null, "category": null, "type": null, "monthKey": null, "description": "Hello"}}DATA
"""


def parse_gemini_response(response_text: str) -> dict:
    """
    Extract the DATA{{...}}DATA block from Gemini response.
    Returns dict with intent, amount, limit, category, type, monthKey, description.
    """
    # Find DATA{...}DATA block
    pattern = r'DATA\{(.*?)\}DATA'
    match = re.search(pattern, response_text, re.DOTALL)

    if not match:
        # No structured data found, treat as general chat
        return {
            "intent": "general_chat",
            "amount": None,
            "limit": None,
            "category": None,
            "type": None,
            "monthKey": None,
            "description": ""
        }

    try:
        json_str = "{" + match.group(1) + "}"
        data = json.loads(json_str)

        # Normalize expense category
        if data.get("category"):
            data["category"] = normalize_expense_category(data["category"])

        return data
    except json.JSONDecodeError:
        return {
            "intent": "general_chat",
            "amount": None,
            "limit": None,
            "category": None,
            "type": None,
            "monthKey": None,
            "description": ""
        }


def get_reply_text(response_text: str) -> str:
    """
    Extract just the friendly reply part (before DATA block).
    """
    if "DATA{" in response_text:
        reply = response_text.split("DATA{")[0].strip()
        return reply
    return response_text.strip()


async def process_chat_message(user_message: str) -> dict:
    try:
        # Check if API Key exists
        api_key = os.getenv("GEMINI_API_KEY")
        if not api_key:
            print("[ERROR] GEMINI_API_KEY is missing from .env file!")
            return {
                "reply": "API Key missing",
                "intent": "error",
                "amount": None,
                "limit": None,
                "category": None,
                "type": None,
                "monthKey": None,
                "description": user_message,
            }

        full_prompt = f"{SYSTEM_PROMPT}\n\nUser: {user_message}"
        response = model.generate_content(full_prompt)
        response_text = response.text

        parsed_data = parse_gemini_response(response_text)
        reply_text = get_reply_text(response_text)

        return {
            "reply": reply_text,
            "intent": parsed_data.get("intent", "general_chat"),
            "amount": parsed_data.get("amount"),
            "limit": parsed_data.get("limit"),
            "category": parsed_data.get("category"),
            "type": parsed_data.get("type"),
            "monthKey": parsed_data.get("monthKey"),
            "description": parsed_data.get("description", user_message),
        }

    except Exception as e:
        print(f"[ERROR] GEMINI SYSTEM ERROR: {str(e)}")
        return {
            "reply": f"Internal Error: {str(e)}",
            "intent": "general_chat",
            "amount": None,
            "limit": None,
            "category": None,
            "type": None,
            "monthKey": None,
            "description": user_message,
        }