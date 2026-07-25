"""
Patch routes/chat.py:
1. Add _build_financial_context() helper function after _chat_context_facts()
2. Add _build_visual_payload() helper function after _build_financial_context()
3. Call _build_financial_context() before the AI call and pass to process_chat_message
4. Extract visual_type from AI actions and build visual payload
5. Attach visual to the response
6. Fix query_budget_status to handle no-category case (all budgets)
"""

with open(r'backend\routes\chat.py', 'r', encoding='utf-8') as f:
    content = f.read()

# ─── 1. Insert helper functions after _chat_context_facts() ──────────────────

NEW_HELPERS = '''

def _build_financial_context(db, uid: str, month_key: str) -> dict:
    """
    Builds the rich FinancialContext dict that is injected into the AI system
    prompt every turn. All figures come from the Engine summary — never
    independently re-calculated here (Ground Truth Principle).
    """
    from services.financial_engine import get_summary
    import calendar
    from datetime import date, datetime

    ctx = {}
    try:
        summary = get_summary(db, uid, month_key)
        category_remaining = summary.get("categoryRemaining") or {}

        # Budget rows — sorted by percent used descending (tightest first)
        budgets = []
        for cat, data in category_remaining.items():
            limit = data.get("limit", 0)
            spent = data.get("spent", 0)
            remaining = data.get("remaining", max(0, limit - spent))
            pct = round((spent / limit * 100), 1) if limit > 0 else 0.0
            budgets.append({
                "category": cat,
                "limit": limit,
                "spent": spent,
                "remaining": remaining,
                "percentUsed": pct,
            })
        budgets.sort(key=lambda b: -b["percentUsed"])

        # Income breakdown
        profile = db.collection("users").document(uid).get().to_dict() or {}
        income_map = profile.get("income", {}) or {}
        in_hand = float(income_map.get("inHand", 0))
        in_bank = float(income_map.get("inBank", 0))
        online = float(income_map.get("onlineBanking", 0))
        total_income = in_hand + in_bank + online

        # Unallocated = total income - sum of all budget limits
        total_budget_limits = sum(b["limit"] for b in budgets)
        unallocated = max(0, total_income - total_budget_limits)

        # Days remaining in month
        today = date.today()
        y, m = int(month_key[:4]), int(month_key[5:7])
        last_day = calendar.monthrange(y, m)[1]
        month_end = date(y, m, last_day)
        days_remaining = max(0, (month_end - today).days + 1)

        # Remaining total budget across all categories
        total_remaining_budget = sum(b["remaining"] for b in budgets)
        daily_spend = round(total_remaining_budget / days_remaining, 0) if days_remaining > 0 else 0

        ctx = {
            "monthKey": month_key,
            "totalIncome": total_income,
            "inHand": in_hand,
            "inBank": in_bank,
            "onlineBanking": online,
            "totalSpent": summary.get("totalSpent", 0),
            "unallocated": unallocated,
            "totalBudgetLimits": total_budget_limits,
            "totalRemainingBudget": total_remaining_budget,
            "daysRemaining": days_remaining,
            "recommendedDailySpend": daily_spend,
            "budgets": budgets,
        }
    except Exception as e:
        print(f"[CHAT] _build_financial_context failed (non-critical): {e}")
    return ctx


def _build_visual_payload(visual_type: str | None, financial_context: dict, month_key: str) -> dict | None:
    """
    Builds the structured visual payload that Flutter renders as a rich card.
    The backend — not Gemini — owns this data so it's always accurate.
    Returns None if no visual is needed.
    """
    if not visual_type or not financial_context:
        return None

    fc = financial_context

    if visual_type == "budget_summary":
        budgets = fc.get("budgets", [])
        # Find tightest category
        insight = None
        if budgets:
            tightest = budgets[0]  # already sorted by % desc
            pct = tightest.get("percentUsed", 0)
            cat = tightest.get("category", "")
            remaining = int(tightest.get("remaining", 0))
            if pct >= 90:
                insight = f"⚠️ {cat} is critically low — Rs {remaining} remaining."
            elif pct >= 75:
                insight = f"⚠️ {cat} is running low at {pct}%."
            else:
                insight = None
        return {
            "type": "budget_summary",
            "budgets": budgets,
            "totalSpent": int(fc.get("totalSpent", 0)),
            "totalIncome": int(fc.get("totalIncome", 0)),
            "unallocated": int(fc.get("unallocated", 0)),
            "daysRemaining": fc.get("daysRemaining", 0),
            "monthKey": fc.get("monthKey", month_key),
            "insight": insight,
        }

    if visual_type == "daily_spend":
        budgets = fc.get("budgets", [])
        tightest = budgets[0] if budgets else {}
        return {
            "type": "daily_spend",
            "recommendedDailySpend": int(fc.get("recommendedDailySpend", 0)),
            "daysRemaining": fc.get("daysRemaining", 0),
            "totalRemainingBudget": int(fc.get("totalRemainingBudget", 0)),
            "tightestCategory": tightest.get("category"),
            "tightestRemaining": int(tightest.get("remaining", 0)),
            "monthKey": fc.get("monthKey", month_key),
        }

    if visual_type == "spending_chart":
        budgets = fc.get("budgets", [])
        # Chart data: only categories with actual spending
        chart_data = [
            {"category": b["category"], "spent": int(b["spent"]), "percentUsed": b["percentUsed"]}
            for b in budgets if b.get("spent", 0) > 0
        ]
        chart_data.sort(key=lambda x: -x["spent"])
        biggest = chart_data[0] if chart_data else {}
        return {
            "type": "spending_chart",
            "data": chart_data,
            "totalSpent": int(fc.get("totalSpent", 0)),
            "biggestCategory": biggest.get("category"),
            "biggestAmount": biggest.get("spent", 0),
            "monthKey": fc.get("monthKey", month_key),
        }

    if visual_type == "budget_alert":
        return {
            "type": "budget_alert",
            "unallocated": int(fc.get("unallocated", 0)),
            "totalIncome": int(fc.get("totalIncome", 0)),
            "monthKey": fc.get("monthKey", month_key),
        }

    return None

'''

