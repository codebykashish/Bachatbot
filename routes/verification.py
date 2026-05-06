import os
import random
import smtplib
import logging
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime, timezone, timedelta

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr
from firebase_config import get_firestore

router = APIRouter()
logger = logging.getLogger(__name__)


# ─── Request Schemas ────────────────────────────────────────────────────────

class SendVerificationCodeRequest(BaseModel):
    email: EmailStr


class VerifyCodeRequest(BaseModel):
    email: EmailStr
    code: str


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _send_email(recipient: str, code: str) -> None:
    """
    Sends a 6-digit verification code to `recipient` via Gmail SMTP.
    Reads SMTP_EMAIL / SMTP_PASSWORD from environment.
    """
    smtp_email = os.getenv("SMTP_EMAIL")
    smtp_password = os.getenv("SMTP_PASSWORD")

    if not smtp_email or not smtp_password:
        raise RuntimeError("SMTP_EMAIL or SMTP_PASSWORD not set in environment.")

    subject = "BachatBot – Your Verification Code"
    body_text = (
        f"Your BachatBot verification code is: {code}\n\n"
        f"This code will expire in 10 minutes.\n\n"
        f"If you did not request this, please ignore this email."
    )
    body_html = f"""
    <div style="font-family:Arial,sans-serif;max-width:480px;margin:auto;padding:32px;
                border:1px solid #e5e7eb;border-radius:12px;background:#fafafa;">
      <h2 style="color:#1e293b;margin-bottom:8px;">BachatBot Verification</h2>
      <p style="color:#475569;font-size:15px;margin-bottom:24px;">
        Use the code below to verify your email address. It expires in <strong>10 minutes</strong>.
      </p>
      <div style="background:#f1f5f9;border-radius:8px;padding:20px;text-align:center;">
        <span style="font-size:36px;font-weight:700;letter-spacing:8px;color:#0ea5e9;">{code}</span>
      </div>
      <p style="color:#94a3b8;font-size:13px;margin-top:24px;">
        If you did not request this, you can safely ignore this email.
      </p>
    </div>
    """

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = smtp_email
    msg["To"] = recipient
    msg.attach(MIMEText(body_text, "plain"))
    msg.attach(MIMEText(body_html, "html"))

    with smtplib.SMTP_SSL("smtp.gmail.com", 465) as server:
        server.login(smtp_email, smtp_password)
        server.sendmail(smtp_email, recipient, msg.as_string())


# ─── Endpoints ───────────────────────────────────────────────────────────────

@router.post("/send-verification-code")
async def send_verification_code(body: SendVerificationCodeRequest):
    """
    Generates a random 6-digit OTP, stores it in Firestore under
    verification_codes/{email}, and sends it via Gmail SMTP.
    No authentication required (pre-signup flow).
    """
    email = body.email.lower().strip()
    db = get_firestore()

    # Generate 6-digit code (zero-padded so "001234" stays as string)
    code = str(random.randint(100000, 999999))

    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(minutes=10)

    # Upsert verification_codes/{email}
    doc_ref = db.collection("verification_codes").document(email)
    doc_ref.set({
        "code": code,
        "createdAt": now,
        "expiresAt": expires_at,
    })

    # Send email — surface errors as 500 so client can retry
    try:
        _send_email(email, code)
    except Exception as exc:
        logger.error(f"[VERIFICATION] Failed to send email to {email}: {exc}")
        raise HTTPException(
            status_code=500,
            detail={
                "success": False,
                "error": {
                    "code": "EMAIL_SEND_FAILED",
                    "message": "Failed to send verification email. Please try again.",
                },
            },
        )

    logger.info(f"[VERIFICATION] Code sent to {email}")
    return {"success": True, "message": "Verification code sent to your email."}


@router.post("/verify-code")
async def verify_code(body: VerifyCodeRequest):
    """
    Validates a 6-digit OTP against the Firestore verification_codes/{email} doc.
    On success the document is deleted so the code cannot be reused.
    No authentication required (pre-signup flow).
    """
    email = body.email.lower().strip()
    code = body.code.strip()
    db = get_firestore()

    doc_ref = db.collection("verification_codes").document(email)
    doc = doc_ref.get()

    if not doc.exists:
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "INVALID_CODE",
                    "message": "Invalid or expired verification code.",
                },
            },
        )

    data = doc.to_dict()
    stored_code: str = data.get("code", "")
    expires_at: datetime = data.get("expiresAt")

    # Normalise timezone — Firestore returns UTC-aware datetimes
    now = datetime.now(timezone.utc)
    if expires_at and expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)

    # Check expiry first (timing-safe: no code comparison if already expired)
    if expires_at and now > expires_at:
        doc_ref.delete()  # clean up stale document
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "CODE_EXPIRED",
                    "message": "Verification code has expired. Please request a new one.",
                },
            },
        )

    # Check code match
    if code != stored_code:
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "INVALID_CODE",
                    "message": "Verification code is incorrect.",
                },
            },
        )

    # Success — delete doc so the code cannot be reused
    doc_ref.delete()
    logger.info(f"[VERIFICATION] Email verified: {email}")

    return {"success": True, "verified": True, "message": "Email verified successfully."}
