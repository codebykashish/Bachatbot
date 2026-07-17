from fastapi import APIRouter, Depends, HTTPException, Body
from firebase_config import get_firestore
from auth import get_current_user
from utils import get_current_month_key
from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment
from typing import Optional, List
from pydantic import BaseModel
from services.budget_service import apply_pending_rebalance, reject_pending_rebalance
from services.financial_engine import recompute as engine_recompute, RecomputeReason

router = APIRouter()


def _cleanup_stale_pending_alert(db, uid: str, transaction_id: str, message: str):
    """
    Marks the "pending_transaction" alert for this transaction as resolved
    and hides it. Used when the alert is stale — the transaction was
    already confirmed/cancelled through some other path — so tapping the
    old alert card cleans itself up instead of throwing an error forever.
    """
    try:
        query = (
            db.collection("users").document(uid).collection("alerts")
            .where("relatedTransactionId", "==", transaction_id)
            .where("type", "==", "pending_transaction")
            .limit(1)
            .stream()
        )
        for doc in query:
            doc.reference.update({
                "message": message,
                "isRead": True,
                "isDeleted": True,
            })
            break
    except Exception as e:
        print(f"[CLEANUP] stale pending_transaction alert update failed (non-fatal): {e}")


# ─── Request Schemas ─────────────────────────────────────────────────────────

class ConfirmTransactionBody(BaseModel):
    """Optional updates that can be applied while confirming a single transaction."""
    amount: Optional[float] = None
    category: Optional[str] = None


class BulkConfirmItem(BaseModel):
    """One item in a bulk confirm/cancel request."""
    id: str
    amount: Optional[float] = None
    category: Optional[str] = None


class BulkConfirmBody(BaseModel):
    """
    Body for POST /confirm-transactions (bulk).
    action: "confirm" | "cancel"
    transactions: list of items with optional field overrides.
    """
    action: str = "confirm"   # "confirm" or "cancel"
    transactions: List[BulkConfirmItem]


