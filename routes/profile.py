from fastapi import APIRouter, Depends, HTTPException
from firebase_config import get_firestore
from auth import get_current_user
from schemas.profile import ProfileUpdateRequest, UserProfileResponse
from utils import serialize_doc, get_current_month_key, sum_month_expense, sum_month_income
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from firebase_admin import auth as firebase_auth
from passlib.context import CryptContext
import logging
from datetime import datetime

# ── Password hashing utility (bcrypt) ────────────────────────────────────────
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

profile_router = APIRouter()

logger = logging.getLogger(__name__)


@profile_router.get("/api/v1/user/profile")
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
    
    # ── Allow core profile fields to be None/null if missing ────────────────
    # Frontend handles fallback; we return null if not yet set in Firestore.
    first_name = data.get("firstName")
    last_name = data.get("lastName")
    phone_number = data.get("phoneNumber") or data.get("phone")

    # Build the profile data for Pydantic model block
    profile_block = {
        "uid": uid,
        "firstName": first_name,
        "lastName": last_name,
        "email": data.get("email"),
        "phoneNumber": phone_number,
        "onboarding": response_data.get("onboarding") or {},
        "preferences": response_data.get("preferences") or {},
        "createdAt": response_data.get("createdAt"),
        "updatedAt": response_data.get("updatedAt")
    }

    # Serialize into the Pydantic model response block
    profile_response = UserProfileResponse(**profile_block)
    
    # Dump to dict
    serialized_profile = profile_response.model_dump()

    # Aggregate current-month totals (same logic as monthly-report)
    month_key = get_current_month_key()
    total_income = sum_month_income(db, uid, month_key)
    total_expense = sum_month_expense(db, uid, month_key)
    serialized_profile["totalIncome"] = total_income
    serialized_profile["totalExpense"] = total_expense
    
    return {
        "success": True,
        "data": serialized_profile
    }


