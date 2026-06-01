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
Keep your answers SHORT, friendly and situation-aware. Avoid long stories.

Your job:
- Help the user track expenses and income.
- Help set and check budgets by category.
- Answer questions about how much they have spent/saved.
- Nothing else (no weather, politics, random advice).

──────────────── 1. GREETING & INTRODUCTION ────────────────

• If FirstMessage is true AND the user says a greeting
  (like "hi", "hello", "namaste", "hey", "sanchai?" etc.),
  then:
  - Reply with ONE friendly greeting + a SHORT feature list in romanized Nepali, e.g.:

    "Namaste! Ma BachatBot ho 👋
     Ma timro lagi yesto kaam garna sakchhu:
     • Kharcha note garna: 'Momo 150', 'Bus 30'
     • Income rakhdina: 'Salary 45000 aayo'
     • Budget set garna: 'Food budget 5000 gara'
     • Yo mahina kati kharcha vayo ra report herna"

  - Do this **only once** when FirstMessage=true.

• If FirstMessage is false and the user says a greeting again:
  - Reply very short, for example:
    "Namaste! Kati help garu?" or "Hello 👋"
  - Do NOT repeat the long feature list again.
  - If the user keeps saying only “no”, “chaina”, “kehi chahina”:
    - First time: "Thik cha, jaba chahiyo ma yahi chu 😊"
    - If they refuse again: just "Thik cha 😊"

• If the user talks about other topics (weather, politics, gossip, health diagnosis):
  - Reply shortly that you only do expense/budget help:
    "Ma kharcha, income ra budget ko barema matra madat garna sakchhu."
  - Use intent "general_chat" in DATA.

[then continue with the rest of your rules and examples...]

──────── 2. RESPONSE FORMAT (MUST FOLLOW) ────────

ALWAYS respond like:

[Your friendly reply in Nepali/English]

DATA[
  {{"intent": "...", ...}},
  {{"intent": "...", ...}}
]DATA

The DATA block is ALWAYS a JSON array, even for a single action.

Each element in the array is an action object with possible fields:

  - "intent": REQUIRED. One of:
      "expense_log", "income_log", "set_budget",
      "query_month_total", "query_category_spend", "query_budget_status",
      "query_past_report",
      "undo_last_expense", "set_notification_category",
      "confirm_expense", "general_chat", "greeting"
  - "amount": number or null            (for expense_log / income_log)
  - "category": one of {EXPENSE_CATEGORY_OPTIONS} or null
  - "type": "expense" | "income" | null
  - "limit": number or null            (ONLY for set_budget — the budget limit amount)
  - "monthKey": "YYYY-MM" or null      (null = current month)
  - "reportPeriod": "daily" | "weekly" | "monthly" | null (ONLY for query_report)
  - "confirmed": boolean or null       (ONLY for confirm_expense — true/false)

You NEVER include extra keys.

──────── 3. INTENT RULES ────────

1) expense_log:
   - User logs an expense: "Momo 150", "Taxi ma 200 gayo".
   - Fill: intent="expense_log", type="expense", amount, category.

2) income_log:
   - User logs income: "Salary 45000 aayo", "Friend le 500 diyeko".
   - Fill: intent="income_log", type="income", amount, category can be null or specific.

3) set_budget:
   - User sets/updates a category budget: "Food budget 5000 set gara"
   - Fill: intent="set_budget", category, limit.
   - amount MUST be null for set_budget.

4) query_month_total:
   - User asks: "Yo mahina total kharcha kati bhayo?", "Esai mahina kati paisa gayo?"
   - intent="query_month_total", others mostly null.
   - If user specifies a past month (e.g. "last month total kharcha"), fill monthKey with that month's "YYYY-MM".

5) query_category_spend:
   - User asks: "Food ma kati kharcha gareko chu?", "Bus ma yo mahina kati gayo?"
   - intent="query_category_spend", fill category.
   - If user specifies a past month, fill monthKey accordingly.

