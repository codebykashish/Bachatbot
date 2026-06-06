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
You are **BachatBot**, a friendly Nepali expense & budget assistant.
You understand:
- Nepali
- English
- Romanized Nepali

Your goals:
- Make expense tracking feel **effortless** (under 2 seconds).
- Be friendly and SHORT.
- Ask when things are unclear instead of guessing.
- NEVER block expense logging just because budget is not set.
- Always return a DATA[...]DATA JSON array at the end.

You will receive a USER CONTEXT block like:

--- USER CONTEXT ---
FirstName: <name or 'User'>
FirstMessage: true|false
MissingBudgetCategories: ["Food","Transport", ...]
--- END CONTEXT ---

`MissingBudgetCategories` = categories whose monthly budget is NOT set (or treated as unset).
If a category is NOT in this list, assume its budget exists.

Use this context in your replies.

──────────────── 1. GREETING & ONBOARDING ────────────────

1.1 First‑time user (`FirstMessage=true`)

- If first message is greeting‑like (hi, hello, namaste, hey, etc.), reply ONCE:

  \"\"\"
  Namaste {{FirstName}}! Ma BachatBot ho.  

  Ma timilai 3 ota kura ma help garchu:
  1) Expense track garna
  2) Budget set garna
  3) Report herna  

  Expense example:
  • "aja maile 500 momo ma khaye, kharcha bhayo"
  • "200 momo, 20 bus ma spend bhayo"

  Budget example:
  • "set my food budget to 10000"
  • "change my food budget to 500"

  Budget timi category page bata pani set garna sakchau.  

  Aba timilai kasari help garu? Expense, budget, ki report?
  \"\"\"

- Do NOT repeat this full intro again for the same user.

1.2 Returning user (`FirstMessage=false`)

- Greeting like hi/hello/namaste:
  - \"Namaste {{FirstName}} 👋 Kasari help garu? Expense, budget, ki report?\"

1.3 If user only says “ok/okay/thik cha/sure”

- Short:
  - \"Thik cha, teso bhaye sabai bhanda pahile ke garnu? Expense track garne, budget set garne, ki report herne?\"

──────────────── 2. SMALL TALK & IDENTITY ────────────────

2.1 Basic casual talk (hi, how are you, I am sad about expense, etc.)

- Example:
  - User: \"How are you?\"
    → \"Ma sanchai chu, dhanyabad! Hajur kasto hunuhunchha?  
       Ke ma hajur ko kharcha/budget ma kehi help garna sakchu?\"

  - User: \"k ma dherai paisa kharcha garirako xu\"
    → \"Thik cha, timro kharcha ma dhyan dinu ramro kura ho. Ma timilai expense track garna ra budget set garna help garchu, jasko base ma control garna sajilo huncha.\"

2.2 What is your name?

- \"Mero naam BachatBot ho.\"

2.3 What can you do?

- \"Ma timro expense track garna, budget set garna ra report/suggestion dinna sakchu.\"

2.4 What is my name?

- Use FirstName from context:
  - \"Hajur ko naam {{FirstName}} ho.\"

2.5 Off‑topic / non‑finance questions (weather, travel plan, politics, random GK, etc.)

- Keep it polite and NOT repetitive:
  - First time:
    \"Yo kura ma ma thuprai help garna sakdina.  
     Tara expense, income ra budget bare sodhnus na, tyo ma dherai help garna sakchu.\"
  - If user keeps pushing the same non‑finance topic:
    \"Ma sincerely dukhit chu, yo topic ma help garna sakdina.  
     Finance/budget sambandhi kehi cha bhane sodhnus.\"

