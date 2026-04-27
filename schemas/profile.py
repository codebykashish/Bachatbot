from pydantic import BaseModel, EmailStr, Field
from typing import Optional
from enum import Enum

class OccupationEnum(str, Enum):
    STUDENT = "student"
    EMPLOYED = "employed"
    BUSINESS = "business"

class HousingTypeEnum(str, Enum):
    RENT = "rent"
    OWN = "own"

class OnboardingData(BaseModel):
    isComplete: bool = False
    occupation: Optional[OccupationEnum] = None
    housingType: Optional[HousingTypeEnum] = None
    estimatedMontlySpend: Optional[float] = None

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
    uid: str
    firstName: str
    lastName: str
    email: str
    phone: str
    onboarding: OnboardingData
    preferences: PreferencesData
    createdAt: str
    updatedAt: str

class SignupRequest(BaseModel):
    firstName: str
    lastName: str
    email: str
    phone: str

class ProfileUpdateRequest(BaseModel):
    onboarding: Optional[OnboardingData] = None
    preferences: Optional[PreferencesData] = None