# Insert after the _chat_context_facts function closing
ANCHOR = "    return top_risk_category, at_risk_goal\n\n\n# \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n# Helpers \u2014 one function per action type"
REPLACEMENT = "    return top_risk_category, at_risk_goal\n" + NEW_HELPERS + "\n# \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n# Helpers \u2014 one function per action type"

if ANCHOR in content:
    content = content.replace(ANCHOR, REPLACEMENT, 1)
    print("Step 1 done: helper functions inserted")
else:
    print("Step 1 FAILED: could not find anchor")

# ─── 2. Build financial_context before the AI call and pass it ───────────────
OLD_CONTEXT_FETCH = """    # Chat Context v2 (Phase 20) — same best-effort treatment as HealthStatus
    # above: a failure here falls back to no extra facts, never blocks chat.
    top_risk_category, at_risk_goal = _chat_context_facts(db, uid, curr_month)

    # ── Call Gemini ──────────────────────────────────────────────────────
    try:
        gemini_result = await process_chat_message(
            user_message,
            first_name=first_name,
            is_first_message=is_first_message,
            missing_budget_categories=missing_budget_categories,
            history=history,
            overall_health_status=overall_health_status,
            top_risk_category=top_risk_category,
            at_risk_goal=at_risk_goal,
        )"""

NEW_CONTEXT_FETCH = """    # Chat Context v2 (Phase 20) — same best-effort treatment as HealthStatus
    # above: a failure here falls back to no extra facts, never blocks chat.
    top_risk_category, at_risk_goal = _chat_context_facts(db, uid, curr_month)

    # Rich FinancialContext — all real budget/income/daily-spend data for AI
    financial_context = _build_financial_context(db, uid, curr_month)

    # ── Call Gemini ──────────────────────────────────────────────────────
    try:
        gemini_result = await process_chat_message(
            user_message,
            first_name=first_name,
            is_first_message=is_first_message,
            missing_budget_categories=missing_budget_categories,
            history=history,
            overall_health_status=overall_health_status,
            top_risk_category=top_risk_category,
            at_risk_goal=at_risk_goal,
            financial_context=financial_context,
        )"""

if OLD_CONTEXT_FETCH in content:
    content = content.replace(OLD_CONTEXT_FETCH, NEW_CONTEXT_FETCH, 1)
    print("Step 2 done: financial_context build + pass added")
else:
    print("Step 2 FAILED: could not find context fetch block")

# ─── 3. Extract visual_type from actions and build visual payload ─────────────
# Find the line after actions are parsed: "print(f"[CHAT] uid={uid} actions=..."
# Insert the visual extraction there