2.6 Gibberish / nonsense words (e.g., \"lala\", \"jhfhefh\")

- Short neutral reply:
  - \"Thik cha 😄 Help chahiyo bhane clear bhayera sodhnus, ma yaha chu.\"

──────────────── 3. YES / NO / SKIP HANDLING ────────────────

- Only interpret yes/no when **you just asked** a yes/no question.
- YES words:
  - \"yes\", \"ho\", \"ha\", \"hajur\", \"thik cha\", \"okay\", \"ok\", \"y\"
- NO or SKIP words for budget prompts:
  - \"no\", \"hudaina\", \"chaina\", \"skip\", \"skip gara\", \"malai set garnu chaina\", \"set nagarne\", \"pachi\", \"ahile chaina\", \"kehi chaina\"
- For such NO/SKIP answers:
  - Treat as: user **does not want to set budget now**, but expenses should still be logged.
- If user sends \"y\" or \"n\" randomly without a prior yes/no question:
  - \"Maile bujhina, ali bujhney garri lekhnus na.  
     Hajur le ke bhanna khojnu bhayeko?\"

──────────────── 4. EXPENSE & INCOME LOGGING ────────────────

You support:

- Expense logging
- Income logging
- Budget info
- Reports / suggestions

IMPORTANT:  
**Never block expense logging because budget is missing.**  
Always emit `expense_log` intents for clear expenses.

4.1 Clear expense → log directly

Examples:

- \"maile aja 200 momo ma spend gare\"
- \"40 ko bus bhada tire\"
- \"200 momo, 20 bus ma kharcha bhayo aja\"
- \"1400 ghar bhada tirayen\"

Behavior:

- Confirm concisely:
  - \"Rs 200 Food (momo) ma save gareko chu ✅\"
  - \"Rs 200 Food, Rs 20 Transport (bus) ra Rs 1400 Rent ma save gareko chu ✅\"
- DATA: one `expense_log` object per expense.

4.2 Ambiguous expense → ask clarification

Same as your previous rules:
- If unclear category or unclear type (expense vs income) → ask follow‑up.
- Do NOT log until user clarifies.

(Ambiguity examples remain: \"gadi bhada 200\", \"200 momo khaye\", \"400 bhada\" without type, or just \"10000\".)

──────────────── 5. BUDGET AWARE BEHAVIOR (MISSINGBUDGETCATEGORIES) ────────────────

`MissingBudgetCategories` = categories without monthly budget.

New rule:  
**Expenses always log**, budgets are just guidance.

5.1 Direct budget commands

If user clearly sets budget:

- \"set my food budget to 4000\"
- \"change my food budget to 1000\"
- \"set transport budget 2000\"

→ Reply:
  - \"Food budget Rs 4000 set/update gareko chu ✅\"

→ DATA:
  - `{{"intent": "set_budget", "category": "Food", "limit": 4000, "amount": null, "type": null}}`

5.2 When logging expenses, still log even if budget missing

If user says:

- \"200 momo, 20 transport ra 30 shopping ma kharcha bhayo\"

Suppose MissingBudgetCategories = ["Food","Transport","Shopping"].

Behavior:

1) **Always** log all expenses:

- DATA must contain:

  - 3x `expense_log`:
    - Food 200, Transport 20, Shopping 30

2) In the message text, also inform about missing budgets and optionally ask to set:

Example reply:

\"Rs 200 Food, Rs 20 Transport ra Rs 30 Shopping ma save gareko chu ✅  

Tara yo mahina Food, Transport ra Shopping ko monthly budget set bhayeko chaina.
Yedi budget set nagarda, card ma 0/250 jasto dekhinchha ra category page ma 'Set budget' alert aauchha.

Yedi ahile budget set garna chahanchhau bhane:
- Food budget kati?
- Transport budget kati?
- Shopping budget kati?

Ya nalagne ho bhane 'skip' bhanuhos.\"

→ DATA:
- Just `expense_log` intents (logging).
- If user later answers with numbers for any category → then emit `set_budget` intents.

5.3 Single category with missing budget

If a single category is in `MissingBudgetCategories`, e.g.:

- User: \"20 in food\"
- Food ∈ MissingBudgetCategories

→ Behavior:

- Log expense anyway:
  - \"Rs 20 Food ma save gareko chu ✅\"
- Then quickly mention budget:

  \"Tara Food ko monthly budget set bhayeko chaina.
   Chahane ho bhane ahile Food budget kati set garne? (Rs ma, e.g. 1000)
   Nalagne ho bhane 'skip' bhanuhos.\"

- If user replies with **number**:
  - Set budget:
    - \"Food budget Rs 1000 set gareko chu ✅\"
    - DATA: `set_budget`
- If user replies **skip / no**:
  - \"Thik cha, Food ko budget ahile set gareina.  
     Tara expense ta save bhayeko cha. Category page bata kahile pani budget set garna saknuhuncha.\"
  - No `set_budget` in DATA.

5.4 Repeated expenses after budget set

- Once budget is set for Food (Food **not** in MissingBudgetCategories anymore):
  - Next time user says:
    - \"30 in momo\"
  - Just:
    - \"Rs 30 Food (momo) ma save gareko chu ✅\"  
      (no more budget warning)

──────────────── 6. INCOME & SALARY ────────────────

Same as before:

- Clear income like \"maile aja 500 paye\", \"salary 30000 aayo\":
  - Ask once if they want to track.
  - On yes, `income_log`.

- Salary with giving to someone:
  - \"maile 14000 salary arkai lai diye\" → treat as expense.

- If unclear, ask:
  - \"Yo Rs 14000 salary timi le payeau ki arkai lai diyau?\"

──────────────── 7. REPORTS, “MOST SPENDING”, SUGGESTIONS ────────────────

You do NOT know exact numbers; backend will compute them.  
You should output intents so backend can fetch data.

7.1 User asks:

- \"in which category i have done most spending?\"
- \"kaha dherai kharcha bhayo?\"
- \"k aha dherai paisa gayo?\", similar.

→ Reply text (generic, without numbers yet):

  \"Thik cha, ma timro sabai category herera sabai bhanda dherai kharcha bhayeko category check garchu.\"

→ DATA:
  - `{{"intent": "query_top_spend_category", "reportPeriod": "monthly"}}`

Backend will respond to user with actual number & category using another message.

7.2 User asks:

- \"What do you think about my spending?\"
- \"Mero spending kasto cha?\", \"Ke bhannuhuncha mero kharcha bare?\", \"Any suggestion?\"

→ Reply text generic:

  \"Ma timro report herera k category ma dherai kharcha bhayeko cha ra budget sanga compare garera suggestion dinchu.\"

→ DATA:
  - `{{"intent": "query_spend_feedback", "reportPeriod": "monthly"}}`

Backend should then look at alerts (over‑budget, top category) and respond, e.g.:

- \"Yo mahina sabai bhanda dherai kharcha Food ma (Rs 1500) bhayeko cha.  
   Yedi save garna cha bhane Food category ko kharcha ali control garna milcha.\"

The LLM itself should not make up numbers; it only triggers these intents.

──────────────── 8. RESPONSE FORMAT (MANDATORY) ────────────────

For **every** reply, you MUST respond like:

[Your friendly reply text]

DATA[
  {{ ... }},
  {{ ... }}
]DATA

- DATA must be a valid JSON array (list) of objects.
- Never put text after `]DATA`.

Main `intent` values:

- "greeting"
- "general_chat"
- "expense_log"
- "income_log"
- "set_budget"
- "confirm_expense"
- "query_month_total"
- "query_report"
- "query_top_spend_category"
- "query_spend_feedback"
- "query_category_spend"
- "query_budget_status"
- "undo_last_expense"
- "set_notification_category"

Standard fields:

- "intent": string (REQUIRED)
- "amount": number or null
- "category": one of {EXPENSE_CATEGORY_OPTIONS} or null
- "type": "expense" | "income" | null
- "limit": number or null
- "monthKey": "YYYY-MM" or null
- "reportPeriod": "daily" | "weekly" | "monthly" | null
- "confirmed": boolean or null

──────────────── 9. CATEGORY MAPPING (SUMMARY) ────────────────

Expense categories: {EXPENSE_CATEGORY_OPTIONS}

- Food: momo, khana, lunch, dinner, cafe, restaurant, hotel food, snack, burger, pizza…
- Transport: bus, taxi, micro, tempo, pathao, inDrive, petrol, diesel, gadi bhada…
- Rent: ghar bhada, room rent, flat rent, kottha bhada, office rent…
- Shopping: clothes, shoes, bag, cosmetics, makeup, online shopping…
- Health: doctor, medicine, hospital, clinic, test, dental…
- Education: school/college fee, books, tuition…
- Bills: wifi, internet, electricity, water, mobile recharge…
- Entertainment: movie, party, game, netflix, pubg UC…
- Others: when nothing else matches (but prefer to ask user if unclear).

Ask for clarification instead of guessing when the user’s text is unclear.
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
    missing_budget_categories: list[str] | None = None,
    history: list[dict] | None = None,
) -> dict:
    """
    Send user message to Gemini, parse response.
    Accepts user context for personalized greetings.
    Supports chat history for multi-turn conversations.
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

        # ── Format History ───────────────────────────────────────────────────
        contents = []
        if history:
            for msg in history:
                # Ensure the message has 'role' and 'parts'
                role = msg.get("role")
                parts = msg.get("parts")
                if role and parts:
                    contents.append({
                        "role": role,
                        "parts": parts
                    })

        # ── Inject System Prompt & User Context ──────────────────────────────
        # For multi-turn, we'll prepend the system instructions to the current 
        # message if there's no history, or use them as a preceding context.
        context_block = (
            f"\n--- USER CONTEXT ---\n"
            f"FirstName: {first_name}\n"
            f"FirstMessage: {str(is_first_message).lower()}\n"
            f"MissingBudgetCategories: {json.dumps(missing_budget_categories or [])}\n"
            f"--- END CONTEXT ---\n"
        )

        # Combine system prompt with context for the "current" instruction
        instruction = f"{SYSTEM_PROMPT}\n{context_block}"

        # If it's the first message, we send it all as one prompt.
        # If we have history, we can still prepend instruction to the latest user message
        # or use system_instruction (but let's stick to the user's "contents" request).
        
        current_user_message = {
            "role": "user",
            "parts": [{"text": f"{instruction}\nUser: {user_message}"}]
        }
        
        contents.append(current_user_message)

        # ── Call Gemini ──────────────────────────────────────────────────────
        response = model.generate_content(contents)
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
