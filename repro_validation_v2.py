import sys
import os
import asyncio
from fastapi import HTTPException
from unittest.mock import MagicMock, patch

# Add current directory to path
sys.path.append(os.getcwd())

from routes.verification import send_verification_code, SendVerificationCodeRequest, check_email, EmailCheckRequest
from routes.auth import validate_password
from schemas.auth import PasswordValidationRequest

async def test_domain_validation():
    print("\n--- Testing Domain Validation ---")
    test_emails = [
        ("user@gmail.com", True),
        ("user@gnail.com", False),
        ("user@gmail.con", False),
        ("user@other.com", False),
    ]
    
    for email, should_pass in test_emails:
        try:
            # Test check_email
            body = EmailCheckRequest(email=email)
            with patch("routes.verification.get_firestore"):
                await check_email(body)
            print(f"Email: {email} -> check_email: PASSED")
            if not should_pass:
                print(f"FAILED: {email} should have been rejected by check_email")
        except HTTPException as e:
            print(f"Email: {email} -> check_email: REJECTED: {e.detail}")
            if should_pass:
                print(f"FAILED: {email} should have been accepted by check_email")

        try:
            # Test send_verification_code (signup)
            body = SendVerificationCodeRequest(email=email, purpose="signup")
            with patch("routes.verification.get_firestore"):
                await send_verification_code(body)
            print(f"Email: {email} -> send_code (signup): PASSED")
            if not should_pass:
                print(f"FAILED: {email} should have been rejected by send_code (signup)")
        except HTTPException as e:
            print(f"Email: {email} -> send_code (signup): REJECTED: {e.detail}")
            if should_pass:
                print(f"FAILED: {email} should have been accepted by send_code (signup)")

async def test_password_friendly_messages():
    print("\n--- Testing Password Friendly Messages ---")
    test_passwords = [
        ("short", "Password must contain at least 8 characters and at least one number (e.g. 1, 2, 3) and one special character (e.g. @, #, *)."),
        ("kashishdhami", "Password must contain at least one number (e.g. 1, 2, 3) and one special character (e.g. @, #, *)."),
        ("kashishdhami7", "Password must contain at least one special character (e.g. @, #, *)."),
        ("StrongP@ss1", "SUCCESS"),
    ]
    
    for pwd, expected_msg in test_passwords:
        try:
            body = PasswordValidationRequest(password=pwd)
            await validate_password(body)
            print(f"Password: {pwd} -> SUCCESS")
            if expected_msg != "SUCCESS":
                print(f"FAILED: {pwd} should have been rejected")
        except HTTPException as e:
            msg = e.detail["message"]
            print(f"Password: {pwd} -> REJECTED: {msg}")
            # Note: The logic in routes/auth.py might produce slightly different wording than expected_msg if not careful.
            # Let's see what it actually outputs.

if __name__ == "__main__":
    asyncio.run(test_domain_validation())
    asyncio.run(test_password_friendly_messages())
