import google.generativeai as genai
import os
from dotenv import load_dotenv

load_dotenv()

genai.configure(api_key=os.getenv("GEMINI_API_KEY"))

model = genai.GenerativeModel("gemini-2.5-flash")

SYSTEM_PROMPT = """
You are BachatBot, a smart expense tracking assistant for Nepal.
You understand Nepali and English mixed language (Nepali romanized).

Your job is to understand what the user says and extract financial information.

Always respond in this format:

[Your friendly reply to user]

DATA{
  "intent": "expense_log" | "income_log" | "general_chat" | "greeting" | "budget_set" | "query_report",
  "amount": 250 | null,
  "category": "Food" | "Transport" | "Rent" | "Education" | "Shopping" | "Health" | "Entertainment" | "Bills" | "Salary" | "Freelance" | "Gift" | "Other" | null,
  "type": "expense" | "income" | null,
  "description": "original user message"
}DATA

Rules:
- If user says expense related thing → intent = expense_log
- If user says income related thing → intent = income_log
- If user is just chatting → intent = general_chat
- If user says hello/hi/namaste → intent = greeting
- Always respond friendly in Nepali or English based on user language
- For Nepal context: momo=Food, bus/tempo=Transport, salary/तलब=income
- Category must be exactly one of the listed categories
- Amount must be a number only, no Rs or rupees text

Examples:
User: "Momo 250"
Reply: Rs 250 Food ma save gareko chu ✅
DATA{"intent": "expense_log", "amount": 250, "category": "Food", "type": "expense", "description": "Momo 250"}DATA

User: "Salary aayo 45000"
Reply: Rs 45000 Salary income ma record gareko chu ✅
DATA{"intent": "income_log", "amount": 45000, "category": "Salary", "type": "income", "description": "Salary aayo 45000"}DATA

User: "Hello"
Reply: Namaste! Ma BachatBot chu. Timro kharcha track garna ready chu 😊
DATA{"intent": "greeting", "amount": null, "category": null, "type": null, "description": "Hello"}DATA
"""


def parse_gemini_response(response_text: str) -> dict:
    """
    Extract the DATA{...}DATA block from Gemini response.
    Returns dict with intent, amount, category, type, description.
    """
    import json
    import re

    # Find DATA{...}DATA block
    pattern = r'DATA\{(.*?)\}DATA'
    match = re.search(pattern, response_text, re.DOTALL)

    if not match:
        # No structured data found, treat as general chat
        return {
            "intent": "general_chat",
            "amount": None,
            "category": None,
            "type": None,
            "description": ""
        }

    try:
        json_str = "{" + match.group(1) + "}"
        data = json.loads(json_str)
        return data
    except json.JSONDecodeError:
        return {
            "intent": "general_chat",
            "amount": None,
            "category": None,
            "type": None,
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
            print("❌ ERROR: GEMINI_API_KEY is missing from .env file!")
            return {"reply": "API Key missing", "intent": "error"}

        full_prompt = f"{SYSTEM_PROMPT}\n\nUser: {user_message}"
        response = model.generate_content(full_prompt)
        response_text = response.text

        parsed_data = parse_gemini_response(response_text)
        reply_text = get_reply_text(response_text)

        return {
            "reply": reply_text,
            "intent": parsed_data.get("intent", "general_chat"),
            "amount": parsed_data.get("amount"),
            "category": parsed_data.get("category"),
            "type": parsed_data.get("type"),
            "description": parsed_data.get("description", user_message)
        }

    except Exception as e:
        # THIS LINE IS IMPORTANT: It prints the real error to your terminal
        print(f"❌ GEMINI SYSTEM ERROR: {str(e)}") 
        
        return {
            "reply": f"Internal Error: {str(e)}",
            "intent": "general_chat",
            "amount": None,
            "category": None,
            "type": None,
            "description": user_message
        }