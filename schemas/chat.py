from pydantic import BaseModel, Field
from typing import Optional
from enum import Enum

class MessageRoleEnum(str, Enum):
    USER = "user"
    ASSISTANT = "assistant"
   
class IntentEnum(str, Enum):
    GENERAL_CHAT = "general_chat"
    EXPENSE_LOG = "expense_log"
    BUDGET_SET = "budget_set"
    UNDO_REQUEST = "undo_request"
    GREETING = "greeting"
    QUERY_REPORT = "query_report"
    CONFIRMATION_RESPONSE = "confirmation_response"

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