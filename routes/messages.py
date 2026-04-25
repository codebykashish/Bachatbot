from fastapi import APIRouter, Depends
from auth import get_current_user

router = APIRouter()


@router.get("/messages")
async def get_messages(
    current_user: dict = Depends(get_current_user)
):
    # TODO: Day 6
    return {"success": True, "data": {"messages": [], "hasMore": False}}