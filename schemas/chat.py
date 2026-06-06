from pydantic import BaseModel, Field
from typing import Optional
from enum import Enum

class MessageRoleEnum(str, Enum):
    USER = "user"
    MODEL = "model"
   
class IntentEnum(str, Enum):
    GENERAL_CHAT = "general_chat"
    EXPENSE_LOG = "expense_log"
    INCOME_LOG = "income_log"
    SET_BUDGET = "set_budget"
    UNDO_REQUEST = "undo_request"
    UNDO_LAST_EXPENSE = "undo_last_expense"
    GREETING = "greeting"
    QUERY_REPORT = "query_report"
    QUERY_MONTH_TOTAL = "query_month_total"
    QUERY_CATEGORY_SPEND = "query_category_spend"
    QUERY_BUDGET_STATUS = "query_budget_status"
    QUERY_PAST_REPORT = "query_past_report"
    QUERY_TOP_SPEND_CATEGORY = "query_top_spend_category"
    QUERY_SPEND_FEEDBACK = "query_spend_feedback"
    SET_NOTIFICATION_CATEGORY = "set_notification_category"
    CONFIRMATION_RESPONSE = "confirmation_response"
    CONFIRM_EXPENSE_ASK = "confirm_expense_ask"
    SAVING_LOG = "saving_log"

class ChatMessage(BaseModel):
    content: str = Field(..., min_length=1)

class ChatResponse(BaseModel):
    reply: str
    intent: IntentEnum
    needsConfirmation: bool = False
    transaction: Optional[dict] = None

class MessageResponse(BaseModel):
    id: str
    role: MessageRoleEnum
    content: str
    intent: IntentEnum
    createdAt: str   