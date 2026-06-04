from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator, ConfigDict
from typing import Optional
from enum import Enum
import re

class OccupationEnum(str, Enum):
    STUDENT = "student"
    EMPLOYED = "employed"
    BUSINESS = "business"

class HousingTypeEnum(str, Enum):
    RENT = "rent"
    OWN = "own"

class OnboardingData(BaseModel):
    isCompleted: bool = False
    occupation: Optional[OccupationEnum] = None
    housingType: Optional[HousingTypeEnum] = None
    estimatedMonthlySpend: Optional[float] = None

class PreferencesData(BaseModel):
    language: str = "en"
    currency: str = "NPR"
    alertThreshold: int = Field(default=80, ge=0, le=100)

class UserProfileCreate(BaseModel):
    firstName: str = Field(..., min_length=1)
    lastName: str = Field(..., min_length=1)
    email: EmailStr
    phone: str

class UserProfileResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    uid: str
    firstName: Optional[str] = None
    lastName: Optional[str] = None
    email: Optional[str] = None
    phoneNumber: Optional[str] = Field(None, alias="phone")
    onboarding: OnboardingData
    preferences: PreferencesData
    createdAt: Optional[str] = None
    updatedAt: Optional[str] = None

class SignupRequest(BaseModel):
    firstName: str
    lastName: str
    email: str
    phone: str

class ProfileUpdateRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    # ── Onboarding / Preferences (existing fields) ──────────────────────────
    onboarding: Optional[OnboardingData] = None
    preferences: Optional[PreferencesData] = None

    # ── Core profile fields ──────────────────────────────────────────────────
    firstName: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=50,
        description="User's first name (1-50 characters)",
    )
    lastName: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=50,
        description="User's last name (1-50 characters)",
    )
    phoneNumber: Optional[str] = Field(
        default=None,
        alias="phone",
        description="Phone number in international (+977...) or local (98...) format",
    )


    @field_validator("firstName", "lastName", mode="before")
    @classmethod
    def strip_name(cls, v):
        """Strip leading/trailing whitespace from name fields."""
        if v is not None:
            v = str(v).strip()
            if not v:
                raise ValueError("Name fields must not be blank or whitespace-only.")
        return v

    @field_validator("phoneNumber", mode="before")
    @classmethod
    def validate_phone(cls, v):
        """
        Accepts:
          - International E.164 style: +977XXXXXXXXXX
          - Local 10-digit Nepali numbers: 98XXXXXXXX / 97XXXXXXXX
          - Generic 7-15 digit numbers with optional leading +
        Rejects obvious garbage.
        """
        if v is None:
            return v
        cleaned = str(v).strip()
        # Allow + prefix then digits only; 7–15 total digits
        pattern = r'^\+?[0-9]{7,15}$'
        if not re.match(pattern, cleaned):
            raise ValueError(
                "phoneNumber must be a valid phone number (7-15 digits, optional leading +)."
            )
        return cleaned
