from fastapi import APIRouter, HTTPException, status
from schemas.auth import PasswordValidationRequest
from utils import validate_password
import logging

router = APIRouter(prefix="/auth", tags=["Authentication"])
logger = logging.getLogger(__name__)

@router.post("/validate-password")
async def validate_password_route(body: PasswordValidationRequest):
    """
    Validate password strength using shared helper.
    """
    password = body.password
    result = validate_password(password)
    
    if not result["isValid"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error": "WEAK_PASSWORD",
                "missing": result["missing"],
                "messageLines": result["messageLines"]
            }
        )
    
    return {"success": True, "message": "Password is valid"}
