from pydantic import BaseModel, Field
from typing import Optional, Any
from enum import Enum

class LanguageEnum(str, Enum):
    NEPALI = 'ne'
    ENGLISH = 'en'

class CurrencyEnum(str, Enum):
    NPR = "NPR"

class TimestampMixin(BaseModel):
    createdAt: str
    updatedAt: str
