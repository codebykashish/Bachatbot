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

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM PROMPT — uses DATA[...]DATA with a JSON ARRAY of action objects.
# Each action object has its own intent, so mixed actions work naturally.
# ═══════════════════════════════════════════════════════════════════════════════

SYSTEM_PROMPT = f"""
You are BachatBot, a smart expense tracking assistant for Nepal.
You understand Nepali and English mixed language (Nepali romanized).

Your job is to understand what the user says and extract financial information.

RESPONSE FORMAT (ALWAYS follow this exactly):

[Your friendly reply to user in Nepali/English]

DATA[
  {{"intent": "...", ...}},
  {{"intent": "...", ...}}
]DATA

The DATA block is ALWAYS a JSON array (even for a single action).
Each element is an action object with these possible fields:
  - "intent": REQUIRED. One of:
      "expense_log", "income_log", "set_budget",
      "query_month_total", "query_category_spend", "query_budget_status",
      "undo_last_expense", "general_chat", "greeting"
  - "amount": number or null (for expense_log / income_log)
  - "category": one of {EXPENSE_CATEGORY_OPTIONS} or null
  - "type": "expense" | "income" | null
  - "limit": number or null (ONLY for set_budget — the budget limit amount)
  - "monthKey": "YYYY-MM" or null (null = current month)

RULES:
1. If user logs an expense → intent = "expense_log", type = "expense", fill amount + category.
2. If user logs income → intent = "income_log", type = "income", fill amount.
3. If user sets a budget → intent = "set_budget", fill category + limit (NOT amount). amount should be null.
4. If user asks total spending → intent = "query_month_total".
5. If user asks category spending → intent = "query_category_spend", fill category.
6. If user asks budget status → intent = "query_budget_status", fill category.
7. If user says "undo" / "pahila ko expense hata" / "tyo galat thiyo" → intent = "undo_last_expense".
8. General chat / greetings → intent = "general_chat" or "greeting".

MULTI-ACTION RULE (VERY IMPORTANT):
If the user mentions MULTIPLE actions in ONE message (e.g. two expenses, or an expense AND a budget set),
return MULTIPLE objects in the array — one per action.

Category mapping for Nepal:
- momo / khana / food = "Food"
- bus / tempo / transportation / yatayat = "Transport"
- salary / talab / income = income_log
- rent / ghar bhada = "Rent"
- pasal / shopping = "Shopping"
- doctor / ausadhi / health = "Health"
- Category must be exactly one of: {EXPENSE_CATEGORY_OPTIONS}

EXAMPLES:

User: "Momo 250"
Reply: Rs 250 Food ma save gareko chu ✅
DATA[{{"intent":"expense_log","amount":250,"category":"Food","type":"expense","limit":null,"monthKey":null}}]DATA

User: "Salary aayo 45000"
Reply: Rs 45000 income record gareko chu ✅
DATA[{{"intent":"income_log","amount":45000,"category":null,"type":"income","limit":null,"monthKey":null}}]DATA

User: "Food budget 8000 set gara"
Reply: Food budget Rs 8000 set gardai chu ✅
DATA[{{"intent":"set_budget","amount":null,"category":"Food","type":null,"limit":8000,"monthKey":null}}]DATA

User: "150 momo khaye ra 20 bus ma gayo"
Reply: Rs 150 Food ma ra Rs 20 Transport ma save gareko chu ✅
DATA[{{"intent":"expense_log","amount":150,"category":"Food","type":"expense","limit":null,"monthKey":null}},{{"intent":"expense_log","amount":20,"category":"Transport","type":"expense","limit":null,"monthKey":null}}]DATA

User: "20 food ma kharcha gare ra transport ko budget 5000 set gara"
Reply: Rs 20 Food ma save gareko chu ra Transport budget Rs 5000 set gareko chu ✅
DATA[{{"intent":"expense_log","amount":20,"category":"Food","type":"expense","limit":null,"monthKey":null}},{{"intent":"set_budget","amount":null,"category":"Transport","type":null,"limit":5000,"monthKey":null}}]DATA

User: "Yo mahina total kharcha kati bhayo?"
Reply: Yo mahina ko total kharcha check gardai chu.
DATA[{{"intent":"query_month_total","amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}]DATA

User: "Food ma kati spend gareko chu?"
Reply: Food ko spend check gardai chu.
DATA[{{"intent":"query_category_spend","amount":null,"category":"Food","type":null,"limit":null,"monthKey":null}}]DATA

User: "Food budget kati cha?"
Reply: Food budget status check gardai chu.
DATA[{{"intent":"query_budget_status","amount":null,"category":"Food","type":null,"limit":null,"monthKey":null}}]DATA

User: "undo"
Reply: Pahilo ko expense undo gardai chu.
DATA[{{"intent":"undo_last_expense","amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}]DATA

User: "Hello"
Reply: Namaste! Ma BachatBot chu. Timro kharcha track garna ready chu 😊
DATA[{{"intent":"greeting","amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}]DATA
"""


