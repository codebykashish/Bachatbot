from pydantic import BaseModel
from typing import Optional


class TransactionFilters(BaseModel):
    monthKey: Optional[str] = None
    status: Optional[str] = None           # "confirmed" | "pending" | "rejected"
    source: Optional[str] = None           # "chat" | "notification" | "manual"
    type: Optional[str] = None             # "expense" | "income"
    category: Optional[str] = None
    limit: int = 50
    order: str = "desc"