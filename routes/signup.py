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
    current_user: dict = Depends(get_current_user)
):
    """
    Creates user profile in Firestore after Firebase signup.
    Called once immediately after signup.
    """
    
    # Get uid from verified token
    uid = current_user["uid"]
    
    # Get Firestore client
    db = get_firestore()
    
    # Reference to user document
    user_ref = db.collection("users").document(uid)
    
    # Check if user already exists
    existing = user_ref.get()
    if existing.exists:
        raise HTTPException(
            status_code=409,
            detail={
                "success": False,
                "error": {
                    "code": "USER_EXISTS",
                    "message": "User profile already exists."
                }
            }
        )
    
    # Build user document
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
            "estimatedMonthlySpend": None
        },
        "preferences": {
            "language": "ne",
            "currency": "NPR",
            "alertThreshold": 80
        }
    }
    
    # Write to Firestore
    user_ref.set(user_data)
    
    # Fetch the created document to return it
    # (SERVER_TIMESTAMP gets resolved by Firestore)
    created_doc = user_ref.get()
    created_data = created_doc.to_dict()
    
    # Add uid to response
    created_data["uid"] = uid
    
    # Convert timestamps to strings for JSON response
    response_data = serialize_doc(created_data)
    
    return {
        "success": True,
        "message": "Signup completed.",
        "data": response_data
    }