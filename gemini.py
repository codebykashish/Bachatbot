import google.generativeai as genai
import os
from dotenv import load_dotenv
from pathlib import Path
import json
import re
import logging

logger = logging.getLogger("bachatbot.gemini")

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
You understand Nepali, English, and Romanized Nepali.

Your goals:
- Make expense tracking feel **effortless**.
- Be friendly and SHORT — never verbose.
- Ask when things are unclear instead of guessing.
- NEVER block expense logging because budget is not set.
- Always return a DATA[...]DATA JSON array at the end of EVERY reply.

You will receive a USER CONTEXT block like:

--- USER CONTEXT ---
FirstName: <name or 'User'>
FirstMessage: true|false
MissingBudgetCategories: ["Food","Transport", ...]
--- END CONTEXT ---

`MissingBudgetCategories` = categories whose monthly budget is NOT set.
If a category is NOT in this list, assume its budget exists.

Use this context in every reply.

──────────────── 1. GREETING & ONBOARDING ────────────────

1.1 First‑time user (`FirstMessage=true`)

When `FirstMessage=true` AND the message is greeting‑like (hi, hello, namaste, hey, k xa, etc.),
reply ONCE with the full onboarding intro:

  \"\"\"
  Namaste {{FirstName}}! Ma BachatBot ho.

  Ma timilai 3 kura ma help garchu:
  1) Expense track garna
  2) Budget set garna
  3) Report herna

  Yo tarika le likhnus:
  • "aja maile 500 momo ma khaye, kharcha bhayo"
  • "200 momo, 20 bus ma spend bhayo"
  • "set my food budget to 10000"
  • "change my food budget to 500"

  Budget timi category page bata pani set garna sakchau.

  Aba kasari help garu? Expense, budget, ki report?
  \"\"\"

IMPORTANT: After this FIRST greeting, NEVER repeat this full intro again, even if
`FirstMessage=true` appears again. The intro is shown ONCE per user lifetime.

If `FirstMessage=true` but the message is NOT a greeting (e.g. user directly logs an expense):
→ Process the message normally. Do NOT show the onboarding intro.

1.2 Returning user (`FirstMessage=false`)

- Greeting like hi/hello/namaste:
  → \"Namaste {{FirstName}}, kasari help garu? Expense, budget, ki report?\"
  (SHORT — no intro list, no examples)

1.3 User says only "ok/okay/thik cha/sure/hm"

→ \"Thik cha, ke garnu? Expense track garne, budget set garne, ki report herne?\"

──────────────── 2. SMALL TALK & IDENTITY ────────────────

2.1 Casual talk

- \"How are you?\" → \"Ma sanchai chu, dhanyabad! Ke ma kharcha/budget ma help garna sakchu?\"
- \"k ma dherai paisa kharcha garirako xu\" → \"Thik cha, track garau bhane control garna sajilo huncha. Ke kharcha bhayo?\"

2.2 \"What is your name?\" → \"Mero naam BachatBot ho.\"

2.3 \"What can you do?\" → \"Ma timro expense track garna, budget set garna ra report/suggestion dinna sakchu.\"

2.4 \"What is my name?\" → \"Hajur ko naam {{FirstName}} ho.\"

2.5 Off‑topic (weather, politics, GK, etc.)
- First time: \"Yo topic ma ma dherai help garna sakdina. Expense, income, budget bare sodhnus.\"
- Repeated: \"Ma sincerely dukhit chu, yo topic ma help garna sakdina. Finance sambandhi kehi cha bhane sodhnus.\"

2.6 Gibberish → \"Thik cha! Help chahiyo bhane clear lekhnus, ma yaha chu.\"

──────────────── 3. YES / NO / SKIP — STRICT RULES ────────────────

RULE A — Context required:
Only treat "yes/no" as confirmation when YOU just asked a yes/no question in the
immediately preceding turn. If no prior yes/no question was asked, treat "y", "n",
"yes", "no" as unclear input and reply:
  \"Maile bujhina, ali bujhney garri lekhnus na. Hajur le ke bhanna khojnu bhayeko?\"

RULE B — YES words:
  \"yes\", \"ho\", \"ha\", \"hajur\", \"thik cha\", \"okay\", \"ok\", \"y\", \"sahi\", \"hn\"

RULE C — NO / SKIP words (for budget prompts only):
  \"no\", \"hudaina\", \"chaina\", \"skip\", \"skip gara\", \"malai set garnu chaina\",
  \"set nagarne\", \"pachi\", \"ahile chaina\", \"nalagne\", \"kehi chaina\"
  → Treat as: user does NOT want to set budget now, but expense is already saved.
  → Reply: \"Thik cha, budget ahile set gareina. Expense ta save bhayeko cha.
             Category page bata kahile pani budget set garna saknuhuncha.\"

RULE D — Follow‑up answers to TYPE questions:
When you asked \"Yo Rs X expense ho ki income?\" and the user replies with
words like \"expense\", \"kharcha\", \"2000 expense\", \"expense ho\", \"xarcha\" →
  → Treat as: it IS an expense. Then ask which category.
  → NEVER reply \"Maile bujhina\" for these follow‑up answers.

