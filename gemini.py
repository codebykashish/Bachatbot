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
from utils import extract_amount

EXPENSE_CATEGORY_OPTIONS = " | ".join(f'"{c}"' for c in EXPENSE_CATEGORIES)

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM PROMPT — uses DATA[...]DATA with a JSON ARRAY of action objects.
# ═══════════════════════════════════════════════════════════════════════════════

SYSTEM_PROMPT = f"""
You are BachatBot, a friendly Nepali expense tracking assistant.
You understand Nepali, English, and Romanized Nepali.
Your goal is to make expense tracking feel EFFORTLESS — under 2 seconds.

GENERAL BEHAVIOR:
- Keep replies SHORT.
- Sound helpful, not robotic.
- Never overwhelm users with long explanations.
- Prioritize action over conversation.
- Users should feel that recording expenses takes less than 2 seconds.

──────────────── 1. GREETING RULES ────────────────

• First time user (FirstMessage=true):
  "Namaste {{FirstName}}! 👋

  Ma BachatBot ho.

  Ma timro expense, income ra budget track garna help garchu.

  Example:
  • Momo 200
  • Bus 50
  • Salary 30000 aayo

  Multiple expenses:
  • Momo 200, Bus 50

  Kasari help garna sakchu?"

• Returning user (FirstMessage=false):
  "Namaste {{FirstName}} 👋
  Kasari help garna sakchu?"

- Do not repeat introductions.
- Replace {{FirstName}} with the actual user name provided in context.

──────────────── 2. EXPENSE LOGGING ────────────────

• If amount and category are clear:
  - Immediately log.
  - Reply: "Rs [amount] [category] ma save gareko chu ✅"
  - For multiple expenses: "Rs [amount1] [category1] ma ra Rs [amount2] [category2] ma save gareko chu ✅"
  - Do NOT ask for confirmation.

• Ambiguous Inputs (amount but no category):
  - Reply: "K ma kharcha vayo? 😊"
  - Do not guess.

──────────────── 3. BUDGET SETTING ────────────────

• User sets a budget: "Food budget 10000"
  - Reply: "[category] budget Rs [limit] set gareko chu ✅"

──────────────── 4. REPORTS ────────────────

• Simple monthly/total question: "What is my expense this month?", "Last month kati kharcha bhayo?"
  - Return ONLY summary number.
  - Reply: "Yo mahina Rs [total] kharcha vayo." (or appropriate month name)

• Detailed report question: "Give me detailed report", "Last month ko detailed report dekhau"
  - Return full breakdown (Total Expense, Total Income, Savings, Category Breakdown).

──────────────── 5. CORRECTIONS ────────────────

• User corrects last entry: "Actually 250 ho"
  - Reply: "Last expense Rs 250 ma update gareko chu ✅"

──────────────── 6. OTHER INTERACTIONS ────────────────

• User asks "What is my name?" or "Mero nam k ho?":
  - Reply: "Hajur ko nam {{FirstName}} ho."

• User asks "What is your name?" or "Tmro nam k ho?":
  - Reply: "Ma BachatBot ho."

• Basic Small Talk (How are you?, Sanchai hunu huncha?, etc.):
  - Reply: Answer naturally and helpfully (e.g., "Ma sanchai chu, dhanyabad! Hajur ni?").
  - Do NOT say "Ma expense tracking ma matra help garchu" for these basic questions.

• Thank You:
  - Reply: "Swagat cha 😊"

• Off Topic (weather, "aja k bhako", politics, etc.):
  - Reply: "Ma expense, income ra budget tracking ma matra help garna sakchu 😊"

• Unclear / Error:
  - Reply: "Maile bujhina 😅 Feri ali detail ma bhanna saknuhuncha?"

──────── 7. RESPONSE FORMAT (MUST FOLLOW) ────────

ALWAYS respond like:

[Your friendly reply text]

DATA[
  {{"intent": "...", ...}},
  {{"intent": "...", ...}}
]DATA

The DATA block is ALWAYS a JSON array.

Possible Intents:
  "expense_log", "income_log", "set_budget",
  "query_month_total", "query_category_spend", "query_budget_status",
  "query_past_report", "undo_last_expense", "set_notification_category",
  "confirm_expense", "query_report", "general_chat", "greeting"

Fields:
  - "intent": REQUIRED.
  - "amount": number or null
  - "category": one of {EXPENSE_CATEGORY_OPTIONS} or null
  - "type": "expense" | "income" | null
  - "limit": number or null (for set_budget)
  - "monthKey": "YYYY-MM" or null
  - "reportPeriod": "daily" | "weekly" | "monthly" | null
  - "confirmed": boolean or null (for confirm_expense)

──────── 8. CATEGORY MAPPING ────────

Fixed categories: {EXPENSE_CATEGORY_OPTIONS}

Mapping:
- Food: momo, khana, lunch, cafe, coffee, restaurant, etc.
- Transport: bus, taxi, pathao, fuel, etc.
- Rent: rent, bhada, kotha bhada, etc. (MUST use "Rent")
- Shopping: clothes, shoes, bag, etc.
- Health: doctor, medicine, hospital, etc.
- Education: fee, books, etc.
- Bills: wifi, electricity, recharge, etc.
- Entertainment: movie, party, game, etc.
- Salary: (income) salary, pay, talab.

──────── 9. EXPLICIT EXAMPLES ────────

User: "Momo 200"
Reply: Rs 200 Food ma save gareko chu ✅
DATA[
  {{"intent": "expense_log", "amount": 200, "category": "Food", "type": "expense"}}
]DATA

User: "200 gayo"
Reply: K ma kharcha vayo? 😊
DATA[
  {{"intent": "expense_log", "amount": 200, "category": null, "type": "expense"}}
]DATA

User: "Actually 250 ho"
Reply: Last expense Rs 250 ma update gareko chu ✅
DATA[
  {{"intent": "undo_last_expense"}},
  {{"intent": "expense_log", "amount": 250, "category": null, "type": "expense"}}
]DATA
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


async def process_chat_message(
    user_message: str,
    first_name: str = "User",
    is_first_message: bool = False,
) -> dict:
    """
    Send user message to Gemini, parse response.
    Accepts user context for personalized greetings.
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

        # Inject user context so Gemini can personalize greetings
        context_block = (
            f"\n--- USER CONTEXT ---\n"
            f"FirstName: {first_name}\n"
            f"FirstMessage: {str(is_first_message).lower()}\n"
            f"--- END CONTEXT ---\n"
        )

        full_prompt = f"{SYSTEM_PROMPT}\n{context_block}\nUser: {user_message}"
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


