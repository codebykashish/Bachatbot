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
    tourCompleted: bool = False


class IncomeData(BaseModel):
    inHand: float = 0.0
    inBank: float = 0.0
    onlineBanking: float = 0.0
    total: float = 0.0

class NotificationPreferencesData(BaseModel):
    """
    Phase 16 — Notification Preferences. One bool per user-facing category
    (see FINANCIAL_ENGINE_SPEC.md "Phase 16 — Notification Preference
    Philosophy"). Missing category = True (opt-out only, never opt-in
    silently) so existing accounts need no migration.
    """
    transactions: bool = True
    budgetAlerts: bool = True
    financialHealth: bool = True
    recovery: bool = True
    streaks: bool = True
    milestones: bool = True

class PreferencesData(BaseModel):
    language: str = "en"
    currency: str = "NPR"
    alertThreshold: int = Field(default=80, ge=0, le=100)
    notifications: NotificationPreferencesData = Field(default_factory=NotificationPreferencesData)

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
    photoUrl: Optional[str] = None
    onboarding: OnboardingData
    preferences: PreferencesData
    income: Optional[IncomeData] = None
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
    photoUrl: Optional[str] = Field(
        default=None,
        description="Firebase Storage download URL for the user's profile photo",
    )
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

    # ── Password change (requires all three fields) ──────────────────────────
    currentPassword: Optional[str] = Field(
        default=None,
        description="Current password — required when changing password",
    )
    newPassword: Optional[str] = Field(
        default=None,
        description="New password — must meet strength requirements",
    )
    confirmNewPassword: Optional[str] = Field(
        default=None,
        description="Confirm new password — must match newPassword",
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

    @field_validator("newPassword", "currentPassword", "confirmNewPassword", mode="before")
    @classmethod
    def validate_password_fields(cls, v):
        """Reject passwords with only whitespace."""
        if v is not None:
            if str(v).strip() == "":
                return None # Treat empty string as None (no attempt to change)
        return v

    @model_validator(mode="after")
    def check_password_attempt(self):
        """
        Logic for 'User wants to change password' vs 'No password change'.
        If ANY field is provided, we treat it as an attempt.
        Verification of completeness and correctness is done in the route
        to provide the specific error JSON formats requested.
        """
        return self