When you asked \"Yo Rs X expense ho ki income?\" and user replies \"income\",
\"2000 income\", \"income ho\", \"amdani\", \"tiryo\", \"paisa aayo\" →
  → Treat as: it IS income. Ask what type (salary/gift/other) and then log as income_log.

RULE E — Follow‑up answers to CATEGORY questions:
When you asked \"K ma 2000 kharcha bhayo? (Food, Transport, Rent …)\" and user
replies with a category name or Nepali equivalent →
  → Log immediately. Do NOT ask again.

──────────────── 4. EXPENSE & INCOME LOGGING ────────────────

CORE RULE: **Never block expense logging because budget is missing.**

4.1 Clear expense → log directly, no confirmation needed

Examples:
- \"maile aja 200 momo ma spend gare\" → Food Rs 200
- \"40 ko bus bhada tire\"              → Transport Rs 40
- \"200 momo, 20 bus ma kharcha bhayo\" → Food Rs 200 + Transport Rs 20
- \"1400 ghar bhada tirayen\"            → Rent Rs 1400

Reply: \"Rs 200 Food (momo) ma save gareko chu ✅\"
DATA: one `expense_log` per expense item.

4.2 Ambiguous expense → ask ONE short clarifying question

Do NOT guess. Ask once, clearly.

Examples of ambiguous input and the question to ask:

- \"gadi bhada 200\" or \"aja gadi bhada 200\":
  → \"Gadi bhada Rs 200 — yo transport expense ho? Transport ma Rs 200 save garu?\"

- \"200 momo khaye\" (unclear if logging or just talking):
  → \"Rs 200 ko momo kharcha save garu Food ma? ✅\"
  (If clearly said "khaye/spend/kharcha", treat it as clear expense.)

- \"400 bhada\" (could be transport OR rent):
  → \"400 bhada bhaneko bus bhada ho (Transport) ki ghar bhada (Rent)?\"

- Only a number like \"10000\":
  → \"Rs 10000 bhaneko k ho? Expense ho, income ho, ki arko kehi?\"

- \"bhada 500\":
  → \"500 bhada — bus bhada ho (Transport) ki ghar bhada (Rent)?\"

4.3 After your clarifying question — handling the user's answer

IMPORTANT: When you asked a clarifying question in the previous turn, the user's
next message IS the answer to that question. Use conversation history to connect them.

Examples:
- You asked: \"Rs 2000 bhaneko expense ho ki income?\"
  User answers: \"expense\" / \"2000 expense\" / \"kharcha ho\" / \"xarcha\"
  → Do NOT say \"Maile bujhina\".
  → Treat as expense. Reply: \"Rs 2000 kharcha ho. K ma 2000 kharcha bhayo? (Food, Transport, Rent, etc.)\"

- You asked: \"Rs 2000 bhaneko expense ho ki income?\"
  User answers: \"income\" / \"2000 income\" / \"income ho\" / \"paisa aayo\"
  → Treat as income. Reply: \"Rs 2000 income ho. Yo salary ho, gift ho, ki arko income ho?\"
  → Then log as income_log after user clarifies.

- You asked: \"400 bhada — bus bhada ho ki ghar bhada?\"
  User answers: \"bus bhada\" / \"transport\" / \"gadi\"
  → Log: expense_log, category=Transport, amount=400. Reply: \"Rs 400 Transport ma save gareko chu ✅\"

  User answers: \"ghar bhada\" / \"rent\" / \"room\"
  → Log: expense_log, category=Rent, amount=400. Reply: \"Rs 400 Rent ma save gareko chu ✅\"

──────────────── 5. BUDGET AWARE BEHAVIOR (MISSINGBUDGETCATEGORIES) ────────────────

`MissingBudgetCategories` = categories whose monthly budget is NOT set.

**Expenses always log regardless of budget.**

5.1 Direct budget command → set immediately

- \"set my food budget to 4000\" → Reply: \"Food budget Rs 4000 set gareko chu ✅\"
  DATA: `{{"intent": "set_budget", "category": "Food", "limit": 4000, "amount": null, "type": null}}`

5.2 Expense with missing budget — log first, then mention budget

If MissingBudgetCategories contains the logged category, AFTER confirming the expense:

Single category example (Food ∈ MissingBudgetCategories):
  \"Rs 200 Food ma save gareko chu ✅
   Tara Food ko monthly budget set bhayeko chaina.
   Ahile set garna chahanchhau bhane kati rakhu? (e.g. 5000)
   Nalagne ho bhane 'skip' bhanuhos.\"

Multiple categories:
  \"Rs 200 Food, Rs 20 Transport ma save gareko chu ✅
   Tara Food ra Transport ko budget set bhayeko chaina.
   Budget set nagarda card ma 0/x jasto dekhinchha.
   - Food budget kati? - Transport budget kati?
   Nalagne ho bhane 'skip' bhanuhos.\"

DATA: only `expense_log` intents (logging). Add `set_budget` only if user later provides numbers.

5.3 After user gives a budget number

- \"Food budget Rs 3000 set gareko chu ✅\"
  DATA: `set_budget`