@profile_router.patch("/api/v1/user/profile")
async def update_profile(
    body: ProfileUpdateRequest,
    current_user: dict = Depends(get_current_user)
):
    """
    Updates onboarding answers, preferences, and/or core profile fields.

    Accepted fields (all optional):
      - firstName / lastName   → written to Firestore user document
      - phoneNumber            → written to Firestore user document as 'phone'
      - currentPassword + newPassword → verified against stored bcrypt hash,
            then new hash saved to Firestore and Firebase Auth is synced
      - onboarding             → merged into the onboarding sub-map
      - preferences            → merged into the preferences sub-map

    User isolation: uid is always sourced from the verified Firebase token.
    A user can only update their own record.
    """

    uid = current_user["uid"]
    timestamp_str = datetime.now().strftime("%H:%M:%S")
    logger.info(f"[{timestamp_str}] [PROFILE] uid={uid} action=patch")
    db = get_firestore()

    user_ref = db.collection("users").document(uid)

    # ── Verify the user document exists ─────────────────────────────────────────
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

    user_data = doc.to_dict()

    # ── Build Firestore update payload ────────────────────────────────────────────
    update_data = {}
    update_data["updatedAt"] = SERVER_TIMESTAMP

    # Core identity fields — written directly to top-level document keys
    if body.firstName is not None:
        update_data["firstName"] = body.firstName
        logger.info(f"[{timestamp_str}] [PROFILE] uid={uid} updating firstName")

    if body.lastName is not None:
        update_data["lastName"] = body.lastName
        logger.info(f"[{timestamp_str}] [PROFILE] uid={uid} updating lastName")

    if body.phoneNumber is not None:
        # Stored as 'phone' in Firestore per schema.md
        update_data["phone"] = body.phoneNumber
        logger.info(f"[{timestamp_str}] [PROFILE] uid={uid} updating phone")

    # Onboarding sub-map (dot-notation merge)
    if body.onboarding is not None:
        onboarding_dict = body.onboarding.model_dump(exclude_none=False)
        for key, value in onboarding_dict.items():
            update_data[f"onboarding.{key}"] = value

    # Preferences sub-map (dot-notation merge)
    if body.preferences is not None:
        preferences_dict = body.preferences.model_dump(exclude_none=False)
        for key, value in preferences_dict.items():
            update_data[f"preferences.{key}"] = value

    # ── Password change logic ───────────────────────────────────────────────────
    curr_pass = body.currentPassword
    new_pass = body.newPassword
    conf_pass = body.confirmNewPassword

    # Check if ANY password field is provided (attempt to change)
    is_attempting_password_change = any([curr_pass, new_pass, conf_pass])

    if is_attempting_password_change:
        # 1. All three must be present
        if not all([curr_pass, new_pass, conf_pass]):
            raise HTTPException(
                status_code=400,
                detail={
                    "success": False,
                    "error": "PASSWORD_FIELDS_INCOMPLETE",
                    "message": "To change your password, please fill Current Password, New Password and Confirm New Password."
                }
            )

        # 2. Confirm new password matches
        if new_pass != conf_pass:
            raise HTTPException(
                status_code=400,
                detail={
                    "success": False,
                    "error": "PASSWORD_MISMATCH",
                    "message": "New password and confirm password do not match."
                }
            )

        # 3. Check new password strength (same as signup)
        # Rules: 8+ chars, 1 number, 1 special character
        has_min_length = len(new_pass) >= 8
        has_number = any(char.isdigit() for char in new_pass)
        has_special = any(not char.isalnum() for char in new_pass)

        if not all([has_min_length, has_number, has_special]):
            raise HTTPException(
                status_code=400,
                detail={
                    "success": False,
                    "error": "WEAK_PASSWORD",
                    "missing": {
                        "minimumLength": not has_min_length,
                        "number": not has_number,
                        "specialCharacter": not has_special
                    },
                    "message": "Your new password is missing:\n- at least 8 characters\n- one number (e.g. 1, 2, 3)\n- one special character (e.g. @, #, *)."
                }
            )

        # 4. Verify current password
        stored_hash = user_data.get("passwordHash")
        # If no stored hash, they likely signed up via social login or something else
        if not stored_hash or not pwd_context.verify(curr_pass, stored_hash):
            logger.warning(f"[{timestamp_str}] [PROFILE] uid={uid} current password incorrect")
            raise HTTPException(
                status_code=400,
                detail={
                    "success": False,
                    "error": "CURRENT_PASSWORD_INCORRECT",
                    "message": "The current password you entered is wrong."
                }
            )

        # 5. New password must be different from current password
        if new_pass == curr_pass:
            raise HTTPException(
                status_code=400,
                detail={
                    "success": False,
                    "error": "NEW_PASSWORD_SAME_AS_CURRENT",
                    "message": "New password cannot be the same as your current password."
                }
            )

        # 6. All checks passed — hash new password
        update_data["passwordHash"] = pwd_context.hash(new_pass)
        logger.info(f"[{timestamp_str}] [PROFILE] uid={uid} new passwordHash staged")

    # ── Guard: nothing meaningful to update ─────────────────────────────────────────
    # len == 1 means only 'updatedAt' was set
    has_firestore_updates = len(update_data) > 1

    if not has_firestore_updates:
        return {
            "success": True,
            "message": "Nothing to update."
        }

    # ── Apply Firestore update (all fields including passwordHash) ────────────────
    user_ref.update(update_data)
    logger.info(f"[{timestamp_str}] [PROFILE] uid={uid} Firestore document updated")

    # ── Sync password to Firebase Auth ───
    if is_attempting_password_change:
        try:
            firebase_auth.update_user(uid, password=new_pass)
            logger.info(f"[{timestamp_str}] [PROFILE] uid={uid} Firebase Auth password synced")
        except Exception as e:
            logger.error(f"[{timestamp_str}] [PROFILE] uid={uid} Firebase Auth sync failed: {e}")

    # ── Build clean success payload ───────────────────────────────────────────────
    updated_fields = []
    if body.firstName is not None:
        updated_fields.append("firstName")
    if body.lastName is not None:
        updated_fields.append("lastName")
    if body.phoneNumber is not None:
        updated_fields.append("phoneNumber")
    if is_attempting_password_change:
        updated_fields.append("password")
    if body.onboarding is not None:
        updated_fields.append("onboarding")
    if body.preferences is not None:
        updated_fields.append("preferences")

    # Fetch updated doc to return full object as requested
    updated_doc = user_ref.get().to_dict()
    updated_doc["uid"] = uid
    response_payload = serialize_doc(updated_doc)
    
    # Extract phone back to phoneNumber for the response consistency
    response_payload["phoneNumber"] = response_payload.get("phone", "")

    return {
        "success": True,
        "message": "Profile updated successfully.",
        "updatedFields": updated_fields,
        "data": response_payload
    }


@profile_router.post("/api/v1/user/profile")
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

@profile_router.api_route("/logout", methods=["GET", "POST"])
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