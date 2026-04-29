from firebase_admin import auth
from fastapi import Request, HTTPException
import logging
from datetime import datetime

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

async def get_current_user(request: Request):
    """
    This function runs on every protected endpoint.
    It reads the token from request header.
    It verifies the token with Firebase.
    It returns the user info (including uid).
    If token is missing or invalid, it returns 401 error.
    """
    timestamp = datetime.now().strftime("%H:%M:%S")

    # Step 1: Get the Authorization header
    auth_header = request.headers.get("Authorization")
    logger.info(f"[{timestamp}] 🔄 [AUTH] Authorization header present: {bool(auth_header)}")

    # Step 2: Check if header exists and has correct format
    if not auth_header:
        logger.warning(f"[{timestamp}] ❌ [AUTH] Missing Authorization header")
        raise HTTPException(
            status_code=401,
            detail={
                "success": False,
                "error": {
                    "code": "MISSING_TOKEN",
                    "message": "Authorization header is missing."
                }
            }
        )
    
    if not auth_header.startswith("Bearer "):
        logger.warning(f"[{timestamp}] ❌ [AUTH] Invalid token format: {auth_header[:20]}...")
        raise HTTPException(
            status_code=401,
            detail={
                "success": False,
                "error": {
                    "code": "INVALID_TOKEN_FORMAT",
                    "message": "Token must be in format: Bearer <token>"
                }
            }
        )
    
    # Step 3: Extract just the token part (remove "Bearer ")
    token = auth_header.split("Bearer ")[1].strip()
    logger.info(f"[{timestamp}] 🔑 [AUTH] Token extracted (length: {len(token)})")

    if not token:
        logger.warning(f"[{timestamp}] ❌ [AUTH] Token is empty")
        raise HTTPException(
            status_code=401,
            detail={
                "success": False,
                "error": {
                    "code": "EMPTY_TOKEN",
                    "message": "Token is empty."
                }
            }
        )
    
    # Step 4: Verify token with Firebase
    try:
        logger.info(f"[{timestamp}] 🔄 [AUTH] Verifying token with Firebase (check_revoked=True)...")
        decoded_token = auth.verify_id_token(token, check_revoked = False) # check_revoked=True makes sure logged-out tokens are instantly rejected!
        # decoded_token contains: uid, email, name, etc.
        uid = decoded_token.get("uid")
        email = decoded_token.get("email")
        logger.info(f"[{timestamp}] ✅ [AUTH] Token verified successfully - UID: {uid}, Email: {email}")
        return decoded_token
        
    except auth.ExpiredIdTokenError as e:
        logger.warning(f"[{timestamp}] ⏱️ [AUTH] Token expired: {str(e)}")
        raise HTTPException(
            status_code=401,
            detail={
                "success": False,
                "error": {
                    "code": "TOKEN_EXPIRED",
                    "message": "Token has expired. Please refresh and try again."
                }
            }
        )
    
    except auth.InvalidIdTokenError as e:
        logger.warning(f"[{timestamp}] ❌ [AUTH] Invalid token: {str(e)}")
        raise HTTPException(
            status_code=401,
            detail={
                "success": False,
                "error": {
                    "code": "INVALID_TOKEN",
                    "message": "Token is invalid."
                }
            }
        )
    
    except auth.RevokedIdTokenError as e:
        logger.warning(f"[{timestamp}] 🚫 [AUTH] Token revoked: {str(e)}")
        raise HTTPException(
            status_code=401,
            detail={
                "success": False,
                "error": {
                    "code": "TOKEN_REVOKED",
                    "message": "Token has been revoked. Please log in again."
                }
            }
        )
    
    except Exception as e:
        logger.error(f"[{timestamp}] ❌ [AUTH] Unexpected error: {type(e).__name__} - {str(e)}")
        raise HTTPException(
            status_code=401,
            detail={
                "success": False,
                "error": {
                    "code": "AUTH_FAILED",
                    "message": "Authentication failed."
                }
            }
        )