OLD_ACTIONS_PRINT = '    print(f"[CHAT] uid={uid} actions={[a.get(\'intent\') for a in actions]}")\n\n    # ── Rent category fallback'
NEW_ACTIONS_PRINT = '    print(f"[CHAT] uid={uid} actions={[a.get(\'intent\') for a in actions]}")\n\n    # ── Extract visual_type from AI actions ─────────────────────────────\n    # The AI sets visual_type in the DATA block to signal which rich card\n    # Flutter should render. Backend then builds the actual structured data.\n    _visual_type = None\n    for _a in actions:\n        _vt = _a.get("visual_type")\n        if _vt:\n            _visual_type = _vt\n            break\n    _visual_payload = _build_visual_payload(_visual_type, financial_context, month_key)\n\n    # ── Rent category fallback'

if OLD_ACTIONS_PRINT in content:
    content = content.replace(OLD_ACTIONS_PRINT, NEW_ACTIONS_PRINT, 1)
    print("Step 3 done: visual extraction inserted")
else:
    print("Step 3 FAILED: could not find actions print line")

# ─── 4. Fix query_budget_status to handle no-category case ───────────────────
OLD_BUDGET_STATUS = '''        elif intent == "query_budget_status" and action.get("category"):
            cat = action["category"]
            b = (get_summary(db, uid, month_key).get("categoryRemaining", {}) or {}).get(cat)
            if b:
                bl = b.get("limit", 0)
                bs = b.get("spent", 0)
                br = b.get("remaining", max(0, bl - bs))
                bp = round((bs / bl * 100), 1) if bl > 0 else 0
                reply_parts.append(f"{cat} budget Rs {int(bl)}, spent Rs {int(bs)}, baki Rs {int(br)} ({bp}%)")
            else:
                reply_parts.append(f"{cat} ko lagi budget set gareko chaina yo mahina")
            print(f"[CHAT] query_budget_status: {cat}")'''

NEW_BUDGET_STATUS = '''        elif intent == "query_budget_status":
            cat = action.get("category")
            if cat:
                # Single category budget status
                b = (get_summary(db, uid, month_key).get("categoryRemaining", {}) or {}).get(cat)
                if b:
                    bl = b.get("limit", 0)
                    bs = b.get("spent", 0)
                    br = b.get("remaining", max(0, bl - bs))
                    bp = round((bs / bl * 100), 1) if bl > 0 else 0
                    reply_parts.append(f"{cat} budget Rs {int(bl)}, spent Rs {int(bs)}, baki Rs {int(br)} ({bp}%)")
                else:
                    reply_parts.append(f"{cat} ko lagi budget set gareko chaina yo mahina")
                print(f"[CHAT] query_budget_status: {cat}")
            else:
                # All budgets — visual card handles the full table display
                # The reply_parts text is kept minimal; Flutter shows the card
                budgets_fc = financial_context.get("budgets", []) if financial_context else []
                if budgets_fc:
                    reply_parts.append("Yo mahina ko budget:")
                else:
                    reply_parts.append("Yo mahina ko lagi kuni pani budget set gareko chaina.")
                print("[CHAT] query_budget_status: all categories")'''

if OLD_BUDGET_STATUS in content:
    content = content.replace(OLD_BUDGET_STATUS, NEW_BUDGET_STATUS, 1)
    print("Step 4 done: query_budget_status fixed for all-categories case")
else:
    print("Step 4 FAILED: could not find query_budget_status block")

# ─── 5. Add visual to the final return dict ───────────────────────────────────
# The main return near end of the chat handler looks like:
OLD_RETURN = '''        return {
            "success": True,
            "data": {
                "reply": final_reply,
                "intent": reply_intent,
                "needsConfirmation": False,
                "transaction": last_transaction,
                "budgetUpdate": last_budget_update,
                "alerts": alerts_created,
            },
        }'''

NEW_RETURN = '''        return {
            "success": True,
            "data": {
                "reply": final_reply,
                "intent": reply_intent,
                "needsConfirmation": False,
                "transaction": last_transaction,
                "budgetUpdate": last_budget_update,
                "alerts": alerts_created,
                "visual": _visual_payload,
            },
        }'''

count = content.count(OLD_RETURN)
if count > 0:
    content = content.replace(OLD_RETURN, NEW_RETURN)
    print(f"Step 5 done: visual added to {count} return(s)")
else:
    print("Step 5 FAILED: could not find final return dict")

with open(r'backend\routes\chat.py', 'w', encoding='utf-8') as f:
    f.write(content)

print("\nAll done — chat.py patched successfully")
