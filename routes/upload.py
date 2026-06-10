import os
import logging
import cloudinary
import cloudinary.uploader
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File

from auth import get_current_user

router = APIRouter()
logger = logging.getLogger(__name__)

# Configure Cloudinary from environment variables
cloudinary.config(
    cloud_name=os.getenv("CLOUDINARY_CLOUD_NAME"),
    api_key=os.getenv("CLOUDINARY_API_KEY"),
    api_secret=os.getenv("CLOUDINARY_API_SECRET"),
    secure=True,
)


@router.post("/upload/profile-photo")
async def upload_profile_photo(
    file: UploadFile = File(...),
    current_user: dict = Depends(get_current_user),
):
    """
    Accepts an image file (JPEG/PNG/WEBP), uploads it to Cloudinary,
    and returns the secure URL. Frontend then calls PATCH /profile
    with the returned photoUrl.
    """
    uid = current_user["uid"]

    # Validate file type
    allowed = {"image/jpeg", "image/png", "image/webp", "image/jpg"}
    if file.content_type not in allowed:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "INVALID_FILE_TYPE",
                "message": "Only JPEG, PNG, and WEBP images are accepted.",
            },
        )

    # Validate file size (max 5 MB)
    contents = await file.read()
    if len(contents) > 5 * 1024 * 1024:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "FILE_TOO_LARGE",
                "message": "Image must be smaller than 5 MB.",
            },
        )

    try:
        result = cloudinary.uploader.upload(
            contents,
            public_id=f"bachatbot/profile_photos/{uid}",
            overwrite=True,                # replaces previous photo for same user
            resource_type="image",
            transformation=[
                {"width": 400, "height": 400, "crop": "fill", "gravity": "face"},
                {"quality": "auto", "fetch_format": "auto"},
            ],
        )
        photo_url = result.get("secure_url")
        logger.info(f"[UPLOAD] uid={uid} profile photo uploaded: {photo_url}")
        return {"success": True, "photoUrl": photo_url}

    except Exception as e:
        logger.error(f"[UPLOAD] uid={uid} Cloudinary upload failed: {e}")
        raise HTTPException(
            status_code=500,
            detail={
                "error": "UPLOAD_FAILED",
                "message": "Failed to upload image. Please try again.",
            },
        )
