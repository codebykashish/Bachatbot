"""
test_weekly_composition.py
=============================
Phase 22D acceptance scenarios for Weekly Reflection Composition — see
FINANCIAL_ENGINE_SPEC.md's "Phase 22D — Weekly Reflection Composition."
compose_weekly_reflection() is a pure function (no Firestore) -- every
scenario here is a plain synthetic interpretation + observation dict.

Run directly: python tests/test_weekly_composition.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import weekly_reflection_service as wrs

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def empty_interpretation(**overrides):
    interp = {"highlights": [], "concerns": [], "pattern": None, "goalContext": None, "nextStep": None}
    interp.update(overrides)
    return interp


def base_observation(**overrides):
    obs = {"weekStart": "2026-07-20", "weekEnd": "2026-07-26", "recommendation": {}}
    obs.update(overrides)
    return obs


def run():
    print("Weekly Composition — test matrix")

    # 1. Opening selection: highlights only -> positive opening
    interp = empty_interpretation(highlights=[{"type": "MEANINGFUL_STREAK", "streakType": "loggingStreak", "value": 3}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "Highlights present, no concerns -> positive opening",
        result["opening"] == "You made some good progress this week.",
        f"got {result['opening']}",
    )

    # 2. Opening selection: nothing at all -> neutral quiet-week opening
    result = wrs.compose_weekly_reflection(empty_interpretation(), base_observation())
    check(
        "Nothing to report -> neutral quiet-week opening",
        result["opening"] == "Here's a look at how your money week went.",
        f"got {result['opening']}",
    )

    # 3. Opening selection: any concern present -> observational opening, never alarming
    interp = empty_interpretation(concerns=[{"type": "LOW_ACTIVITY"}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "Concerns present -> observational opening, not a positive one",
        result["opening"] == "Here's what stood out about your money this week.",
        f"got {result['opening']}",
    )

    # 4. Highlight wording: MEANINGFUL_STREAK
    interp = empty_interpretation(highlights=[{"type": "MEANINGFUL_STREAK", "streakType": "loggingStreak", "value": 3}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "MEANINGFUL_STREAK composes with the human streak label and count",
        result["highlights"][0]["text"] == "You kept your logging streak going for 3 days.",
        f"got {result['highlights']}",
    )

    # 5. Highlight wording: CATEGORY_WITHIN_BUDGET
    interp = empty_interpretation(highlights=[{"type": "CATEGORY_WITHIN_BUDGET", "category": "Transport", "spent": 700, "limit": 2910}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "CATEGORY_WITHIN_BUDGET composes without stating raw numbers (per tone principle -- fact is enough)",
        result["highlights"][0]["text"] == "Your Transport spending stayed comfortably within budget.",
        f"got {result['highlights']}",
    )

    # 6. Concern wording: CATEGORY_HIGH_USAGE at exactly 100% -> "full budget" phrasing, never judgmental
    interp = empty_interpretation(concerns=[{"type": "CATEGORY_HIGH_USAGE", "category": "Shopping", "spent": 2590, "limit": 2590}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "100% usage composes as 'used its full budget', never 'overspent'",
        "full budget" in result["concerns"][0]["text"] and "overspent" not in result["concerns"][0]["text"].lower(),
        f"got {result['concerns']}",
    )

    # 7. Concern wording: CATEGORY_HIGH_USAGE below 100% -> percent phrasing
    interp = empty_interpretation(concerns=[{"type": "CATEGORY_HIGH_USAGE", "category": "Food", "spent": 5280, "limit": 6600}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "85% usage composes with the actual percentage, not 'full budget'",
        "80%" in result["concerns"][0]["text"],
        f"got {result['concerns']}",
    )

    # 8. Concern wording: LOW_ACTIVITY is gentle, never blaming
    interp = empty_interpretation(concerns=[{"type": "LOW_ACTIVITY"}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "LOW_ACTIVITY never says 'failed' or 'didn't track'",
        "fail" not in result["concerns"][0]["text"].lower(),
        f"got {result['concerns']}",
    )

    # 9. Health wording uses human labels, not raw status strings
    interp = empty_interpretation(concerns=[{"type": "HEALTH_WORSENED", "from": "green", "to": "amber"}])
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "HEALTH_WORSENED uses human labels (healthy/watch), not raw green/amber",
        "healthy" in result["concerns"][0]["text"] and "watch" in result["concerns"][0]["text"],
        f"got {result['concerns']}",
    )

    # 10. Pattern composition
    interp = empty_interpretation(pattern={"type": "UNUSUAL_SPENDING", "category": "Shopping", "createdAt": None})
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "Pattern composes naming the category and 'unusually high'",
        result["pattern"]["text"] == "Your Shopping spending was unusually high compared with your recent pattern.",
        f"got {result['pattern']}",
    )

    # 11. Goal context: at-risk, real shortfall, capitalized name
    interp = empty_interpretation(goalContext={"type": "GOAL_AT_RISK", "goalId": "g1", "goalName": "laptop", "shortfall": 12000})
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "GOAL_AT_RISK composes with capitalized goal name and real shortfall, current-state phrasing",
        result["goalContext"]["text"] == "You're currently Rs 12000 short of your Laptop goal.",
        f"got {result['goalContext']}",
    )
    check(
        "GOAL_AT_RISK never implies this week caused the shortfall",
        "this week" not in result["goalContext"]["text"].lower(),
        f"got {result['goalContext']}",
    )

    # 12. Goal context: on track
    interp = empty_interpretation(goalContext={"type": "GOAL_ON_TRACK", "goalId": "g2", "goalName": "emergency fund"})
    result = wrs.compose_weekly_reflection(interp, base_observation())
    check(
        "GOAL_ON_TRACK composes as currently-on-track, capitalized name",
        result["goalContext"]["text"] == "You're currently on track toward your Emergency fund goal.",
        f"got {result['goalContext']}",
    )

    # 13. Next step: category-based recommendation pulls category from OBSERVATION, not interpretation
    interp = empty_interpretation(nextStep={"recommendationCode": "REDUCE_CATEGORY_SPENDING"})
    obs = base_observation(recommendation={"code": "REDUCE_CATEGORY_SPENDING", "category": "Food", "goalName": None})
    result = wrs.compose_weekly_reflection(interp, obs)
    check(
        "Next step reads category from observation's recommendation, not from the interpretation object",
        result["nextStep"]["text"] == "Consider easing up on Food spending.",
        f"got {result['nextStep']}",
    )

    # 14. Next step: goal-based recommendation pulls goalName from observation
    interp = empty_interpretation(nextStep={"recommendationCode": "INCREASE_GOAL_CONTRIBUTION"})
    obs = base_observation(recommendation={"code": "INCREASE_GOAL_CONTRIBUTION", "category": None, "goalName": "laptop"})
    result = wrs.compose_weekly_reflection(interp, obs)
    check(
        "Next step reads goalName from observation and capitalizes it",
        result["nextStep"]["text"] == "Consider increasing your contribution toward your Laptop goal.",
        f"got {result['nextStep']}",
    )

    # 15. Section visibility: nothing selected -> pattern/goalContext/nextStep are all None, never placeholders
    result = wrs.compose_weekly_reflection(empty_interpretation(), base_observation())
    check(
        "Empty interpretation -> highlights/concerns are empty lists, pattern/goalContext/nextStep are None",
        result["highlights"] == [] and result["concerns"] == []
        and result["pattern"] is None and result["goalContext"] is None and result["nextStep"] is None,
        f"got {result}",
    )

    # 16. weekStart/weekEnd pass through from observation
    result = wrs.compose_weekly_reflection(empty_interpretation(), base_observation())
    check(
        "weekStart/weekEnd pass through from the observation unchanged",
        result["weekStart"] == "2026-07-20" and result["weekEnd"] == "2026-07-26",
        f"got weekStart={result['weekStart']} weekEnd={result['weekEnd']}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Weekly Composition scenarios passed.")


if __name__ == "__main__":
    run()
