from pydantic import BaseModel, Field
from typing import Optional
from enum import Enum


class TransactionTypeEnum(str, Enum):
    EXPENSE = "expense"
    INCOME = "income"
    TRANSFER = "transfer"
    SAVING = "saving"


class TransactionStatusEnum(str, Enum):
    CONFIRMED = "confirmed"
    PENDING = "pending"
    REJECTED = "rejected"
    CANCELLED = "cancelled"


class TransactionSourceEnum(str, Enum):
    CHAT = "chat"
    MANUAL = "manual"
    NOTIFICATION = "notification"
    OFFLINE_SYNC = "offline_sync"


class TransactionCreate(BaseModel):
    amount: float = Field(..., gt=0)
    category: Optional[str] = None
    savingMethod: Optional[str] = None
    type: TransactionTypeEnum
    description: str = ""
    monthKey: str
    source: TransactionSourceEnum = TransactionSourceEnum.MANUAL


class TransactionResponse(BaseModel):
    id: str
    amount: float
    category: Optional[str] = None
    savingMethod: Optional[str] = None
    type: TransactionTypeEnum
    status: TransactionStatusEnum
    source: TransactionSourceEnum
    description: str
    monthKey: str
    isDeleted: bool = False
    deletedAt: Optional[str] = None
    originalMessageId: Optional[str] = None
    createdAt: str
    updatedAt: str


class TransactionsResponse(BaseModel):
    transactions: list[TransactionResponse]
    count: int