def parse_gemini_response(response_text: str) -> list:
    """
    Extract the DATA[...]DATA block from Gemini's response.
    Returns a list of action dicts, each with: intent, amount, category, type, limit, monthKey.
    Handles both:
      - New array format: DATA[...]DATA
      - Legacy single-object format: DATA{...}DATA (wrapped into a one-element list)
    """
    # ── Try new array format first: DATA[...]DATA ────────────────────────
    array_pattern = r'DATA\[(.*?)\]DATA'
    array_match = re.search(array_pattern, response_text, re.DOTALL)

    if array_match:
        try:
            json_str = "[" + array_match.group(1) + "]"
            actions = json.loads(json_str)
            if isinstance(actions, list):
                for action in actions:
                    if action.get("category"):
                        action["category"] = normalize_expense_category(action["category"])
                return actions
        except json.JSONDecodeError as e:
            print(f"[GEMINI] Array parse failed: {e}")

    # ── Fallback: legacy single-object DATA{{...}}DATA ───────────────────
    obj_pattern = r'DATA\{(.*?)\}DATA'
    obj_match = re.search(obj_pattern, response_text, re.DOTALL)

    if obj_match:
        try:
            json_str = "{" + obj_match.group(1) + "}"
            data = json.loads(json_str)

            if data.get("category"):
                data["category"] = normalize_expense_category(data["category"])

            # If legacy format had an "items" array, expand each into its own action
            raw_items = data.get("items")
            if raw_items and isinstance(raw_items, list) and len(raw_items) > 0:
                actions = []
                for item in raw_items:
                    if item.get("category"):
                        item["category"] = normalize_expense_category(item["category"])
                    actions.append({
                        "intent": data.get("intent", "expense_log"),
                        "amount": item.get("amount"),
                        "category": item.get("category"),
                        "type": item.get("type", data.get("type")),
                        "limit": None,
                        "monthKey": data.get("monthKey"),
                    })
                return actions

            # Single action
            return [data]
        except json.JSONDecodeError as e:
            print(f"[GEMINI] Object parse failed: {e}")

    # ── Nothing matched → general chat ───────────────────────────────────
    return [{
        "intent": "general_chat",
        "amount": None,
        "category": None,
        "type": None,
        "limit": None,
        "monthKey": None,
    }]


def get_reply_text(response_text: str) -> str:
    """
    Extract the friendly reply part (everything before the DATA block).
    """
    # Try DATA[ first (new format)
    if "DATA[" in response_text:
        return response_text.split("DATA[")[0].strip()
    # Fallback to DATA{ (legacy)
    if "DATA{" in response_text:
        return response_text.split("DATA{")[0].strip()
    return response_text.strip()


async def process_chat_message(user_message: str) -> dict:
    """
    Send user message to Gemini, parse response.
    Returns dict with:
      - reply: str (friendly text)
      - actions: list of action dicts
    """
    try:
        api_key = os.getenv("GEMINI_API_KEY")
        if not api_key:
            print("[ERROR] GEMINI_API_KEY is missing from .env file!")
            return {
                "reply": "API Key missing",
                "actions": [{"intent": "error", "amount": None, "category": None,
                             "type": None, "limit": None, "monthKey": None}],
            }

        full_prompt = f"{SYSTEM_PROMPT}\n\nUser: {user_message}"
        response = model.generate_content(full_prompt)
        response_text = response.text

        actions = parse_gemini_response(response_text)
        reply_text = get_reply_text(response_text)

        print(f"[GEMINI] Parsed {len(actions)} action(s): {[a.get('intent') for a in actions]}")

        return {
            "reply": reply_text,
            "actions": actions,
        }

    except Exception as e:
        print(f"[ERROR] GEMINI SYSTEM ERROR: {str(e)}")
        return {
            "reply": f"Internal Error: {str(e)}",
            "actions": [{"intent": "general_chat", "amount": None, "category": None,
                         "type": None, "limit": None, "monthKey": None}],
        }