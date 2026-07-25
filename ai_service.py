import logging
from ai_gemini import call_gemini_chat, call_gemini_notification
from ai_ollama import call_ollama_chat, call_ollama_notification
from ai_prompts import parse_ai_response, get_reply_text
from google.api_core.exceptions import ResourceExhausted, ServiceUnavailable, InternalServerError, DeadlineExceeded
import google.api_core.exceptions

logger = logging.getLogger("bachatbot.ai_service")

async def process_chat_message(
    user_message: str,
    first_name: str = "User",
    is_first_message: bool = False,
    missing_budget_categories: list[str] | None = None,
    history: list[dict] | None = None,
    overall_health_status: str | None = None,
    top_risk_category: str | None = None,
    at_risk_goal: dict | None = None,
    financial_context: dict | None = None,
) -> dict:
    """
    Orchestrates the chat message processing.
    Tries Gemini first, falls back to Ollama on recoverable errors.
    """
    
    response_text = None
    provider_used = "None"
    
    # 1. Try Gemini
    try:
        logger.info("[AI] Primary provider: Gemini")
        logger.info("[AI] Gemini request started")
        
        response_text = call_gemini_chat(
            user_message=user_message,
            first_name=first_name,
            is_first_message=is_first_message,
            missing_budget_categories=missing_budget_categories,
            history=history,
            overall_health_status=overall_health_status,
            top_risk_category=top_risk_category,
            at_risk_goal=at_risk_goal,
            financial_context=financial_context,
        )
        logger.info("[AI] Gemini request succeeded")
        provider_used = "Gemini"
        
    except (ResourceExhausted, ServiceUnavailable, InternalServerError, DeadlineExceeded) as e:
        logger.warning(f"[AI] Gemini failed: {e.__class__.__name__}")
        logger.info("[AI] Switching to Ollama fallback")
        
        # 2. Try Ollama Fallback
        try:
            logger.info("[AI] Ollama request started")
            response_text = call_ollama_chat(
                user_message=user_message,
                first_name=first_name,
                is_first_message=is_first_message,
                missing_budget_categories=missing_budget_categories,
                history=history,
                overall_health_status=overall_health_status,
                top_risk_category=top_risk_category,
                at_risk_goal=at_risk_goal,
                financial_context=financial_context,
            )
            logger.info("[AI] Ollama request succeeded")
            provider_used = "Ollama"
            
        except Exception as ollama_err:
            logger.error(f"[AI] Ollama fallback failed: {ollama_err}")
            logger.error("[AI] Both AI providers unavailable")
            return _graceful_error()
            
    except google.api_core.exceptions.GoogleAPICallError as e:
        # Other unknown API errors, possibly also fallback
        logger.warning(f"[AI] Gemini failed: {e.__class__.__name__}")
        logger.info("[AI] Switching to Ollama fallback")
        try:
            response_text = call_ollama_chat(
                user_message=user_message,
                first_name=first_name,
                is_first_message=is_first_message,
                missing_budget_categories=missing_budget_categories,
                history=history,
                overall_health_status=overall_health_status,
                top_risk_category=top_risk_category,
                at_risk_goal=at_risk_goal,
                financial_context=financial_context,
            )
            provider_used = "Ollama"
        except Exception:
            return _graceful_error()
            
    except Exception as e:
        # Unexpected errors (like no API key config etc.) - still fallback just in case
        logger.error(f"[AI] Unexpected Gemini Error: {e}")
        try:
            response_text = call_ollama_chat(
                user_message=user_message,
                first_name=first_name,
                is_first_message=is_first_message,
                missing_budget_categories=missing_budget_categories,
                history=history,
                overall_health_status=overall_health_status,
                top_risk_category=top_risk_category,
                at_risk_goal=at_risk_goal,
                financial_context=financial_context,
            )
            provider_used = "Ollama"
        except Exception:
            return _graceful_error()

    # 3. Validation / Parsing
    if not response_text:
        return _graceful_error()
        
    try:
        actions = parse_ai_response(response_text)
        reply_text = get_reply_text(response_text)
        print(f"[{provider_used}] Parsed {len(actions)} action(s): {[a.get('intent') for a in actions]}")
        
        return {
            "reply": reply_text,
            "actions": actions,
        }
    except Exception as e:
        logger.error(f"[AI] Validation/Parsing error from {provider_used} response: {e}")
        # If parsing fails, we could potentially try the fallback here, 
        # but for simplicity and safety, return error if schema is broken.
        return _graceful_error()


async def parse_notification_text(notification_text: str) -> dict:
    """
    Orchestrates notification parsing with fallback.
    """
    default = {"amount": 0.0, "category": "Other", "type": "expense"}
    response_text = None
    provider_used = "None"
    
    try:
        response_text = call_gemini_notification(notification_text)
        provider_used = "Gemini"
    except (ResourceExhausted, ServiceUnavailable, InternalServerError, DeadlineExceeded) as e:
        logger.warning(f"[AI_NOTIF] Gemini failed: {e.__class__.__name__}")
        try:
            response_text = call_ollama_notification(notification_text)
            provider_used = "Ollama"
        except Exception as oe:
            logger.error(f"[AI_NOTIF] Both providers failed: {oe}")
            return default
    except Exception as e:
        logger.error(f"[AI_NOTIF] Unexpected Gemini Error: {e}")
        try:
            response_text = call_ollama_notification(notification_text)
            provider_used = "Ollama"
        except Exception:
            return default

    if not response_text:
        return default
        
    import re, json
    from schemas.categories import normalize_expense_category
    from utils import extract_amount
    
    raw = response_text.strip()
    raw = re.sub(r"^```[a-z]*\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)
    
    try:
        parsed = json.loads(raw)
        extracted = extract_amount(notification_text)
        amount = extracted if extracted > 0 else float(parsed.get("amount", 0))
        category = parsed.get("category")
        tx_type  = parsed.get("type", "expense")

        if category and category not in ("null", "None", "unknown", "Unknown"):
            category = normalize_expense_category(category)
        else:
            category = None
            
        print(f"[{provider_used}_NOTIF] '{notification_text}' → amount={amount} category={category} type={tx_type}")
        return {"amount": amount, "category": category, "type": tx_type}
    except Exception as e:
        print(f"[{provider_used}_NOTIF] Parse error: {e} | raw='{raw}'")
        return default

def _graceful_error():
    return {
        "reply": "Chat server ma error aayo. Kehi samay pachi feri try garnus.",
        "actions": [{"intent": "general_chat", "amount": None, "category": None,
                     "type": None, "limit": None, "monthKey": None}],
    }