# ═══════════════════════════════════════════════════════════════════════════════
# POST /confirm-transaction/{transactionId}
# Confirms a single pending transaction (notification OR chat-pending).
# Now accepts optional body: { "amount": ..., "category": ... }
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/confirm-transaction/{transaction_id}")
async def confirm_transaction(
    transaction_id: str,
    body: ConfirmTransactionBody = Body(default=ConfirmTransactionBody()),
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    print(f"[CONFIRM] uid={uid} tx={transaction_id} override_amount={body.amount} override_category={body.category}")

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
        # Already resolved through some other path (e.g. a stale alert
        # card tapped after the underlying transaction was already
        # confirmed/cancelled elsewhere) — clean up the stale alert instead
        # of erroring, so the card disappears instead of staying stuck.
        existing_status = tx.get("status")
        _cleanup_stale_pending_alert(
            db, uid, transaction_id,
            f"This transaction was already {existing_status}.",
        )
        return {
            "success": True,
            "message": f"Already {existing_status} — nothing to do.",
            "data": {
                "transaction": {
                    "id": transaction_id,
                    "status": existing_status,
                },
                "budgetUpdate": None,
                "alreadyResolved": True,
            },
        }

    # Use effective values (overridden or original)
    amount   = float(body.amount)   if body.amount   is not None else float(tx.get("amount", 0))
    category = body.category        if body.category is not None else tx.get("category")
    tx_type  = tx.get("type", "expense")
    month_key = tx.get("monthKey", get_current_month_key())

    # ── 2a. ENFORCE CATEGORY for notifications — expenses only. Income
    # never has a spending category, so it must never be required here.
    if tx.get("source") == "notification" and tx_type == "expense" and not category:
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "CATEGORY_REQUIRED",
                    "message": "Please select a category for this notification transaction.",
                },
            },
        )

    # ── 2b. Apply optional overrides + confirm ────────────────────────────
    # PRE-EXISTING BUG, fixed here: update_payload was built but never
    # written to tx_ref, so a transaction confirmed through this single
    # endpoint stayed status="pending" in Firestore forever — the old
    # budget.spent Increment() below doesn't check the transaction's own
    # persisted status, so it silently "worked" anyway, but the transaction
    # itself never actually became confirmed. This was invisible before the
    # Engine started summing from confirmed transactions directly; it's the
    # first thing this migration needs correct, since the Engine now
    # depends on this write actually happening.
    update_payload: dict = {
        "status":    "confirmed",
        "updatedAt": SERVER_TIMESTAMP,
    }
    if body.amount is not None:
        update_payload["amount"] = amount
    if body.category is not None:
        update_payload["category"] = category
    tx_ref.update(update_payload)

    # ── 3. Update matching notification ─────────────────────────────────
    notif_query = (
        db.collection("users").document(uid)
        .collection("notifications")
        .where("transactionId", "==", transaction_id)
        .limit(1)
        .stream()
    )
    for notif_doc in notif_query:
        notif_update: dict = {"status": "confirmed"}
        if body.category is not None:
            notif_update["parsedCategory"] = body.category
        if body.amount is not None:
            notif_update["parsedAmount"] = float(body.amount)
        notif_doc.reference.update(notif_update)
        print(f"[CONFIRM] Notification {notif_doc.id} marked confirmed")
        break

    # ── 4. Budget update (expenses only) ────────────────────────────────
    budget_update = None
    alerts_created = []

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

            # Rebalance if overspent — same pattern as manual/chat expenses:
            # nothing is applied until the user confirms via /confirm-rebalance.
            if new_spent > blimit:
                try:
                    from services.budget_service import rebalance_on_overspend
                    rb = rebalance_on_overspend(
                        db, uid, category, new_spent, blimit, matching[0].id, month_key
                    )
                    if rb:
                        budget_update["pendingRebalance"] = rb
                        print(f"[CONFIRM] [REBALANCE] pending confirmation id={rb['rebalanceId']}")
                except Exception as rb_err:
                    print(f"[CONFIRM] [REBALANCE] error (non-fatal): {rb_err}")

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

    # ── 5b. Update the original "pending_transaction" alert in place ─────
    # Without this it stays stuck showing "Transaction Detected" forever —
    # tappable again, and a second confirm attempt fails silently since the
    # transaction is no longer pending. Turning it into a normal-looking
    # confirmed entry means the Activity feed reflects the real state.
    try:
        pending_alert_query = (
            db.collection("users").document(uid).collection("alerts")
            .where("relatedTransactionId", "==", transaction_id)
            .where("type", "==", "pending_transaction")
            .limit(1)
            .stream()
        )
        for pa_doc in pending_alert_query:
            cat_label = category or ("Income" if tx_type == "income" else "Expense")
            pa_doc.reference.update({
                "type": tx_type,
                "category": category,
                "message": f"Rs {int(amount)} {cat_label} {tx_type} confirmed.",
                "isRead": True,
            })
            break
    except Exception as e:
        print(f"[CONFIRM] pending_transaction alert update failed (non-fatal): {e}")

    # ── 5c. Clear stale pendingAction so chat doesn't keep restoring this
    # transaction as still-pending after it's already been confirmed ─────
    try:
        pa_ref = db.collection("users").document(uid).collection("pendingAction").document("current")
        pa_doc = pa_ref.get()
        if pa_doc.exists and transaction_id in (pa_doc.to_dict().get("pendingTxIds") or []):
            pa_ref.delete()
    except Exception as e:
        print(f"[CONFIRM] pendingAction clear failed (non-fatal): {e}")

    # ── 6. Create assistant message so Chat UI shows the result ──────────
    try:
        messages_ref = db.collection("users").document(uid).collection("messages")
        cat_display = category or "Income"
        confirm_reply = f"OK, Rs {int(amount)} {cat_display} ma save gareko chu ✅"
        msg_ref = messages_ref.document()
        msg_ref.set({
            "role":                 "model",
            "parts":                [{"text": confirm_reply}],
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

    try:
        engine_recompute(db, uid, month_key, reason=RecomputeReason.TRANSACTION_CONFIRMED)
    except Exception as _re:
        print(f"[CONFIRM] Engine recompute failed (non-fatal): {_re}")

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
# POST /confirm-transactions   — bulk confirm OR cancel chat-pending transactions
#
# Body:
# {
#   "action": "confirm" | "cancel",
#   "transactions": [
#     { "id": "txn_id_1", "amount": 100, "category": "Food" },
#     { "id": "txn_id_2" }
#   ]
# }
#
# Returns per-item results.
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/confirm-transactions")
async def bulk_confirm_transactions(
    body: BulkConfirmBody,
    current_user: dict = Depends(get_current_user),
):
    """
    Bulk confirm or cancel a list of pending transactions.

    Use this for:
    - Confirming chat-parsed pending transactions (from /chat pendingTransactions list).
    - Cancelling pending transactions the user does not want to log.

    action = "confirm": sets status = "confirmed", increments budget.spent.
    action = "cancel":  sets status = "cancelled", does NOT touch budgets.
    """
    uid = current_user["uid"]
    db = get_firestore()

    action = (body.action or "confirm").strip().lower()
    if action not in ("confirm", "cancel"):
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "INVALID_ACTION",
                    "message": "action must be 'confirm' or 'cancel'.",
                },
            },
        )

    if not body.transactions:
        raise HTTPException(
            status_code=400,
            detail={
                "success": False,
                "error": {
                    "code": "EMPTY_LIST",
                    "message": "transactions list cannot be empty.",
                },
            },
        )

    print(f"[BULK_CONFIRM] uid={uid} action={action} count={len(body.transactions)}")

    results = []
    confirmed_month_keys = set()
    for item in body.transactions:
        tx_id = item.id
        try:
            tx_ref = (
                db.collection("users").document(uid)
                .collection("transactions").document(tx_id)
            )
            tx_doc = tx_ref.get()

            if not tx_doc.exists:
                results.append({
                    "id": tx_id,
                    "status": "error",
                    "reason": "Transaction not found.",
                })
                continue

            tx = tx_doc.to_dict()
            if tx.get("status") != "pending":
                results.append({
                    "id": tx_id,
                    "status": "skipped",
                    "reason": f"Transaction is already '{tx.get('status')}'.",
                })
                continue

            if action == "cancel":
                # ── Cancel: mark as cancelled, no budget changes ─────────
                tx_ref.update({
                    "status":    "cancelled",
                    "updatedAt": SERVER_TIMESTAMP,
                })
                # Update matching notification doc if any
                notif_docs = list(
                    db.collection("users").document(uid)
                    .collection("notifications")
                    .where("transactionId", "==", tx_id)
                    .limit(1)
                    .stream()
                )
                for nd in notif_docs:
                    nd.reference.update({"status": "cancelled"})

                results.append({
                    "id": tx_id,
                    "status": "cancelled",
                    "transaction": {
                        "id":       tx_id,
                        "status":   "cancelled",
                        "amount":   tx.get("amount"),
                        "category": tx.get("category"),
                    },
                })
                print(f"[BULK_CONFIRM] Cancelled tx={tx_id}")

            else:
                # ── Confirm: apply overrides then confirm ────────────────
                amount   = float(item.amount)   if item.amount   is not None else float(tx.get("amount", 0))
                category = item.category        if item.category is not None else tx.get("category")
                tx_type  = tx.get("type", "expense")
                month_key = tx.get("monthKey", get_current_month_key())
                confirmed_month_keys.add(month_key)

                # ENFORCE CATEGORY for notifications
                if tx.get("source") == "notification" and not category:
                    results.append({
                        "id": tx_id,
                        "status": "error",
                        "reason": "Category is required for notification transactions.",
                    })
                    continue

                update_payload: dict = {
                    "status":    "confirmed",
                    "updatedAt": SERVER_TIMESTAMP,
                }
                if item.amount is not None:
                    update_payload["amount"] = amount
                if item.category is not None:
                    update_payload["category"] = category
                tx_ref.update(update_payload)

                # Update matching notification
                notif_docs = list(
                    db.collection("users").document(uid)
                    .collection("notifications")
                    .where("transactionId", "==", tx_id)
                    .limit(1)
                    .stream()
                )
                for nd in notif_docs:
                    notif_upd: dict = {"status": "confirmed"}
                    if item.category is not None:
                        notif_upd["parsedCategory"] = category
                    if item.amount is not None:
                        notif_upd["parsedAmount"] = amount
                    nd.reference.update(notif_upd)

                # Budget increment (expenses only)
                budget_update = None
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
                        new_spent    = updated_budget.get("spent", 0.0)
                        blimit       = updated_budget.get("limit", 0.0)
                        remaining    = max(0.0, blimit - new_spent)
                        percent_used = round((new_spent / blimit) * 100, 2) if blimit > 0 else 0.0
                        budget_update = {
                            "id":          matching[0].id,
                            "category":    category,
                            "limit":       blimit,
                            "spent":       new_spent,
                            "remaining":   remaining,
                            "percentUsed": percent_used,
                            "monthKey":    month_key,
                        }

                results.append({
                    "id": tx_id,
                    "status": "confirmed",
                    "transaction": {
                        "id":       tx_id,
                        "amount":   amount,
                        "category": category,
                        "type":     tx_type,
                        "status":   "confirmed",
                        "monthKey": month_key,
                    },
                    "budgetUpdate": budget_update,
                })
                print(f"[BULK_CONFIRM] Confirmed tx={tx_id} Rs {amount} {category}")

        except Exception as e:
            print(f"[BULK_CONFIRM] Error tx={tx_id}: {e}")
            results.append({
                "id": tx_id,
                "status": "error",
                "reason": str(e),
            })

    total_confirmed = sum(1 for r in results if r.get("status") == "confirmed")
    total_cancelled = sum(1 for r in results if r.get("status") == "cancelled")
    total_errors    = sum(1 for r in results if r.get("status") == "error")

    # One recompute per month actually touched by a confirm — not per item,
    # and not at all if nothing in this batch became financially real.
    for mk in confirmed_month_keys:
        try:
            engine_recompute(db, uid, mk, reason=RecomputeReason.TRANSACTION_CONFIRMED)
        except Exception as _re:
            print(f"[BULK_CONFIRM] Engine recompute failed for month={mk} (non-fatal): {_re}")

    return {
        "success": True,
        "data": {
            "results":        results,
            "totalConfirmed": total_confirmed,
            "totalCancelled": total_cancelled,
            "totalErrors":    total_errors,
        },
    }


