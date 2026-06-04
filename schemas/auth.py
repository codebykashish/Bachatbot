from pydantic import BaseModel, EmailStr
from typing import Dict

class EmailCheckRequest(BaseModel):
    email: EmailStr

class EmailCheckResponse(BaseModel):
    email: str
    exists: bool

class PasswordValidationRequest(BaseModel):
    password: str

class PasswordValidationResponse(BaseModel):
    success: bool
    message: str = "Password is valid"

class WeakPasswordError(BaseModel):
    error: str = "WEAK_PASSWORD"
    missing: Dict[str, bool]
    message: str
