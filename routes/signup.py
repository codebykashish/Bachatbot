from fastapi import APIRouter, Depends, HTTPException
from firebase_config import get_firestore
from auth import get_current_user
from schemas.profile import SignupRequest
from utils import serialize_doc
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

router = APIRouter()


@router.post("/complete-signup", status_code=201)
async def complete_signup(
    body: SignupRequest,
    current_user: dict = Depends(get_current_user),
):
    """
    Creates user profile in Firestore after Firebase signup.
    Idempotent: if profile already exists, returns it instead of erroring.
    """
    uid = current_user["uid"]
    db = get_firestore()

    print(f"[SIGNUP] uid={uid} email={body.email}")

    user_ref = db.collection("users").document(uid)

    # Check if user already exists — return existing profile instead of 409
    existing = user_ref.get()
    if existing.exists:
        print(f"[SIGNUP] uid={uid} profile already exists, returning existing")
        data = existing.to_dict()
        data["uid"] = uid
        return {
            "success": True,
            "message": "Signup completed.",
            "data": serialize_doc(data),
        }

    # Build user document per schema.md
    user_data = {
        "firstName": body.firstName,
        "lastName": body.lastName,
        "email": body.email,
        "phone": body.phone,
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
        "onboarding": {
            "isCompleted": True,
            "occupation": None,
            "housingType": None,
            "estimatedMonthlySpend": None,
        },
        "preferences": {
            "language": "ne",
            "currency": "NPR",
            "alertThreshold": 80,
        },
    }

    user_ref.set(user_data)

    # Re-read to get resolved timestamps
    created_doc = user_ref.get()
    created_data = created_doc.to_dict()
    created_data["uid"] = uid

    print(f"[SIGNUP] uid={uid} profile created successfully")

    return {
        "success": True,
        "message": "Signup completed.",
        "data": serialize_doc(created_data),
    }