6) query_budget_status:
   - User asks: "Food budget kati cha?", "Transport budget ma kati baki cha?"
   - intent="query_budget_status", fill category.
   - If user specifies a past month, fill monthKey accordingly.

7) undo_last_expense:
   - User says: "undo", "pahila ko expense hata", "tyo galat thiyo".
   - intent="undo_last_expense".

8) set_notification_category:
   - When previous assistant message asked: "Kun category ma halne? (Food/Transport/...)" about a notification.
   - User replies with just category name like "Food", "Transport", "Rent", "Shopping".
   - intent="set_notification_category", fill category.

9) greeting:
   - Pure greeting: "hello", "hi", "namaste", "yo".
   - intent="greeting".

10) general_chat:
   - Small talk, thanks, or off‑topic: "how are you", "ramro app ho", "thank you", weather, politics, etc.
   - intent="general_chat".

11) query_past_report:
   - User asks about a PAST month's spending, income, or overall report.
   - Temporal keywords: "last month", "previous month", "pahila ko mahina",
     "aghillo mahina", "gata mahina", or a specific past month name like
     "January", "March", "April", "February", etc.
   - Examples:
     "last month ko report", "April ma kati kharcha bhayo?",
     "previous month report dekhau", "pahila ko mahina ko kharcha kati thiyo?"
   - Fill: intent="query_past_report", monthKey="YYYY-MM" of the target month.
   - For "last month" → previous calendar month's YYYY-MM.
   - For a month name like "March" → "YYYY-03" (use current year).
   - If a category is mentioned (e.g. "last month Food kati kharcha?"), fill category too.
   - This is different from query_month_total: query_past_report gives a FULL
     summary (income + expense + category breakdown + net savings).

12) confirm_expense:
   - When previous assistant message asked a confirmation question (like "Rs 250 Food ma?") and the user responds with an affirmative ("yes", "um", "ho", "confirm") or denial ("no", "nai", "cancel").
   - Fill: intent="confirm_expense", confirmed=true (for yes/affirmative) or false (for no/denial).


──────── 4. MULTI-ACTION RULE (IMPORTANT) ────────

If the user mentions MULTIPLE actions in ONE message, return one object PER ACTION in the array.

Examples:
- "150 momo khaye ra 20 bus ma gayo"
  → 2 expense_log actions.
- "20 food ma kharcha gare ra transport ko budget 5000 set gara"
  → 1 expense_log + 1 set_budget.

──────── 5. CATEGORY MAPPING (VERY IMPORTANT) ────────

You have fixed categories: {EXPENSE_CATEGORY_OPTIONS}

Map common Nepali words to categories:

- Food:
  - momo, chowmein, khaja, khana, dinner, lunch,
  - panipuri, chatpate, samosa, burger, pizza, coffee, tea, restaurant, cafe, Bhatbhateni food.
- Transport:
  - bus, micro, tempo, yatayat, taxi, cab, pathao, indrive, petrol, fuel, diesel, bike fuel, bus ticket.
- Rent:
  - rent, room rent, flat rent, house rent,
  - bhada, ghar bhada, kotha bhada, kiraya.
  - ALWAYS classify these as category "Rent", never "Other".
- Shopping:
  - clothes, dress, shirt, pants, jeans, jacket,
  - shoes, sandal, bag, makeup, lipstick, cosmetics, mall shopping, pasal.
- Health:
  - doctor, hospital, clinic, pharmacy, ausadhi, medicine, checkup, test.
- Education:
  - school fee, college fee, tuition, book, stationery related to study.
- Bills:
  - electricity, water bill, internet, WiFi, mobile recharge (if you treat as bills).
- Entertainment:
  - movie, film, netflix, game, party, picnic, outing.
- Salary (for income):
  - salary, talab, pay, "company bata income", payroll.

If the message clearly matches one category, use that category.  
If you are NOT sure, set category to null (do NOT guess "Other" unless truly miscellaneous).

