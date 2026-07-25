"""
test_notification_generator.py
================================
Phase 5.6B acceptance scenarios for the Notification Generator — see
FINANCIAL_ENGINE_SPEC.md's "Phase 5.6B — Notification Generator
Pipeline" and "Rule 8 — Generator Fails Fast." Pure logic tests — no
Firestore, no other engines; the Generator only looks up static tables
and assembles an object.

Run directly: python tests/test_notification_generator.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import notification_generator as gen

FAILURES = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(f"{label} — {detail}")


def run():
    print("Notification Generator — test matrix")

    # 1. A simple event with no payload placeholders assembles correctly
    event1 = {"eventId": "u1:2026-07-19:health_worsened", "event": "HEALTH_WORSENED", "payload": {"from": "green", "to": "amber"}}
    n1 = gen.generate_notification(event1)
    check(
        "HEALTH_WORSENED assembles with correct priority/frequency/timing/template",
        n1["priority"] == "High" and n1["frequency"] == "DAILY" and n1["timing"] == "IMMEDIATE"
        and n1["templateId"] == "TITLE_HEALTH_WORSENED",
        f"got {n1}",
    )
    check(
        "Title and body are fully resolved human text, not template IDs",
        n1["title"] == "Spending pace increased" and "spending faster" in n1["body"],
        f"got {n1}",
    )
    check(
        "status is 'Created' (the real Lifecycle's first state), not an invented 'Pending'",
        n1["status"] == "Created",
        f"got {n1['status']}",
    )
    check(
        "payload is preserved unchanged on the notification (Rule 7)",
        n1["payload"] == event1["payload"],
        f"got {n1['payload']}",
    )

    # 2. A payload-driven template correctly interpolates using the REAL
    # payload shape ({from}/{to}), not the original illustrative {n}.
    event2 = {"eventId": "u1:2026-07-19:logging_streak_extended", "event": "LOGGING_STREAK_EXTENDED", "payload": {"from": 6, "to": 7}}
    n2 = gen.generate_notification(event2)
    check(
        "LOGGING_STREAK_EXTENDED's title interpolates the real {to} payload key correctly",
        n2["title"] == "7-day logging streak",
        f"got {n2['title']}",
    )
    check(
        "LOGGING_STREAK_EXTENDED uses Low priority and WEEKLY frequency, per the frozen matrices",
        n2["priority"] == "Low" and n2["frequency"] == "WEEKLY" and n2["timing"] == "NIGHT",
        f"got {n2}",
    )

    # 3. CATEGORY_BECAME_EXHAUSTED (one of the rows found missing during
    # the Rule 3 audit) interpolates {category} correctly across title/body/cta
    event3 = {"eventId": "u1:2026-07-19:category_became_exhausted:Food", "event": "CATEGORY_BECAME_EXHAUSTED", "payload": {"category": "Food"}}
    n3 = gen.generate_notification(event3)
    check(
        "CATEGORY_BECAME_EXHAUSTED interpolates {category} in title, body, and cta",
        n3["title"] == "Food budget exhausted" and "Food budget" in n3["body"] and n3["cta"] == "Review Food spending",
        f"got {n3}",
    )
    check(
        "CATEGORY_BECAME_EXHAUSTED has the Frequency/Timing rows added during the Rule 3 audit",
        n3["frequency"] == "DAILY" and n3["timing"] == "IMMEDIATE",
        f"got {n3}",
    )

    # 4. RECOVERY_FAILED (the other row found missing) resolves correctly
    event4 = {"eventId": "u1:2026-07-19:recovery_failed", "event": "RECOVERY_FAILED", "payload": {}}
    n4 = gen.generate_notification(event4)
    check(
        "RECOVERY_FAILED resolves with its Timing/Template rows added during the Rule 3 audit",
        n4["timing"] == "IMMEDIATE" and n4["templateId"] == "TITLE_RECOVERY_FAILED",
        f"got {n4}",
    )

    # 5. MILESTONE_UNLOCKED uses the per-milestone-code nested template
    event5 = {"eventId": "u1:2026-07-19:milestone_unlocked:FIRST_HEALTHY_WEEK", "event": "MILESTONE_UNLOCKED", "payload": {"code": "FIRST_HEALTHY_WEEK"}}
    n5 = gen.generate_notification(event5)
    check(
        "MILESTONE_UNLOCKED resolves the per-code template, not a generic one",
        n5["title"] == "First Healthy Week unlocked!" and n5["templateId"] == "TITLE_MILESTONE_FIRST_HEALTHY_WEEK",
        f"got {n5}",
    )
    check(
        "A different milestone code resolves a genuinely different template",
        gen.generate_notification({"event": "MILESTONE_UNLOCKED", "payload": {"code": "FIRST_GOAL_COMPLETED"}})["title"] == "First goal completed!",
    )

    # 6. Rule 8 — an unknown milestone code fails explicitly, never a generic fallback
    try:
        gen.generate_notification({"event": "MILESTONE_UNLOCKED", "payload": {"code": "NOT_A_REAL_MILESTONE"}})
        check("An unknown milestone code raises NotificationGeneratorError", False, "did not raise")
    except gen.NotificationGeneratorError:
        check("An unknown milestone code raises NotificationGeneratorError", True)

    # 7. Rule 8 — a completely unknown event code fails explicitly
    try:
        gen.generate_notification({"event": "SOME_EVENT_THAT_DOES_NOT_EXIST", "payload": {}})
        check("An unknown event code raises NotificationGeneratorError", False, "did not raise")
    except gen.NotificationGeneratorError:
        check("An unknown event code raises NotificationGeneratorError", True)

    # 8. Rule 8 — a missing 'event' key fails explicitly
    try:
        gen.generate_notification({"payload": {}})
        check("A missing 'event' key raises NotificationGeneratorError", False, "did not raise")
    except gen.NotificationGeneratorError:
        check("A missing 'event' key raises NotificationGeneratorError", True)

    # 9. Rule 8 — a payload missing a key the template needs fails
    # explicitly, never silently rendering "{category}" literally
    try:
        gen.generate_notification({"event": "CATEGORY_BECAME_EXHAUSTED", "payload": {}})
        check("A payload missing a required template key raises NotificationGeneratorError", False, "did not raise")
    except gen.NotificationGeneratorError:
        check("A payload missing a required template key raises NotificationGeneratorError", True)

    # 10. Determinism (Rule 4) — same input, same output, every time
    n1_again = gen.generate_notification(event1)
    check(
        "Calling generate_notification twice with the same event produces identical output",
        n1 == n1_again,
        f"got two different results",
    )

    # 11. Output shape — exactly the frozen keys, nothing more
    check(
        "Output has exactly the frozen keys, no delivery metadata (deliveredAt/readAt/etc.)",
        set(n1.keys()) == {
            "eventId", "eventCode", "priority", "frequency", "timing",
            "interruptionLevel", "deepLink", "templateId", "title", "body",
            "cta", "payload", "status",
        },
        f"got {list(n1.keys())}",
    )
    check(
        "interruptionLevel is present but honestly None (Context gate not implemented) -- deepLink is now real",
        n1["interruptionLevel"] is None and n1["deepLink"] == "health",
        f"got {n1['interruptionLevel']}, {n1['deepLink']}",
    )

    # 12. Deep Link Matrix -- every real event code resolves to one of
    # the three known frontend destinations, never None/missing
    n12 = gen.generate_notification({"eventId": "x", "event": "MILESTONE_UNLOCKED", "payload": {"code": "FIRST_EXPENSE_LOGGED"}})
    check(
        "MILESTONE_UNLOCKED resolves to the 'streak' deep link regardless of milestone code",
        n12["deepLink"] == "streak",
        f"got {n12['deepLink']}",
    )
    n13 = gen.generate_notification({"eventId": "y", "event": "CATEGORY_BECAME_EXHAUSTED", "payload": {"category": "Food"}})
    check(
        "CATEGORY_BECAME_EXHAUSTED resolves to 'category_detail', not the generic 'health' bucket",
        n13["deepLink"] == "category_detail",
        f"got {n13['deepLink']}",
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("All Notification Generator scenarios passed.")


if __name__ == "__main__":
    run()