# ═══════════════════════════════════════════════════════════════════════════════
# POST /confirm-rebalance/{rebalanceId}
# Confirms taking budget from other categories (or savings) to cover an
# overspend. Only now are the actual budget-limit writes applied.
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/confirm-rebalance/{rebalance_id}")
async def confirm_rebalance(
    rebalance_id: str,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    result = apply_pending_rebalance(db, uid, rebalance_id)
    if result is None:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "REBALANCE_NOT_FOUND",
                    "message": "Pending rebalance not found or already resolved.",
                },
            },
        )

    return {
        "success": True,
        "message": "Budget adjusted.",
        "data": result,
    }


# ═══════════════════════════════════════════════════════════════════════════════
# POST /reject-rebalance/{rebalanceId}
# Declines taking budget from other categories. No budget-limit changes are
# made anywhere — the overspent category simply stays over its limit.
# ═══════════════════════════════════════════════════════════════════════════════

@router.post("/reject-rebalance/{rebalance_id}")
async def reject_rebalance(
    rebalance_id: str,
    current_user: dict = Depends(get_current_user),
):
    uid = current_user["uid"]
    db = get_firestore()

    result = reject_pending_rebalance(db, uid, rebalance_id)
    if result is None:
        raise HTTPException(
            status_code=404,
            detail={
                "success": False,
                "error": {
                    "code": "REBALANCE_NOT_FOUND",
                    "message": "Pending rebalance not found or already resolved.",
                },
            },
        )

    return {
        "success": True,
        "message": "No budget was moved.",
        "data": result,
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
        # Already resolved elsewhere — clean up the stale alert instead of
        # erroring, same reasoning as confirm_transaction above.
        existing_status = tx.get("status")
        _cleanup_stale_pending_alert(
            db, uid, transaction_id,
            f"This transaction was already {existing_status}.",
        )
        return {
            "success": True,
            "message": f"Already {existing_status} — nothing to do.",
            "data": {
                "transaction": {
                    "id": transaction_id,
                    "status": existing_status,
                },
                "budgetUpdate": None,
                "alerts": [],
                "alreadyResolved": True,
            },
        }

    # ── 2. Cancel transaction ────────────────────────────────────────────
    tx_ref.update({
        "status":    "cancelled",
        "updatedAt": SERVER_TIMESTAMP,
    })
    print(f"[REJECT] Transaction {transaction_id} marked cancelled")

    # ── 3. Update matching notification ─────────────────────────────────
    notif_query = (
        db.collection("users").document(uid)
        .collection("notifications")
        .where("transactionId", "==", transaction_id)
        .limit(1)
        .stream()
    )
    for notif_doc in notif_query:
        notif_doc.reference.update({"status": "cancelled"})
        print(f"[REJECT] Notification {notif_doc.id} marked cancelled")
        break

    # ── 4. No budget changes on cancellation ──────────────────────────────

    amount   = float(tx.get("amount", 0))
    category = tx.get("category", "")
    source_app = tx.get("description", "").split(":")[0] if ":" in tx.get("description", "") else "Notification"

    # ── 4b. Update the original "pending_transaction" alert in place —
    # same reason as confirm: otherwise it stays stuck and tappable forever.
    try:
        pending_alert_query = (
            db.collection("users").document(uid).collection("alerts")
            .where("relatedTransactionId", "==", transaction_id)
            .where("type", "==", "pending_transaction")
            .limit(1)
            .stream()
        )
        for pa_doc in pending_alert_query:
            pa_doc.reference.update({
                "message": f"Rs {int(amount)} transaction from {source_app} discarded.",
                "isRead": True,
                "isDeleted": True,
            })
            break
    except Exception as e:
        print(f"[REJECT] pending_transaction alert update failed (non-fatal): {e}")

    # ── 4c. Clear stale pendingAction ─────────────────────────────────────
    try:
        pa_ref = db.collection("users").document(uid).collection("pendingAction").document("current")
        pa_doc2 = pa_ref.get()
        if pa_doc2.exists and transaction_id in (pa_doc2.to_dict().get("pendingTxIds") or []):
            pa_ref.delete()
    except Exception as e:
        print(f"[REJECT] pendingAction clear failed (non-fatal): {e}")

    # ── 5. Create assistant message so Chat UI shows the cancellation ─────
    try:
        messages_ref = db.collection("users").document(uid).collection("messages")
        reject_reply = f"OK, {source_app} Rs {int(amount)} {category} transaction ignore gareko chu."
        msg_ref = messages_ref.document()
        msg_ref.set({
            "role":                 "model",
            "parts":                [{"text": reject_reply}],
            "content":              reject_reply,
            "intent":               "notification_cancelled",
            "extractedData":        None,
            "relatedTransactionId": transaction_id,
            "createdAt":            SERVER_TIMESTAMP,
        })
        print(f"[REJECT] Assistant message created: {msg_ref.id}")
    except Exception as e:
        print(f"[REJECT] Assistant message FAILED: {e}")

    return {
        "success": True,
        "message": "Transaction cancelled.",
        "data": {
            "transaction": {
                "id":       transaction_id,
                "amount":   amount,
                "category": category,
                "type":     tx.get("type"),
                "status":   "cancelled",
                "source":   tx.get("source"),
                "monthKey": tx.get("monthKey"),
            },
            "budgetUpdate": None,
            "alerts":       [],
        },
    }