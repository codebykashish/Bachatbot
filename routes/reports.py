from fastapi import APIRouter, Depends
from auth import get_current_user

router = APIRouter()


@router.get("/monthly-report")
async def get_monthly_report(
    current_user: dict = Depends(get_current_user)
):
    # TODO: Week 2
    return {"success": True, "message": "Coming soon"}