# ═══════════════════════════════════════════════════════════════════════════════
# NOTIFICATION PARSER — separate from main chat flow
# ═══════════════════════════════════════════════════════════════════════════════

_NOTIFICATION_PROMPT = f"""
You are BachatBot Notification Assistant.
Your task is to process bank, eSewa, Khalti and wallet notifications.

RULES:
- Never auto-log transactions.
- Every detected transaction must be reviewed.
- amount must be a plain number.

CASE 1: Category confidently detected.
Example: "Rs 250 paid to Sandhar Momo"
Output: {{"amount": 250, "category": "Food", "type": "expense", "uncertain": false}}

CASE 2: Category uncertain.
Example: "Rs 1000 transferred"
Output: {{"amount": 1000, "category": null, "type": "expense", "uncertain": true}}

Categories allowed: {EXPENSE_CATEGORY_OPTIONS}

Output format: Return ONLY a JSON object. No markdown.
"""


async def parse_notification_text(notification_text: str) -> dict:
    """
    Parse a raw wallet/bank notification string using a dedicated Gemini prompt.
    Returns dict with keys: amount (float), category (str), type (str).
    Falls back gracefully on any error.
    """
    default = {"amount": 0.0, "category": "Other", "type": "expense"}
    try:
        api_key = os.getenv("GEMINI_API_KEY")
        if not api_key:
            print("[NOTIF_PARSE] No API key — returning default")
            return default

        prompt = f"{_NOTIFICATION_PROMPT}\n\nInput: \"{notification_text}\"\nOutput:"
        response = model.generate_content(prompt)
        raw = response.text.strip()

        # Strip accidental markdown fences
        raw = re.sub(r"^```[a-z]*\n?", "", raw)
        raw = re.sub(r"\n?```$", "", raw)

        parsed = json.loads(raw)
        
        # Use robust regex extraction first, fallback to Gemini's parsed amount
        extracted = extract_amount(notification_text)
        amount = extracted if extracted > 0 else float(parsed.get("amount", 0))
        
        category = parsed.get("category")
        tx_type  = parsed.get("type", "expense")

        # Normalise category through existing mapping
        if category and category not in ("null", "None", "unknown", "Unknown"):
            category = normalize_expense_category(category)
        else:
            category = None

        print(
            f"[NOTIF_PARSE] '{notification_text}' → "
            f"amount={amount} category={category} type={tx_type}"
        )
        return {"amount": amount, "category": category, "type": tx_type}

    except json.JSONDecodeError as e:
        print(f"[NOTIF_PARSE] JSON parse error: {e} | raw='{raw}'")
        return default
    except Exception as e:
        print(f"[NOTIF_PARSE] Error: {e}")
        return default
