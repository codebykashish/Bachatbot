from fastapi import APIRouter, Depends
from auth import get_current_user

router = APIRouter()


@router.get("/alerts")
async def get_alerts(
    current_user: dict = Depends(get_current_user)
):
    # TODO: Week 2
    return {"success": True, "data": {"alerts": [], "unreadCount": 0}}


@router.patch("/alerts/{alert_id}/read")
async def mark_alert_read(
    alert_id: str,
    current_user: dict = Depends(get_current_user)
):
    # TODO: Week 2
    return {"success": True, "message": "Coming soon"}