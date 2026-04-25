from fastapi import APIRouter, Depends
from auth import get_current_user

router = APIRouter()


@router.post("/confirm-transaction/{transaction_id}")
async def confirm_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user)
):
    # TODO: Week 2
    return {"success": True, "message": "Coming soon"}


@router.post("/reject-transaction/{transaction_id}")
async def reject_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user)
):
    # TODO: Week 2
    return {"success": True, "message": "Coming soon"}