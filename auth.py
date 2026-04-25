from firebase_admin import auth
from fastapi import Request, HTTPException


async def get_current_user(request: Request):
    """
    This function runs on every protected endpoint.
    It reads the token from request header.
    It verifies the token with Firebase.
    It returns the user info (including uid).
    If token is missing or invalid, it returns 401 error.
    """
    
    # Step 1: Get the Authorization header
    auth_header = request.headers.get("Authorization")
    
    # Step 2: Check if header exists and has correct format
    if not auth_header:
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
    
    if not token:
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
        decoded_token = auth.verify_id_token(token)
        # decoded_token contains: uid, email, name, etc.
        return decoded_token
        
    except auth.ExpiredIdTokenError:
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
    
    except auth.InvalidIdTokenError:
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
    
    except auth.RevokedIdTokenError:
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