from fastapi import APIRouter, Depends, HTTPException
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment

router = APIRouter()


# ═══════════════════════════════════════════════════════════════════════════════
# POST /confirm-transaction/{transactionId}
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/confirm-transaction/{transaction_id}")
async def confirm_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    print(f"[CONFIRM] uid={uid} tx={transaction_id}")

    # ── 1. Fetch transaction ─────────────────────────────────────────────
    tx_ref = (
        db.collection("users").document(uid)
        .collection("transactions").document(transaction_id)
    )
    tx_doc = tx_ref.get()

    if not tx_doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "TRANSACTION_NOT_FOUND",
                    "message": "Transaction not found.",
                },
            },
        )

    tx = tx_doc.to_dict()

    if tx.get("status") != "pending":
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "NOT_PENDING",
                    "message": f"Transaction status is '{tx.get('status')}', not 'pending'.",
                },
            },
        )

    # ── 2. Confirm transaction ───────────────────────────────────────────
    tx_ref.update({
        "status":    "confirmed",
        "updatedAt": SERVER_TIMESTAMP,
    })
    print(f"[CONFIRM] Transaction {transaction_id} marked confirmed")

    # ── 3. Update matching notification ─────────────────────────────────
    notif_query = (
        db.collection("users").document(uid)
        .collection("notifications")
        .where("transactionId", "==", transaction_id)
        .limit(1)
        .stream()
    )
    for notif_doc in notif_query:
        notif_doc.reference.update({"status": "confirmed"})
        print(f"[CONFIRM] Notification {notif_doc.id} marked confirmed")
        break

    # ── 4. Budget update (expenses only) ────────────────────────────────
    budget_update = None
    alerts_created = []

    amount   = float(tx.get("amount", 0))
    category = tx.get("category")
    tx_type  = tx.get("type", "expense")
    month_key = tx.get("monthKey", get_current_month_key())

    if tx_type == "expense" and category:
        budgets_ref = db.collection("users").document(uid).collection("budgets")
        matching = list(
            budgets_ref
            .where("category", "==", category)
            .where("monthKey", "==", month_key)
            .limit(1)
            .stream()
        )
        if matching:
            bref = matching[0].reference
            bref.update({
                "spent":     Increment(amount),
                "updatedAt": SERVER_TIMESTAMP,
            })
            updated_budget = bref.get().to_dict()
            new_spent   = updated_budget.get("spent", 0.0)
            blimit      = updated_budget.get("limit", 0.0)
            remaining   = max(0.0, blimit - new_spent)
            percent_used = round((new_spent / blimit) * 100, 2) if blimit > 0 else 0.0
            budget_update = {
                "id":          matching[0].id,
                "category":    updated_budget.get("category", category),
                "limit":       blimit,
                "spent":       new_spent,
                "remaining":   remaining,
                "percentUsed": percent_used,
                "monthKey":    month_key,
            }
            print(
                f"[CONFIRM] Budget updated: {category} spent={new_spent} "
                f"({percent_used}%)"
            )

            # ── 5. Optional alert ────────────────────────────────────────
            try:
                alert_msg = (
                    f"Rs {int(amount)} {category} confirmed from notification."
                )
                aref = (
                    db.collection("users").document(uid)
                    .collection("alerts").document()
                )
                aref.set({
                    "type":      "transaction_confirmed",
                    "category":  category,
                    "message":   alert_msg,
                    "severity":  "medium" if percent_used >= 80 else "low",
                    "isRead":    False,
                    "isDeleted": False,
                    "monthKey":  month_key,
                    "createdAt": SERVER_TIMESTAMP,
                })
                alerts_created.append({
                    "id":       aref.id,
                    "type":     "transaction_confirmed",
                    "category": category,
                    "message":  alert_msg,
                    "severity": "medium" if percent_used >= 80 else "low",
                    "isRead":   False,
                    "monthKey": month_key,
                })
                print(f"[CONFIRM] Alert created: {aref.id}")
            except Exception as e:
                print(f"[CONFIRM] Alert FAILED: {e}")
        else:
            print(f"[CONFIRM] No budget for '{category}' in {month_key}")

    # income → no budget update (intentional)

    # ── 6. Create assistant message so Chat UI shows the result ──────────
    try:
        messages_ref = db.collection("users").document(uid).collection("messages")
        cat_display = category or "Income"
        confirm_reply = f"OK, Rs {int(amount)} {cat_display} ma save gareko chu ✅"
        msg_ref = messages_ref.document()
        msg_ref.set({
            "role":                 "assistant",
            "content":              confirm_reply,
            "intent":               "notification_confirmed",
            "extractedData":        {
                "amount": amount,
                "category": category,
                "type": tx_type,
            },
            "relatedTransactionId": transaction_id,
            "createdAt":            SERVER_TIMESTAMP,
        })
        print(f"[CONFIRM] Assistant message created: {msg_ref.id}")
    except Exception as e:
        print(f"[CONFIRM] Assistant message FAILED: {e}")

    return {
        "success": True,
        "message": "Transaction confirmed.",
        "data": {
            "transaction": {
                "id":        transaction_id,
                "amount":    amount,
                "category":  category,
                "type":      tx_type,
                "status":    "confirmed",
                "source":    tx.get("source"),
                "monthKey":  month_key,
            },
            "budgetUpdate": budget_update,
            "alerts":       alerts_created,
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# POST /reject-transaction/{transactionId}
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/reject-transaction/{transaction_id}")
async def reject_transaction(
    transaction_id: str,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    print(f"[REJECT] uid={uid} tx={transaction_id}")

    # ── 1. Fetch transaction ─────────────────────────────────────────────
    tx_ref = (
        db.collection("users").document(uid)
        .collection("transactions").document(transaction_id)
    )
    tx_doc = tx_ref.get()

    if not tx_doc.exists:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "TRANSACTION_NOT_FOUND",
                    "message": "Transaction not found.",
                },
            },
        )

    tx = tx_doc.to_dict()

    if tx.get("status") != "pending":
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "NOT_PENDING",
                    "message": f"Transaction status is '{tx.get('status')}', not 'pending'.",
                },
            },
        )

    # ── 2. Reject transaction ────────────────────────────────────────────
    tx_ref.update({
        "status":    "rejected",
        "updatedAt": SERVER_TIMESTAMP,
    })
    print(f"[REJECT] Transaction {transaction_id} marked rejected")

    # ── 3. Update matching notification ─────────────────────────────────
    notif_query = (
        db.collection("users").document(uid)
        .collection("notifications")
        .where("transactionId", "==", transaction_id)
        .limit(1)
        .stream()
    )
    for notif_doc in notif_query:
        notif_doc.reference.update({"status": "rejected"})
        print(f"[REJECT] Notification {notif_doc.id} marked rejected")
        break

    # ── 4. No budget changes on rejection ────────────────────────────────

    # ── 5. Create assistant message so Chat UI shows the rejection ───────
    amount   = float(tx.get("amount", 0))
    category = tx.get("category", "")
    source_app = tx.get("description", "").split(":")[0] if ":" in tx.get("description", "") else "Notification"
    try:
        messages_ref = db.collection("users").document(uid).collection("messages")
        reject_reply = f"OK, {source_app} Rs {int(amount)} {category} transaction ignore gareko chu."
        msg_ref = messages_ref.document()
        msg_ref.set({
            "role":                 "assistant",
            "content":              reject_reply,
            "intent":               "notification_rejected",
            "extractedData":        None,
            "relatedTransactionId": transaction_id,
            "createdAt":            SERVER_TIMESTAMP,
        })
        print(f"[REJECT] Assistant message created: {msg_ref.id}")
    except Exception as e:
        print(f"[REJECT] Assistant message FAILED: {e}")

    return {
        "success": True,
        "message": "Transaction rejected.",
        "data": {
            "transaction": {
                "id":       transaction_id,
                "amount":   amount,
                "category": category,
                "type":     tx.get("type"),
                "status":   "rejected",
                "source":   tx.get("source"),
                "monthKey": tx.get("monthKey"),
            },
            "budgetUpdate": None,
            "alerts":       [],
        },
    }