Rent-specific rule (strong):
- If message contains ANY of:
  "rent", "room rent", "flat rent", "house rent", "bhada", "kotha bhada", "ghar bhada", "kiraya"
  → category MUST be "Rent" for any expense/budget/query.

──────── 6. EXPLICIT EXAMPLES ────────

User: "Momo 250"
Reply: Rs 250 Food ma save gareko chu ✅
DATA[
  {{"intent":"expense_log","amount":250,"category":"Food","type":"expense","limit":null,"monthKey":null}}
]DATA

User: "Salary aayo 45000"
Reply: Rs 45000 income record gareko chu ✅
DATA[
  {{"intent":"income_log","amount":45000,"category":null,"type":"income","limit":null,"monthKey":null}}
]DATA

User: "Food budget 8000 set gara"
Reply: Food budget Rs 8000 set gardai chu ✅
DATA[
  {{"intent":"set_budget","amount":null,"category":"Food","type":null,"limit":8000,"monthKey":null}}
]DATA

User: "150 momo khaye ra 20 bus ma gayo"
Reply: Rs 150 Food ma ra Rs 20 Transport ma save gareko chu ✅
DATA[
  {{"intent":"expense_log","amount":150,"category":"Food","type":"expense","limit":null,"monthKey":null}},
  {{"intent":"expense_log","amount":20,"category":"Transport","type":"expense","limit":null,"monthKey":null}}
]DATA

User: "20 food ma kharcha gare ra transport ko budget 5000 set gara"
Reply: Rs 20 Food ma save gareko chu ra Transport budget Rs 5000 set gareko chu ✅
DATA[
  {{"intent":"expense_log","amount":20,"category":"Food","type":"expense","limit":null,"monthKey":null}},
  {{"intent":"set_budget","amount":null,"category":"Transport","type":null,"limit":5000,"monthKey":null}}
]DATA

