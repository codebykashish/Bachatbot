from fastapi import APIRouter, Depends, HTTPException
from firebase_config import get_firestore
from auth import get_current_user
from schemas.profile import ProfileUpdateRequest
from utils import serialize_doc, get_current_month_key, sum_month_expense, sum_month_income
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from firebase_admin import auth as firebase_auth
import logging
from datetime import datetime

router = APIRouter()

logger = logging.getLogger(__name__)

@router.get("/profile")
async def get_profile(
    current_user: dict = Depends(get_current_user)
):
    """
    Returns current user's full profile from Firestore.
    Frontend uses this to check if onboarding is done.
    Also includes totalIncome and totalExpense for the home screen.
    """
    
    uid = current_user["uid"]
    print(f"[PROFILE] uid={uid} action=get")
    db = get_firestore()
    
    # Fetch user document
    user_ref = db.collection("users").document(uid)
    doc = user_ref.get()
    
    # If the Firestore profile doesn't exist yet (e.g. the user authenticated
    # via Firebase Auth but POST /profile was never called), auto-create a
    # minimal stub so GET /profile never 404s for a legitimately logged-in user.
    if not doc.exists:
        print(f"[PROFILE] uid={uid} — Firestore doc missing, auto-creating stub profile")
        stub = {
            "firstName": current_user.get("name", "").split()[0] if current_user.get("name") else "",
            "lastName": " ".join(current_user.get("name", "").split()[1:]) if current_user.get("name") else "",
            "email": current_user.get("email", ""),
            "phone": "",
            "onboarding": {
                "isCompleted": False,
                "occupation": None,
                "housingType": None,
                "estimatedMonthlySpend": None
            },
            "preferences": {
                "language": "en",
                "currency": "NPR",
                "alertThreshold": 80
            },
            "createdAt": SERVER_TIMESTAMP,
            "updatedAt": SERVER_TIMESTAMP
        }
        user_ref.set(stub)
        # Re-fetch so timestamps are populated
        doc = user_ref.get()
    
    # Get data and add uid
    data = doc.to_dict()
    data["uid"] = uid
    
    # Convert timestamps
    response_data = serialize_doc(data)
    
    # Aggregate current-month totals (same logic as monthly-report)
    month_key = get_current_month_key()
    total_income = sum_month_income(db, uid, month_key)
    total_expense = sum_month_expense(db, uid, month_key)
    response_data["totalIncome"] = total_income
    response_data["totalExpense"] = total_expense
    
    return {
        "success": True,
        "data": response_data
    }


@router.patch("/profile")
async def update_profile(
    body: ProfileUpdateRequest,
    current_user: dict = Depends(get_current_user)
):
    """
    Updates onboarding answers or preferences.
    Uses merge so only provided fields are updated.
    """
    
    uid = current_user["uid"]
    print(f"[PROFILE] uid={uid} action=update")
    db = get_firestore()
    
    user_ref = db.collection("users").document(uid)
    
    # Check user exists
    doc = user_ref.get()
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "USER_NOT_FOUND",
                    "message": "User profile not found."
                }
            }
        )
    
    # Build update dict with only provided fields
    update_data = {}
    update_data["updatedAt"] = SERVER_TIMESTAMP
    
    # If onboarding data provided, update those fields
    if body.onboarding is not None:
        onboarding_dict = body.onboarding.model_dump(exclude_none=False)
        # Use dot notation for nested fields (Firestore merge)
        for key, value in onboarding_dict.items():
            update_data[f"onboarding.{key}"] = value
    
    # If preferences data provided, update those fields
    if body.preferences is not None:
        preferences_dict = body.preferences.model_dump(exclude_none=False)
        for key, value in preferences_dict.items():
            update_data[f"preferences.{key}"] = value
    
    # If nothing was provided
    if len(update_data) == 1:  # only updatedAt
        return {
            "success": True,
            "message": "Nothing to update."
        }
    
    # Update Firestore document
    user_ref.update(update_data)
    
    return {
        "success": True,
        "message": "Profile updated."
    }


@router.post("/profile")
async def create_profile(
    body: dict,
    current_user: dict = Depends(get_current_user)
):
    """
    Create initial user profile (for new users after signup)
    """
    uid = current_user["uid"]
    db = get_firestore()
    
    firstName = body.get("firstName", "")
    lastName = body.get("lastName", "")
    email = body.get("email", "")
    phone = body.get("phone", "")
    
    if not all([firstName, lastName, email]):
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "MISSING_FIELDS",
                    "message": "firstName, lastName, and email are required"
                }
            }
        )
    
    user_ref = db.collection("users").document(uid)
    
    user_ref.set({
        "firstName": firstName,
        "lastName": lastName,
        "email": email,
        "phone": phone,
        "onboarding": {
            "isCompleted": False,
            "occupation": None,
            "housingType": None,
            "estimatedMonthlySpend": None
        },
        "preferences": {
            "language": "en",
            "currency": "NPR",
            "alertThreshold": 80
        },
        "createdAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP
    })
    
    return {
        "success": True,
        "message": "Profile created",
        "data": {
            "uid": uid,
            "firstName": firstName,
            "lastName": lastName,
            "email": email
        }
    }

@router.api_route("/logout", methods=["GET", "POST"])
async def logout(current_user: dict = Depends(get_current_user)):
    """
    Logs out the user by revoking their Firebase token.
    Frontend should call this on logout to invalidate the token.
    """
    timestamp = datetime.now().strftime("%H:%M:%S")
    uid = current_user.get("uid")
    email = current_user.get("email")
    
    logger.info(f"[{timestamp}] 🔄 [LOGOUT] Starting logout for user: {email} (UID: {uid})")
    
    try:
        logger.info(f"[{timestamp}] 🔑 [LOGOUT] Revoking refresh tokens for user: {uid}")
        firebase_auth.revoke_refresh_tokens(uid)
        
        logger.info(f"[{timestamp}] ✅ [LOGOUT] Successfully revoked tokens for user: {uid}")
        
        return {
            "success": True,
            "message": "User logged out successfully.",
            "user_uid": uid,
            "user_email": email
        }
        
    except Exception as e:
        logger.error(f"[{timestamp}] ❌ [LOGOUT] Error revoking tokens for {uid}: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail={
                "success": False,
                "error": {
                    "code": "LOGOUT_FAILED",
                    "message": f"Failed to log out user: {str(e)}"
                }
            }
        )