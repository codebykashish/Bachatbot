from fastapi import APIRouter, Depends
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from services.financial_engine import recompute as engine_recompute, RecomputeReason
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

    month_key = get_current_month_key()
    try:
        engine_recompute(db, uid, month_key, reason=RecomputeReason.INCOME_UPDATED)
    except Exception as _re:
        logger.warning(f"[INCOME] Engine recompute failed (non-fatal, old logic still authoritative): {_re}")

    # Create alert notifications for each changed source
    try:
        alerts_ref = db.collection("users").document(uid).collection("alerts")

        # Build one alert per changed source, with undo metadata
        source_changes: list[tuple[str, str, float]] = []  # (field, label, delta)

        if in_hand != old_in_hand:
            diff = in_hand - old_in_hand
            label = "In Hand"
            msg = f"Rs {int(diff)} added to {label} income." if diff > 0 else f"{label} income updated to Rs {int(in_hand)}."
            source_changes.append(("inHand", msg, diff))

        if in_bank != old_in_bank:
            diff = in_bank - old_in_bank
            label = "In Bank"
            msg = f"Rs {int(diff)} added to {label} income." if diff > 0 else f"{label} income updated to Rs {int(in_bank)}."
            source_changes.append(("inBank", msg, diff))

        if online_banking != old_online:
            diff = online_banking - old_online
            label = "Online Banking"
            msg = f"Rs {int(diff)} added to {label} income." if diff > 0 else f"{label} income updated to Rs {int(online_banking)}."
            source_changes.append(("onlineBanking", msg, diff))

        if not source_changes:
            source_changes.append(("", f"Rs {int(total)} total income set.", 0.0))

        for (source_field, msg, delta) in source_changes:
            # Only positive additions are undoable (incomeSource + incomeDelta)
            is_addition = source_field and delta > 0
            alerts_ref.document().set({
                "type": "income",
                "message": msg,
                "category": None,
                "amount": abs(delta),           # always show the real change amount
                "incomeSource": source_field if is_addition else None,
                "incomeDelta": delta if is_addition else 0.0,
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
