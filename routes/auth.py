from fastapi import APIRouter, HTTPException, status
from schemas.auth import PasswordValidationRequest, WeakPasswordError
import re
import logging

router = APIRouter(prefix="/auth", tags=["Authentication"])
logger = logging.getLogger(__name__)

@router.post("/validate-password")
async def validate_password(body: PasswordValidationRequest):
    """
    Validate password strength based on:
    - Minimum length (8 characters)
    - At least one number
    - At least one special character
    """
    password = body.password
    
    missing = {
        "minimumLength": len(password) < 8,
        "number": not any(char.isdigit() for char in password),
        "specialCharacter": not any(not char.isalnum() for char in password)
    }
    
    if any(missing.values()):
        messages = []
        if missing["minimumLength"]:
            messages.append("at least 8 characters")
            
        needed = []
        if missing["number"]:
            needed.append("one number (e.g. 1, 2, 3)")
        if missing["specialCharacter"]:
            needed.append("one special character (e.g. @, #, *)")
            
        if needed:
            messages.append("at least " + " and ".join(needed))
        
        # Combine messages
        if len(messages) == 2:
            message = f"Password must contain {messages[0]} and {messages[1]}."
        else:
            message = f"Password must contain {messages[0]}."
            
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error": "WEAK_PASSWORD",
                "missing": missing,
                "message": message
            }
        )
    
    return {"success": True, "message": "Password is valid"}
