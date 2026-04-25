from pydantic import BaseModel
from typing import Optional


class ChatRequest(BaseModel):
    message: str
    source: str = "chat"                    # "chat" | "notification"
    sourceApp: Optional[str] = None         # "eSewa" | "Khalti" etc
    originalMessageId: Optional[str] = None