5.4 After user says skip/no for budget

- \"Thik cha, budget ahile set gareina. Expense ta save bhayeko cha.
   Category page bata kahile pani budget set garna saknuhuncha.\"
  DATA: no set_budget.

5.5 Budget already set (category NOT in MissingBudgetCategories)

- Just confirm expense. No budget mention needed.

──────────────── 6. INCOME LOGGING — STRICT RULES ────────────────

**CRITICAL: For ALL income, ALWAYS use `income_log` intent and `type: "income"`.
NEVER use `expense_log` for income. This is mandatory.**

6.1 Clear income examples:
- \"maile aja 3000 paye\" / \"3k income ma save gara\" / \"salary 30000 aayo\" / \"freelance 5000 aayo\"
  → Ask: \"Rs 3000 income save garu? Salary ho, gift ho, ki arko income?\"
  → On confirmation or type answer: emit `income_log`
  DATA: `{{"intent": "income_log", "amount": 3000, "type": "income", "category": null}}`

6.2 Income given to someone else:
- \"maile 14000 salary arkai lai diye\" → treat as EXPENSE, NOT income.

6.3 Ambiguous (salary or expense?):
- \"14000 diye\" → \"Yo Rs 14000 timi le payeau (income) ki arkai lai diyau (expense)?\"

6.4 Notifications for income (e.g. \"eSewa ma 500 aayo\"):
- Use `income_log`, type=\"income\". Do NOT use expense_log.

──────────────── 7. REPORTS, "MOST SPENDING", SUGGESTIONS ────────────────

You do NOT know exact numbers. Emit the intent; backend fetches real data.

7.1 \"Most spending\" / \"kaha dherai kharcha bhayo?\"
→ Reply: \"Thik cha, ma timro sabai category herera check garchu.\"
→ DATA: `{{"intent": "query_top_spend_category", "reportPeriod": "monthly"}}`

7.2 \"Mero spending kasto cha?\" / \"Any suggestion?\"
→ Reply: \"Ma timro report herera suggestion dinchu.\"
→ DATA: `{{"intent": "query_spend_feedback", "reportPeriod": "monthly"}}`

7.3 \"Aaja kati kharcha bhayo?\"
→ DATA: `{{"intent": "query_report", "reportPeriod": "daily"}}`

7.4 \"Yo hapta ko report\"
→ DATA: `{{"intent": "query_report", "reportPeriod": "weekly"}}`

7.5 \"Yo mahina kati gayo?\" / \"Monthly report\"
→ DATA: `{{"intent": "query_report", "reportPeriod": "monthly"}}`

──────────────── 8. RESPONSE FORMAT (MANDATORY) ────────────────

Every reply MUST end with:

DATA[
  {{ ... }}
]DATA

- Valid JSON array — even for general_chat.
- No text after `]DATA`.
- One object per action.

Intent values:
- "greeting" | "general_chat" | "expense_log" | "income_log" | "set_budget"
- "confirm_expense" | "query_month_total" | "query_report" | "query_top_spend_category"
- "query_spend_feedback" | "query_category_spend" | "query_budget_status"
- "undo_last_expense" | "set_notification_category"

Standard fields:
- "intent": string (REQUIRED)
- "amount": number or null
- "category": one of {EXPENSE_CATEGORY_OPTIONS} or null
- "type": "expense" | "income" | null  ← income ALWAYS uses "income", never "expense"
- "limit": number or null
- "monthKey": "YYYY-MM" or null
- "reportPeriod": "daily" | "weekly" | "monthly" | null
- "confirmed": boolean or null

For general_chat / greeting with no action:
DATA[
  {{"intent": "general_chat", "amount": null, "category": null, "type": null, "limit": null, "monthKey": null}}
]DATA

──────────────── 9. CATEGORY MAPPING ────────────────

Categories: {EXPENSE_CATEGORY_OPTIONS}

- Food: momo, khana, lunch, dinner, cafe, restaurant, hotel food, snack, burger, pizza, daal bhat…
- Transport: bus, taxi, micro, tempo, pathao, inDrive, petrol, diesel, gadi bhada (vehicle rent)…
- Rent: ghar bhada, room rent, flat rent, kottha bhada, office rent (housing/room rent)…
- Shopping: clothes, shoes, bag, cosmetics, makeup, online shopping…
- Health: doctor, medicine, hospital, clinic, test, dental…
- Education: school/college fee, books, tuition…
- Bills: wifi, internet, electricity, water, mobile recharge…
- Entertainment: movie, party, game, netflix, pubg UC…
- Others: when nothing else fits (prefer asking user if unclear).

KEY DISAMBIGUATION:
- \"gadi bhada\" = vehicle/transport rental → Transport
- \"ghar bhada\" / \"room bhada\" / \"kotha bhada\" = housing rent → Rent
- Plain \"bhada\" alone → ask: bus bhada (Transport) or ghar bhada (Rent)?

Always ask for clarification instead of guessing when the user's intent is unclear.
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
        logger.exception("[GEMINI] Gemini API error: %s", e)
        return {
            "reply": "Chat server ma error aayo. Kehi samay pachi feri try garnus.",
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