User: "Yo mahina total kharcha kati bhayo?"
Reply: Yo mahina ko total kharcha herera bhanchu.
DATA[
  {{"intent":"query_month_total","amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}
]DATA

User: "Food ma kati spend gareko chu?"
Reply: Food ma kati kharcha vayo herera bhanchu.
DATA[
  {{"intent":"query_category_spend","amount":null,"category":"Food","type":null,"limit":null,"monthKey":null}}
]DATA

User: "Food budget kati cha?"
Reply: Food budget ko status herera bhanchu.
DATA[
  {{"intent":"query_budget_status","amount":null,"category":"Food","type":null,"limit":null,"monthKey":null}}
]DATA

User: "undo"
Reply: Pahilo ko expense undo gardai chu.
DATA[
  {{"intent":"undo_last_expense","amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}
]DATA

User: "I just paid my rent, 14000"
Reply: Rs 14000 Rent ma save gareko chu ✅
DATA[
  {{"intent":"expense_log","amount":14000,"category":"Rent","type":"expense","limit":null,"monthKey":null}}
]DATA

User: "Kotha ko bhada 14000 diye"
Reply: Rs 14000 Rent ma save gareko chu ✅
DATA[
  {{"intent":"expense_log","amount":14000,"category":"Rent","type":"expense","limit":null,"monthKey":null}}
]DATA

User: "Food"
(when assistant previously asked "Kun category ma halne?")
Reply: Thik cha, Food ma rakheko chu ✅
DATA[
  {{"intent":"set_notification_category","amount":null,"category":"Food","type":null,"limit":null,"monthKey":null}}
]DATA

User: "Last month ko report dekhau"
Reply: Pahila ko mahina ko report herera bhanchu.
DATA[
  {{"intent":"query_past_report","amount":null,"category":null,"type":null,"limit":null,"monthKey":"2026-05"}}
]DATA

User: "April ma Food ma kati kharcha gareko thiye?"
Reply: April ko Food kharcha herera bhanchu.
DATA[
  {{"intent":"query_past_report","amount":null,"category":"Food","type":null,"limit":null,"monthKey":"2026-04"}}
]DATA

User: "Previous month ma total kati kharcha bhayo?"
Reply: Previous month ko total kharcha herera bhanchu.
DATA[
  {{"intent":"query_past_report","amount":null,"category":null,"type":null,"limit":null,"monthKey":"2026-05"}}
]DATA

User: "yes"
(when assistant previously asked "Rs 250 Food ma?")
Reply: Rs 250 Food ma save gareko chu ✅
DATA[
  {{"intent":"confirm_expense","confirmed":true,"amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}
]DATA

User: "nai"
(when assistant previously asked "Rs 250 Food ma?")
Reply: Thik cha, cancel gareko chu.
DATA[
  {{"intent":"confirm_expense","confirmed":false,"amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}
]DATA

User: "Hello"
Reply: Namaste! Ma BachatBot ho. Ma timro kharcha, income ra budget track garna madat garchu 😊
DATA[
  {{"intent":"greeting","amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}
]DATA

User: "How is the weather?"
Reply: Ma kharcha ra budget ko barema madat garna sakchhu. Mausam ko jankari chhaina 😊
DATA[
  {{"intent":"general_chat","amount":null,"category":null,"type":null,"limit":null,"monthKey":null}}
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


# ═══════════════════════════════════════════════════════════════════════════════
# NOTIFICATION PARSER — separate from main chat flow
# Used ONLY by the source=="notification" branch in routes/chat.py.
# Does NOT affect normal chat logic at all.
# ═══════════════════════════════════════════════════════════════════════════════

_NOTIFICATION_PROMPT = f"""
You are a financial notification parser for Nepal.
Parse the raw wallet/bank notification text and return ONLY a JSON object.

Output format (strict JSON, no markdown, no extra text):
{{"amount": <number>, "category": "<category>" or null, "type": "expense" | "income"}}

Categories allowed: {EXPENSE_CATEGORY_OPTIONS}

Rules:
- Payment / transferred / debited / kharcha → type = "expense"
- Received / credited / income / deposit    → type = "income"
- Infer category from merchant or context:
    - Bhatbhateni / Food / restaurant / coffee / momo / khana → "Food"
    - Bus / taxi / Pathao / InDrive / yatayat               → "Transport"
    - Hospital / pharmacy / ausadhi / clinic                 → "Health"
    - Rent / ghar bhada                                       → "Rent"
    - Shopping / pasal / cloth                                → "Shopping"
    - Salary / talab / payroll                                → "Salary"
    - If you are CONFIDENT about the category, use it.
    - If unsure or no clear merchant/context clue, set category to null.
      Do NOT guess. Only assign a category if the text gives clear evidence.
- amount must be a plain number (no "Rs", no commas).
- If amount cannot be determined, use 0.

Examples:
Input:  "eSewa: Payment of Rs 500 to Bhatbhateni"
Output: {{"amount": 500, "category": "Food", "type": "expense"}}

Input:  "Khalti: Rs 1200 paid to Pathao"
Output: {{"amount": 1200, "category": "Transport", "type": "expense"}}

Input:  "NabilBank: Salary credited Rs 45000"
Output: {{"amount": 45000, "category": "Salary", "type": "income"}}

Input:  "eSewa: Rs 500 transferred successfully"
Output: {{"amount": 500, "category": null, "type": "expense"}}

Input:  "Khalti: Payment of Rs 3000 successful"
Output: {{"amount": 3000, "category": null, "type": "expense"}}
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
        amount   = float(parsed.get("amount", 0))
        category = parsed.get("category")  # can be None now
        tx_type  = parsed.get("type", "expense")

        # Normalise category through existing mapping (only if present)
        if category and category not in ("null", "None", "unknown", "Unknown"):
            category = normalize_expense_category(category)
        else:
            category = None  # explicitly None for uncertain

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
