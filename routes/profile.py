from fastapi import APIRouter, Depends, HTTPException
from firebase_config import get_firestore
from auth import get_current_user
from schemas.profile import ProfileUpdateRequest
from utils import serialize_doc
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

router = APIRouter()


@router.get("/profile")
async def get_profile(
    current_user: dict = Depends(get_current_user)
):
    """
    Returns current user's full profile from Firestore.
    Frontend uses this to check if onboarding is done.
    """
    
    uid = current_user["uid"]
    db = get_firestore()
    
    # Fetch user document
    user_ref = db.collection("users").document(uid)
    doc = user_ref.get()
    
    # If user doesn't exist yet (should not happen normally)
    if not doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "USER_NOT_FOUND",
                    "message": "User profile not found. Please complete signup."
                }
            }
        )
    
    # Get data and add uid
    data = doc.to_dict()
    data["uid"] = uid
    
    # Convert timestamps
    response_data = serialize_doc(data)
    
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