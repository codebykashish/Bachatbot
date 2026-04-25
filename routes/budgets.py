from fastapi import APIRouter, Depends
from auth import get_current_user

router = APIRouter()


@router.post("/budgets")
async def create_budget(
    current_user: dict = Depends(get_current_user)
):
    # TODO: Week 2
    return {"success": True, "message": "Coming soon"}


@router.get("/budgets")
async def get_budgets(
    current_user: dict = Depends(get_current_user)
):
    # TODO: Week 2
    return {"success": True, "data": {"budgets": []}}