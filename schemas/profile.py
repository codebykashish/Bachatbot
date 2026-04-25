from pydantic import BaseModel, EmailStr
from typing import Optional


class OnboardingData(BaseModel):
    isCompleted: bool = False
    occupation: Optional[str] = None        # "student" | "employed" | "business"
    housingType: Optional[str] = None       # "rent" | "own"
    estimatedMonthlySpend: Optional[float] = None


class PreferencesData(BaseModel):
    language: str = "ne"                    # "ne" | "en"
    currency: str = "NPR"
    alertThreshold: int = 80               # percentage


class SignupRequest(BaseModel):
    firstName: str
    lastName: str
    email: str
    phone: Optional[str] = None


class ProfileUpdateRequest(BaseModel):
    onboarding: Optional[OnboardingData] = None
    preferences: Optional[PreferencesData] = None