from fastapi import APIRouter, Depends
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
import logging

router = APIRouter()
logger = logging.getLogger(__name__)


def _get_income_data(user_doc_data: dict) -> dict:
    income = user_doc_data.get("income", {})
    in_hand = float(income.get("inHand", 0.0))
    in_bank = float(income.get("inBank", 0.0))
    online_banking = float(income.get("onlineBanking", 0.0))
    return {
        "inHand": in_hand,
        "inBank": in_bank,
        "onlineBanking": online_banking,
        "total": in_hand + in_bank + online_banking,
    }


@router.get("/income")
async def get_income(current_user: dict = Depends(get_current_user)):
    """Return the user's declared income (in hand, bank, online banking)."""
    uid = current_user["uid"]
    db = get_firestore()
    doc = db.collection("users").document(uid).get()
    if not doc.exists:
        return {"success": True, "data": {"inHand": 0.0, "inBank": 0.0, "onlineBanking": 0.0, "total": 0.0}}
    return {"success": True, "data": _get_income_data(doc.to_dict())}


@router.post("/income")
async def update_income(
    body: dict,
    current_user: dict = Depends(get_current_user),
):
    """
    Set or update declared income sources.
    Supports partial updates — omit a field to keep it unchanged.
    Creates alert notifications for each changed source.
    """
    uid = current_user["uid"]
    db = get_firestore()
    user_ref = db.collection("users").document(uid)

    doc = user_ref.get()
    old_income: dict = {}
    if doc.exists:
        old_income = doc.to_dict().get("income", {})

    old_in_hand = float(old_income.get("inHand", 0.0))
    old_in_bank = float(old_income.get("inBank", 0.0))
    old_online = float(old_income.get("onlineBanking", 0.0))

    in_hand = float(body.get("inHand", old_in_hand))
    in_bank = float(body.get("inBank", old_in_bank))
    online_banking = float(body.get("onlineBanking", old_online))
    total = in_hand + in_bank + online_banking

    user_ref.update({
        "income.inHand": in_hand,
        "income.inBank": in_bank,
        "income.onlineBanking": online_banking,
        "income.updatedAt": SERVER_TIMESTAMP,
        "updatedAt": SERVER_TIMESTAMP,
    })
    logger.info(f"[INCOME] uid={uid} inHand={in_hand} inBank={in_bank} online={online_banking} total={total}")

    # Create alert notifications for each changed source
    try:
        month_key = get_current_month_key()
        alerts_ref = db.collection("users").document(uid).collection("alerts")

        messages: list[str] = []

        if in_hand != old_in_hand:
            diff = in_hand - old_in_hand
            if diff > 0:
                messages.append(f"Rs {int(diff)} added to In Hand income.")
            else:
                messages.append(f"In Hand income updated to Rs {int(in_hand)}.")

        if in_bank != old_in_bank:
            diff = in_bank - old_in_bank
            if diff > 0:
                messages.append(f"Rs {int(diff)} added to In Bank income.")
            else:
                messages.append(f"In Bank income updated to Rs {int(in_bank)}.")

        if online_banking != old_online:
            diff = online_banking - old_online
            if diff > 0:
                messages.append(f"Rs {int(diff)} added to Online Banking income.")
            else:
                messages.append(f"Online Banking income updated to Rs {int(online_banking)}.")

        if not messages:
            messages.append(f"Rs {int(total)} total income set.")

        for msg in messages:
            alerts_ref.document().set({
                "type": "income",
                "message": msg,
                "category": None,
                "severity": "low",
                "isRead": False,
                "isDeleted": False,
                "monthKey": month_key,
                "relatedTransactionId": None,
                "createdAt": SERVER_TIMESTAMP,
            })
    except Exception as e:
        logger.warning(f"[INCOME] alert creation failed: {e}")

    return {
        "success": True,
        "message": "Income updated successfully.",
        "data": {
            "inHand": in_hand,
            "inBank": in_bank,
            "onlineBanking": online_banking,
            "total": total,
        },
    }
