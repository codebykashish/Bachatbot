# Financial Engine Specification

This is the "constitution" of BachatBot's money logic. It exists so that
every future feature is checked against a written rule instead of being
reimplemented from scratch in a new file with a slightly different formula
(which is how the app ended up with two different "savings priority"
implementations — one in `budget_service.py`, one in `routes/budgets.py` —
before this spec existed).

**Product philosophy (governs every phase, not just the Engine):**

> BachatBot never tells the user what they must do. It explains the
> current financial situation, recommends actions based on available
> evidence, and leaves the final decision to the user.

This is why the pipeline is a chain of interpretation, not control, and
why no stage downstream of the Engine is allowed to act on the user's
behalf:

```
Financial Engine        computes facts
Metrics Engine           interprets those facts
Health Engine            summarizes risk
Recommendation Engine    offers options
Notification Engine      decides when it's worth interrupting the user
Chatbot                  explains the reasoning in plain language
```

None of them take control away from the user. A feature that silently
acts on the user's money (auto-adjusting a budget, auto-reallocating a
goal, skipping confirmation before moving funds) is out of scope for this
architecture regardless of how well-intentioned it is — see "Metrics never
modify money" under Phase 2.0 below, which is this same principle applied
specifically to the Metrics Engine.

**The Financial Engine is the only component in the system allowed to make
financial decisions.** Every other component — UI, chatbot, reports,
notifications, analytics — consumes its outputs but never implements
financial logic itself.

**The Financial Engine is the only code allowed to read raw financial data
(income, budgets, transactions, goals) and turn it into calculated values.**
Every other part of the app — chatbot, Reports, Home, notifications, UI
colors — reads calculated values from the Engine's summary document. Nothing
downstream recalculates.

### Financial Truth Flow

```
User Action
    │
    ▼
Raw Data Stored          (income, budgets, transactions, goals)
    │
    ▼
Financial Engine         (recompute)
    │
    ▼
Financial Summary
    │
    ▼
Everything Else          (Home, Reports, Goals, Chat, Notifications,
                           Health, Recommendations)
```

One diagram, the whole architecture: nothing downstream of Financial
Summary is allowed to reach back up past it. A chatbot reply, a report
card, and a health color are three different *presentations* of the same
single flow — not three separate calculations that happen to agree today.

---

## 0. Public API (frozen — the only way anything talks to the Engine)

The file this lives in can move; this interface cannot change without
updating every consumer. The API exposes **domain actions**, not
feature-specific outputs — recommendations, alerts, health, and colors are
not separate methods, because they're products of the financial state, not
separate responsibilities. If recommendations get redesigned tomorrow, the
API must not need to change. Four public operations, nothing else:

- **`recompute(userId, monthKey)`** — rebuilds the monthly financial summary
  from raw data. The only operation allowed to write to `financialSummary`.
- **`getSummary(userId, monthKey)`** — returns the current
  `financialSummary` document. The only way anything reads calculated
  values — including reason codes, notifications, health, and risk, which
  live inside this one document rather than behind their own methods (see
  Section 5).
- **`simulateTransaction(userId, transaction)`** — answers "what would
  happen if the user spends Rs X right now?" without committing anything.
  Runs the same waterfall/goal-impact logic as a real transaction but
  writes nothing. Powers the confirm-before-you-commit dialogs and lets the
  chatbot answer "can I afford this?" before logging.
- **`validateTransaction(userId, transaction)`** — a lighter check than
  `simulateTransaction`: is this transaction well-formed and affordable at
  all (enough combined category buffer + Savings Pool to cover it), without
  computing or returning the full hypothetical summary. Used as a fast
  guard before bothering to simulate or commit.

```
Chatbot            ──┐
Notification Service ─┼── getSummary(userId, monthKey) ──► reasonCodes, notifications, all calculated fields
Reports             ──┤
Home Screen         ──┘
```

Everything else — the rebalance waterfall, health-color thresholds,
baseline/anomaly math, streak logic, recommendation generation — is a
private helper inside the Engine. No consumer ever calls a helper directly
or gets a dedicated method for it; if a consumer needs something a helper
computes, it's already sitting in the summary document `getSummary`
returns.

## 1. Money Priority Rule (never violated)

```
Income
   ↓
Category Budget
   ↓
Other Category Buffer   (unused budget in OTHER categories)
   ↓
Savings Pool            (last resort, always confirmed with the user first)
```

Any code that needs to fund a shortfall — an overspent category, or a new/
increased budget that exceeds available income — must exhaust the category-
buffer step in full before touching the Savings Pool. Savings is never used
first, never used partially while cheaper buffer exists, and never used
without a confirmation step.

## 2. Savings Rules

- The Savings Pool always exists — it is not something the user creates.
  It is `income − total category budget limits`, always available even with
  zero goals.
- Savings Goals are optional. A goal is a *label* on part of the pool, not a
  separate wallet — creating a goal never moves or duplicates money.
- Goals never duplicate money: the sum of what all goals report as "saved"
  never exceeds the actual Savings Pool balance.
- Savings is used only after all category buffers (this category's own
  remaining budget, then other categories' remaining buffer) are exhausted.
- Using savings automatically and immediately affects goal progress, because
  goal progress is always computed live from the pool — there is no separate
  step to "update" a goal after savings is used.
- Priority tiers: goals in a lower-numbered tier are funded in full before a
  higher-numbered tier gets anything. Goals sharing a tier split that tier's
  share proportionally (side by side). Default tier for a new goal is 1.

## 3. Transaction Rule Checklist

Every transaction commit must resolve these, in this order, every time,
regardless of whether it came from chat, SMS/notification parsing, or manual
entry:

1. **Is it affordable?** (does it fit the category, or does it need funding
   from elsewhere per the Money Priority Rule)
2. **Which category is affected?**
3. **Does it trigger rebalancing?** (category buffer → other categories →
   savings, per Rule 1)
4. **Does it touch savings?** (and if so, which goals are affected, per
   Rule 2)
5. **Does it affect health?** (category health color, overall month health)
6. **Does it affect streaks?** (spending streak, savings streak)
7. **Does this look unusual** compared to the user's own baseline for that
   category?
8. **Does anything above warrant surfacing** — a chat message, a system
   notification, or nothing? (exactly one decision, shared by chat and
   notifications — never decided twice, never decided differently)

No entry path (chat, SMS, manual) is allowed to skip any of these steps or
implement its own version of them.

## 4. Engine Contract

Every mutation — logging a transaction, editing a budget, creating/editing a
goal, updating income, month rollover — ends with exactly one call:

```
FinancialEngine.recompute(userId, month)
```

No exceptions. No route, service, or script is allowed to write a calculated
field (remaining budget, health color, goal progress, streaks, etc.)
directly. If a calculated field needs to change, it changes because
`recompute` ran, not because something patched it inline. (See the Ground
Truth Principle, Section 8, for the specific case this rule was written
to prevent: a derived value quietly kept as a mutable counter instead.)

**Recompute vs. patch:** default to a full recompute for any change that can
affect multiple calculations (income, budgets, goals, transaction edits/
deletes, month rollover) — which in practice is nearly everything. A
targeted patch is only allowed for fields that are provably cosmetic or
fully isolated, with no dependent calculation anywhere else in the summary.
When in doubt, recompute — correctness first, optimize later only if a real
performance problem shows up.

## 5. Summary Document Contract

One document per user per month is the single source of truth for
calculated values: `users/{uid}/financialSummary/{monthKey}`.

```
financialSummary/{monthKey}
├── remainingBudget        (this month, overall)
├── categoryRemaining      (per category: limit, spent, remaining, health)
├── savingsPool            (current balance, how much is claimed by goals)
├── goalProgress           (per goal: saved, remaining, percent, priority)
├── projectedSavings       (end-of-month estimate)
├── dailyAllowance         (safe spend/day for the rest of the month)
├── health                 (overall month: green/amber/red)
├── risk                   (on-track / at-risk)
├── streaks                (spending streak, savings streak)
├── reasonCodes            (array of {code, data} — see below)
├── notifications          (array of {type, status})
└── lastUpdated
```

Example:

```json
{
  "remainingBudget": 5200,
  "dailyAllowance": 180,
  "health": "AMBER",
  "risk": "MEDIUM",
  "reasonCodes": [
    {
      "code": "OVERSPEND_RECOVERY",
      "data": {
        "category": "Food",
        "overspentBy": 300,
        "suggestedDailySpend": 120,
        "recoveryDays": 4
      }
    }
  ],
  "notifications": [
    { "type": "UNUSUAL_SPENDING", "status": "pending" }
  ]
}
```

Raw collections (`budgets`, `transactions`, `goals`, income on the user doc)
remain the source of truth for **inputs**. This document is the source of
truth for **outputs**. UI code must never calculate a field that exists in
this list — it reads it.

Recommendations and alerts are not separate API methods (Section 0) or
separate top-level fields with bespoke shapes — they are `reasonCodes` and
`notifications` entries, computed once by `recompute` and sitting in the
summary for every consumer to read. Reason codes carry data, never
sentences — e.g. `OVERSPEND_RECOVERY`, `SAVINGS_USED_LAST`,
`GOAL_AFFECTED`, `UNUSUAL_SPENDING`, `STREAK_BROKEN`, `MONTH_AT_RISK`. A
separate "Explainer" layer turns a reason code + its data into a short,
simple Romanized Nepali-English sentence for chat, a concise line for a
notification, or an insight card for Reports. The Engine never produces
sentences — chat says it, notifications schedule it, Reports visualize it,
nobody recalculates it.

## 6. Classification Rule — before adding any feature, ask:

**Is this a new rule, a new calculation, or just a new way of presenting
existing information?**

- *"If spending exceeds today's pace, calculate a recovery plan."* → new
  calculation → belongs in the Engine (Recommendation Engine phase), emitted
  as a `reasonCode` in the summary document — not a new API method.
- *"Show a red card when the category is unhealthy."* → presentation →
  belongs in the UI only, reading the existing `health` field.
- *"Notify the user two hours after unusual spending."* → new trigger →
  belongs in the Notification Engine phase, driven by a reason code the
  Engine already produces.
- *"Chat explains why savings decreased."* → presentation → belongs in the
  Explainer layer, reading the existing `alerts`/reason code.

If the answer is "new rule" or "new calculation," it goes in this spec and
in the Engine — never scattered into a route, a widget, or the chatbot
handler directly. If the answer is "presentation," no Engine change is
needed at all.

## 7. Invariants

These must hold after every `recompute`, for every user, every month, with
no exceptions. They're written this explicitly because they become
automated tests later — a failing invariant means the Engine has a bug,
full stop, regardless of which feature triggered it.

- **Money Conservation** — `Available Money = Spent + Remaining Category
  Budgets + Savings Pool`. No money disappears or gets created by a
  recompute. ("Available Money" today just means declared income; the
  invariant is phrased this way, not as `Total Income = ...`, so it keeps
  holding once the app supports multiple income sources, refunds, or
  carry-over balances — at that point it becomes `Net Available Funds =
  Spent + Allocated Remaining + Savings Pool` without needing to redefine
  the invariant itself, only what feeds into "available.")
- **No Negative Budgets** — a category's remaining amount never goes
  negative. If spending would push it negative, the Money Priority Rule
  (Section 1) must have already resolved it — via other-category buffer or
  Savings Pool — before the summary is written. (This app does not support
  debt/negative budgets; if that ever changes, it's a new rule added here
  first, not a quiet exception in code.)
- **Single Source of Truth** — every financial number shown anywhere in the
  app originates from `financialSummary`. If a screen shows a number that
  didn't come from `getSummary`, that's a bug in the UI, not a valid
  shortcut.
- **Deterministic Engine** — given the same income, budgets, transactions,
  and goals, `recompute` always produces the same summary. No hidden
  randomness, no dependence on wall-clock time inside the math itself
  (timestamps are inputs, not entropy).
- **Idempotence** — running `recompute` twice in a row with no data changes
  in between must produce the exact same summary. A second recompute is
  never observably different from the first.
- **Order Independence** — independent transactions produce the same final
  summary regardless of the order they're processed in, given the same
  timestamps and no genuine conflict (e.g. Food −200 then Transport −100
  must land on the same end state as Transport −100 then Food −200).
- **Confirmed Means Persisted** — a transaction becomes financially real
  only when its persisted `status` field is `"confirmed"` in the database
  — never because the UI believes it's confirmed, never because a related
  counter was updated as if it were. The Engine only ever trusts what the
  database actually says, not what any caller assumed happened. (This is
  the exact invariant Stage 2's bug violated: a transaction was counted as
  confirmed by the old `budgets.spent` increment while its own `status`
  field silently stayed `"pending"` — two different parts of the system
  disagreeing about whether the same event was real.)
- **Exactly-Once Recompute** — every financial change produces exactly one
  successful recompute — not zero (a route that forgets to call it leaves
  the summary stale) and not two (a route that double-triggers it wastes
  work and risks two different `recomputeId`s claiming to describe the
  same change). One raw-data write → one recompute call.

## 8. Ground Truth Principle

Every derived value must have exactly one source. Whenever a new feature is
added, this table answers "where does the truth for this actually live?" —
if a value isn't on this list, that's a sign it hasn't been classified yet,
not a sign it's free to be computed wherever's convenient.

| Value | Ground Truth |
|---|---|
| Budget limit | Budget document |
| Income | Income document |
| Goal target, timeframe, priority | Goal document |
| Category spent | Sum of confirmed, non-deleted transactions |
| Savings Pool | Engine calculation |
| Remaining Budget | Engine calculation |
| Goal Progress | Engine calculation |
| Streaks, milestones, behavior event history | **Behavior Engine's own persisted state (Phase 4.5)** — the one exception to "never a mutable counter" below, and the only Engine-owned persisted collections (`behaviorState` + `behaviorHistory`) in the system; see Phase 4.5A for why |

Note what's *not* in the left column as a document field: `spent` is not
read from a stored counter — it's computed by summing transactions every
time. **`budgets.spent` is not raw data. It is derived data that was
historically kept as a mutable counter, hand-incremented and
hand-decremented at eight separate call sites across the codebase — three
of which don't exist (edit and delete never reverse it) — which is exactly
the kind of silent drift this whole Engine exists to eliminate.** Once
Transactions is migrated (see the Build Roadmap), a budget document stores
only `limit`; `spent` is never written to it again.

**No route, service, or UI component may directly mutate a derived
financial total.** If a value can be recomputed from ground-truth data, it
must never also be maintained as a mutable counter updated in place. The
moment code reads `budget.spent += amount` (or any equivalent
increment/decrement of a value this table marks as derived), that should
read as a bug on sight — regardless of which phase or route it appears in.

### Transaction boundary

> The Engine only ever sums transactions where
> `status == "confirmed" AND isDeleted == false`.
>
> Pending? Ignore. Cancelled? Ignore. Deleted? Ignore. Confirmed? Financial
> truth.

**A confirmed transaction is an immutable financial event that contributes
to the user's financial state.** Any later correction happens by editing,
recategorizing, soft-deleting, or replacing that event — never by mutating
a derived total directly. This is the business meaning of "confirmed," not
just the technical one: once an event is confirmed, the Engine's job is to
keep re-deriving the truth from the full set of confirmed events, not to
patch a running total in response to it.

## 9. Bugs Found During Migration

Not needed for coding — this is documentation of what the migration itself
proved. Neither bug below was introduced by the Engine; both already
existed, silently, and were only made visible because the Engine enforces
a strict, single definition of financial truth where the old scattered
code didn't. This table is the evidence that the migration is improving
correctness, not just moving code around — update it every time a stage
surfaces something real.

| Stage | Bug | Root Cause | Fix |
|---|---|---|---|
| 1 | `budgets.spent` silently drifted from reality after an edit or delete | A derived value (sum of confirmed transactions) was maintained as a mutable counter instead of being recomputed | Engine derives `spent` from confirmed, non-deleted transactions every recompute — the counter is never trusted |
| 2 | A transaction could be counted as spend without its own `status` ever becoming `"confirmed"` | `confirm_transaction` built an `update_payload` (status→confirmed) but never wrote it to the transaction document; the legacy budget increment beside it didn't check the transaction's own status, so it "worked" anyway | Added the missing `tx_ref.update(update_payload)` write; codified as the Confirmed Means Persisted invariant (Section 7) |
| 3C | An amount-only chat correction ("no, it was 350") silently deleted the expense and relogged nothing — the money vanished | Relogging was gated on a new category being parsed; an amount-only correction had none, so the `else` branch only deleted, never recreated | Redesigned to modify the existing transaction in place — amount and category are now independent, neither gates the other |
| UAT | An income notification asked "which category?" — a category list built for expenses — before confirming | `category_uncertain` (chat.py) and the `CATEGORY_REQUIRED` check (confirm.py, and a third copy inside chat.py's own conversational-confirm branch) never checked transaction type; income has no category at all, so `category is None` was always true for it, always tripping the expense-only logic | All three sites now gate on `tx_type == "expense"` first — income can never be "category uncertain" |
| UAT | Categories screen showed a stale (and reportedly briefly wrong) budget percentage after a chat correction | `chat_screen.dart`'s `_refreshCategoriesIntents`/`_refreshHomeIntents` sets never included `"correction"`, so a correction reply never told the UI to refetch — the same gap another intent had already been patched for elsewhere in the file (`primary_intent = "expense_log"  # trigger frontend categories refresh`) | Added `"correction"` to both sets, following the existing pattern. **Not fully confirmed** — this closes a real, concrete gap (no refresh signal at all), but the exact transient "2310/2200 self-correcting" visual wasn't reproduced directly; needs a live re-test to confirm it's the complete explanation |

Note: an item previously listed here from Stage 3B (a second ambiguous
chat message silently discarding the first unresolved one) was moved to
**Future Workflow Improvements** below — it's a conversation-state-
management gap the migration exposed, not an Engine or transaction-truth
bug, and this table is reserved for the latter.

## 9b. Future Workflow Improvements

Not Engine bugs, not fixed during migration — UX/design gaps the
migration happened to surface. Left here so they aren't lost, and left
alone because Phase 0 already established: don't redesign features
mid-migration.

- **Orphaned pending chat transaction** (found during Stage 3B): creating
  a new ambiguous-chat pending action calls `pendingAction/current.set()`
  unconditionally, silently discarding a still-unresolved previous one.
  That earlier transaction is left as `status: "pending"` forever, with no
  conversational path back to it. Current assumption, stated explicitly
  rather than left implicit: **one active pending chat interaction per
  user.** A future fix would ask the user to resolve the first one before
  starting a second (or queue/ID-select — see the original discussion) —
  a conversation-design decision, not a migration one.

## 9c. Infrastructure Discoveries

Not product bugs, not Engine bugs — deployment/environment gaps the
migration's testing happened to surface. Kept separate from Section 9 on
purpose: these say something about operational readiness, not about
whether the migration itself improved correctness.

| Discovery | Resolution |
|---|---|
| Missing composite index for `chat.py`'s `correction`/`undo_last_expense` query (`type`+`status`+`isDeleted`+`createdAt`) — declared in `firestore.indexes.json` but never deployed, meaning both chat intents have likely errored for every real user who ever triggered them | Deployed via `firebase deploy --only firestore:indexes`; added `backend/firebase.json` so this deploy path exists going forward |
| Two other declared indexes (`messages` collection) were invalid — Firestore rejected them as redundant with automatic single-field indexing, blocking the entire index deploy | Removed both from `firestore.indexes.json` |
| Missing `email-validator` dependency blocked importing `chat.py` at all (`schemas/profile.py`'s `EmailStr` usage) | Installed via `pip install email-validator` |

---

## Phase 0 is frozen

Once Phase 1 begins, this document does not grow with new features. During
implementation, only bug fixes and ambiguity clarifications are allowed
here — a new rule, a new invariant, or a redesigned contract means stopping
and treating it as a deliberate Phase 0 revision, not a drive-by edit while
mid-build. This is what keeps the Engine from becoming a moving target
while everything else is being built on top of it.

---

## Build Roadmap

| Phase | Scope |
|---|---|
| 0 | Financial Rules & Contracts (this document) |
| 1 | Core Money Engine — remaining budget, category balances, Savings Pool, rebalance waterfall |
| 1.5 | Integration — migrate existing routes to write raw data then call the Engine, no new functionality |
| 1.9 | UI Migration — every screen reads `financialSummary` instead of computing its own numbers; no redesign, only swapping the data source |
| 2.0 | Metrics Design — no code; per-metric assumptions, confidence, and the Facts→Calculations→Guidance→Predictions→Coaching ladder |
| 2 | Financial Metrics — Days Remaining, Budget Utilization, Spending Pace, Recommended Daily Spend, Recovery Plan, Category Pressure, Savings Stability |
| 3 | Health & Risk Engine — green/amber/red, health scores |
| 4 | Recommendation Engine — recovery suggestions, coaching insights |
| 4.5 | Behavior Engine — streaks, habits, milestones (owns pattern detection so Notifications never has to) |
| 5 | Notification Engine — 5.0 Philosophy, 5.1 Types, 5.2 Eligibility, 5.3 Priority, 5.4 Frequency, 5.5 Timing, 5.6 Generator, 5.7 Lifecycle, 5.8 Notification Center, 5.9 Review & Freeze |
| 6 | Chatbot Integration — reads Engine results, explains via the Explainer |
| 7 | Reports & Dashboard — display-only, no calculations |

Phase 1 is migrated one responsibility at a time, not absorbed in one
sweep — each step below replaces one existing scattered calculation, is
verified to match current app behavior, and only then has its old logic
removed:

1. Remaining budget (this month, overall)
2. Category balances (limit, spent, remaining per category)
3. Savings Pool (`income − total category budget limits`)
4. Rebalance waterfall (category → other categories → savings-last)
5. Goal impact (live progress against the pool, priority tiers)

### Phase 1 — Definition of Correct

> Given the same income, budgets, goals, transactions, and date, the
> Financial Engine must always produce exactly the same financial summary,
> regardless of which screen, API, or chatbot action triggered the
> recomputation.

Every design decision below is judged against this sentence, not against
"does it compile" or "does one screen look right."

### Phase 1 — What the Engine receives (inputs only): the Engine Input Contract

The Engine works only with raw, ground-truth data (Section 8) — it never
receives an already-computed value:

```
Financial Engine Inputs
├── Income
├── Budgets (limits only)
├── Goals (target, timeframe, priority)
├── Confirmed Transactions (status == confirmed, isDeleted == false)
└── Current Date
```

Notice what's deliberately absent: not `budget.spent`, not `savingsPool`,
not `remainingBudget`. Those are outputs. `spent` in particular is *not*
an input at all as of the Transactions migration — it's derived by summing
Confirmed Transactions per category, every recompute, not read from a
stored counter (see the Ground Truth Principle, Section 8, and the
Transactions design below).

It never receives remaining budget, health, colors, recommendations, or
daily allowance as input either — those only ever come out of the Engine,
never into it. (Health/colors/recommendations aren't Phase 1's job at all —
see the roadmap — but the rule holds from here forward: once something is
an output, it is never fed back in as an input.)

**Status note:** this is the target contract. The Phase 1 code shipped so
far still reads `spent` off each budget document as an interim measure,
because Transactions (the route that would let the Engine sum confirmed
transactions directly) hasn't been migrated yet. That gap closes as part
of the Transactions migration below — until then, `_load_data` reading
`spent` from `budgets` is a known, temporary exception to this contract,
not a silent violation of it.

### Phase 1 — What the Engine returns

```
financialSummary/{monthKey}   (Phase 1 fields only — no colors yet)
├── income
├── totalSpent
├── remainingBudget
├── categoryRemaining     (per category: limit, spent, remaining)
├── savingsPool
├── goalProgress          (per goal: saved, remaining, percent, priority)
├── rebalanceResult        (what moved where, if anything, on the last commit)
├── metadata
│   ├── version            (schema version of this summary shape)
│   ├── engineVersion       (code version that produced it)
│   ├── recomputedAt
│   ├── reason              (e.g. "transaction_added", "budget_edited", "manual")
│   └── decisionLog         (ordered list of what the pipeline did — dev-only,
│                            never shown to the user, exists purely to make
│                            debugging a specific recompute possible)
└── lastUpdated
```

Health, risk, streaks, `reasonCodes`, and `notifications` (Section 5) are
added in later phases — Phase 1's summary is deliberately smaller than the
final shape.

### Phase 1 — Pipeline shape

`recompute` is not one function — internally it's a fixed sequence of
single-responsibility steps, each easy to test in isolation:

```
Load Data → Validate → Calculate Budgets → Calculate Savings →
Apply Rebalancing → Calculate Goal Impact → Build Summary → Save Summary
```

Each step appends to the `decisionLog` (e.g. `"Food exceeded by Rs300"`,
`"Moved Rs200 from Entertainment"`, `"Moved Rs100 from Savings"`,
`"Goal progress reduced"`) so a specific recompute can be traced after the
fact without re-deriving it by hand.

### Phase 1 — Test scenarios (must all pass before old logic is removed)

1. **Clean state** — income declared, budgets set, no transactions. Summary
   must match the inputs exactly (remaining = limit for every category,
   savings pool = income − total limits).
2. **Normal spend** — spend within a category's budget. Only that
   category's remaining and total spent change; Savings Pool untouched.
3. **Overspend, buffer available** — spend beyond one category's limit
   while another category still has buffer. Rebalancing moves money
   between categories; Savings Pool untouched.
4. **Overspend, everything exhausted** — every category fully spent, then
   spend again. Savings Pool absorbs it; any active goal's progress drops
   accordingly.

These are the acceptance tests for Phase 1 — "the code runs" is not the
bar, "these four scenarios produce the exact expected numbers" is.

**Phase 1 is verified as of 2026-07-17** against a real account
(`botbachat@gmail.com`, month `2026-07`): overall totals, every category,
every goal, determinism, mutation-reversibility, rebalance priority order,
and simulated-vs-committed rebalance all matched. See
`backend/scripts/audit_financial_engine.py` and
`backend/tests/test_financial_engine.py`.

### Phase 1.5 — Integration (no new functionality)

Phase 1 proved the Engine computes the same numbers as the current app.
Phase 1.5's only job is making the Engine the thing everything *actually
reads from* — by migrating existing routes to the same pattern, one at a
time, verifying after each one before moving to the next:

```
Old Route
    ↓
Validate request
    ↓
Write raw data              (routes still own this — transactions, budgets, goals)
    ↓
FinancialEngine.recompute(userId, monthKey)     (Engine owns every derived calculation)
    ↓
Return updated summary
```

No new calculations, no new rules, no new fields — Phase 1.5 is purely
"stop computing things inline, call the Engine instead." If a route
currently computes something the Engine doesn't yet produce, that's a
Phase 1/2+ gap to flag, not something to quietly reimplement inline during
1.5.

**Migration order** (least risky / most foundational first):

1. **Budgets** — edits affect nearly every calculation, but the flow itself
   is straightforward.
2. **Income** — simplest possible case: change income → recompute → done.
3. **Goals** — goals stop calculating anything themselves; they only
   create/edit the goal record, then the Engine recalculates savings
   allocation.
4. **Transactions** — the biggest one: spending, rebalance, savings,
   notifications, future recommendations all meet here. Left until the
   Engine has already proven itself on the simpler routes.
5. **Chat** — last, and by then close to trivial: `chat.py` stops doing
   math entirely and just asks "what happened?", then explains it.

**Raw vs. Derived** — the rule that keeps this migration from regressing:
every field in the database answers exactly one of these two questions.

- **Raw** — routes may write it: `income`, `transaction`, `budget`, `goal`.
- **Derived** — only the Engine may write it: `remainingBudget`,
  `savingsPool`, `projectedSavings`, `health`, `dailyAllowance`,
  `recommendations`, `alerts`.

If a value is derived, a route that writes it directly is a bug, full
stop — regardless of which phase introduced it.

**Recompute identity** — now that `recompute()` is stable, each run gets a
traceable identity in `metadata`, not just a timestamp:

```
metadata
├── version
├── engineVersion
├── recomputeId       (unique per run)
├── reason             (e.g. "transaction_added", "budget_edited" — what triggered this run)
├── durationMs
├── recomputedAt
└── decisionLog
```

Not needed to debug today's bug — needed for the bug six months from now
that only shows up as "the numbers were briefly wrong for one user on one
day."

**Standard reason codes** — `reason` is not free text. Every route calls
`recompute` with one of these (defined once as `RecomputeReason` constants
in `financial_engine.py`, imported by callers, never a hand-typed string):

```
INCOME_UPDATED
BUDGET_CREATED
BUDGET_UPDATED
BUDGET_DELETED
GOAL_CREATED
GOAL_UPDATED
GOAL_DELETED
TRANSACTION_CREATED
TRANSACTION_CONFIRMED
TRANSACTION_EDITED
TRANSACTION_DELETED
MONTH_ROLLOVER
```

(`MANUAL` and `SUMMARY_MISSING` also exist, for the Engine's own internal/
self-heal calls — not something a route should ever pass.)

**Recompute triggers** — the definitive reference for "does this event
need a recompute?" whenever a new feature is added:

| Event | Recompute? |
|---|---|
| Budget Created | ✅ |
| Budget Updated | ✅ |
| Budget Deleted | ✅ |
| Income Updated | ✅ |
| Goal Created | ✅ |
| Goal Updated | ✅ |
| Goal Deleted | ✅ |
| Transaction Added | ✅ |
| Transaction Edited | ✅ |
| Transaction Deleted | ✅ |
| Month Changed (rollover) | ✅ |

If an event mutates any raw data (income, budgets, transactions, goals),
it recomputes — there is no "small enough to skip" exception (see the
Exactly-Once Recompute invariant above).

**Migration Complete criteria — what "migrated" actually means for a
route.** "Budgets migrated" is not itself a checklist item; a route only
counts as fully migrated once all eight of these are true. Fewer than
eight is "migration in progress," stated as such — never rounded up to
"complete":

- [ ] Route only writes raw data
- [ ] Route calls `FinancialEngine.recompute()`
- [ ] Engine updates the summary correctly
- [ ] UI reads the summary correctly
- [ ] No financial calculations remain in the route
- [ ] Old duplicated logic has been removed
- [ ] Unit tests pass
- [ ] Real-user verification passes

**Migration Progress Table** — kept honest, updated as each route moves:

| Route | Migration Status | Remaining Work | Verification |
|---|---|---|---|
| Budgets | 🟡 Partial | Remove duplicate rebalance/response-building logic; UI reads summary | ✅ |
| Income | 🟡 Partial | UI reads summary | ✅ |
| Goals | 🟡 Partial | UI reads summary | ✅ |
| Transactions | 🟡 Partial (Engine wired everywhere; old `Increment` sites not yet deleted) | Delete all 8 legacy `Increment` call sites now that every operation recomputes independently of them | ✅ (Stages 1, 2, 3A-3D, 4A, 4B — every entry point verified to produce identical results) |
| Chat | 🟡 Partial — transaction operations complete (Chat Transaction Integration Complete, above); query/reporting intents (`query_past_report`, `query_top_spend_category`, `query_spend_feedback`) still compute directly from transactions rather than reading `financialSummary` | Migrate query intents to read the summary once it has the fields they need (later phases) | ✅ (transaction operations) |

**Migration Progress (bugs and tests per stage)** — read six months from
now, this is the evidence the migration improved reliability, not just
moved code around:

| Stage | Bugs Found | Bugs Fixed | Tests Added |
|---|---|---|---|
| 1 | 1 | 1 | 5 scenarios (`test_financial_engine.py`) + audit script |
| 2 | 1 | 1 | Live confirm test (single + bulk) |
| 3A | 0 | 0 | Live direct-chat-transaction test |
| 3B | 1 (conversation-state gap, tracked separately) | 0 | Live yes/no confirmation test |
| 3C | 2 (1 product bug, 1 infrastructure) | 2 | Live amount-only + category-change correction tests |
| 3D | 0 | 0 | Live undo test |
| 4A | 0 | 0 | 5 live REST-edit cases (amount, category, both, description-only, edit-deleted) |
| 4B | 0 | 0 | 4 live REST-delete cases (confirmed, pending, double-delete, already-deleted) |

**Budgets — detail:**
- [x] Route only writes raw data — create/update/delete only ever touch the
  `budgets` collection and `alerts`
- [x] Route calls `recompute()` — `BUDGET_CREATED` / `BUDGET_UPDATED` /
  `BUDGET_DELETED`
- [x] Engine updates the summary correctly — confirmed via a fresh
  `recomputeId` after each call, verified live against
  `botbachat@gmail.com`
- [ ] UI reads the summary correctly — nothing reads `financialSummary` yet;
  the UI still reads the route's own response, which is still built from
  the route's own calculation (see next item)
- [ ] No financial calculations remain in the route — **false**. The
  income-allocation/shortfall/rebalance-plan block inside
  `create_or_update_budget` still computes and returns the actual
  rebalance plan the frontend acts on; the Engine call is additive only
- [ ] Old duplicated logic removed — not yet, deliberately deferred until
  Transactions and Chat are migrated too, since the same waterfall logic
  is duplicated in more than one place and should be deleted everywhere at
  once
- [x] Unit tests pass
- [x] Real-user verification passes (full audit + rebalance-priority
  cross-check against the old path, see Phase 1 section above)

**Income — detail (the gold-standard flow):**
```
Receive Request → Validate Input → Write Raw Income →
FinancialEngine.recompute(reason=INCOME_UPDATED) → Return Response
```
- [x] Route only writes raw data — `income.inHand`/`inBank`/`onlineBanking`
  only; `total` in the response is a trivial sum for display, never stored
  as a derived field elsewhere
- [x] Route calls `recompute()` — `INCOME_UPDATED`
- [x] Engine updates the summary correctly — verified live: bumping
  `inHand` by Rs 500 moved `income` 10995→11495 and `savingsPool`
  10395→10895 automatically, with no other code touching either field;
  reverted cleanly
- [ ] UI reads the summary correctly — same gap as Budgets, nothing reads
  `financialSummary` yet
- [x] No financial calculations remain in the route — confirmed: this
  route never touched Savings Pool, goal progress, remaining budget, or
  health before, and still doesn't; the Engine cascade is the *only* thing
  connecting an income change to those values now
- [x] Old duplicated logic removed — there wasn't any to remove; this
  route was clean already, which is why it's the reference implementation
- [x] Unit tests pass
- [x] Real-user verification passes

Income is *not* marked "complete" only because of the shared "UI reads the
summary" gap — no route can individually finish that criterion alone,
since nothing anywhere reads `financialSummary` yet. That's a Phase 1.5
exit condition across all five routes, not a per-route one.

**Goals — detail:** the raw-vs-derived line for a goal is: *name,
targetAmount, timeframeMonths, priority, status* are raw (stored fields);
*savedSoFar, remaining, percentComplete, monthlyTarget* are derived. Before
migration, the derived math (`percentComplete`/`remaining`/
`monthlyTarget`/the completed-status override) was computed inline in
`routes/goals.py`'s `_with_computed_fields` — duplicating, field-for-field,
what `financial_engine.py`'s `_calculate_goal_impact` already computed
internally for its own summary. Fixed by expanding the Engine's
`goalProgress` output to the full shape the route needs (adding
`savedSoFar`, `percentComplete`, `monthlyTarget`, `status` alongside the
existing `saved`/`percent`), then replacing `_with_computed_fields` with
`_merge_engine_fields` — which does no math at all, only copies the
Engine's already-computed entry onto the raw serialized doc.

- [x] Route only writes raw data — create/update/delete only ever touch the
  `goals` collection
- [x] Route calls `recompute()` — `GOAL_CREATED` / `GOAL_UPDATED` /
  `GOAL_DELETED`; GET calls read-only `get_summary()` (self-heals, no
  mutation, so no recompute call belongs there)
- [x] Engine updates the summary correctly — verified live: create, edit
  target amount, rename, and delete all produced the expected summary
  changes (see lifecycle verification below)
- [ ] UI reads the summary correctly — same shared gap as Budgets/Income
- [x] No financial calculations remain in the route — `_merge_engine_fields`
  performs zero arithmetic; every derived field is copied from
  `summary["goalProgress"]`. The one narrow exception is the defensive
  fallback for a goal not yet reflected in the summary (should not happen
  given every mutation path now recomputes, but kept so GET never crashes
  on a stale/missing entry)
- [x] Old duplicated logic removed — `_with_computed_fields` deleted
  entirely, along with the direct `compute_goal_progress`/
  `get_available_pool` imports it used
- [x] Unit tests pass
- [x] Real-user verification passes — full lifecycle tested live against
  `botbachat@gmail.com`:
  - **Create** (target 1000, 2 months, priority 5) → `GOAL_CREATED`
    recompute, goal count 2→3, `monthlyTarget` correctly `500.0`
  - **Edit target amount** (1000→2000) → `GOAL_UPDATED` recompute,
    `monthlyTarget` recalculated to `1000.0`, `savingsPool` unchanged (as
    it should be — editing a goal never touches budgets/income)
  - **Rename** → `targetAmount` and `percentComplete` both unchanged,
    confirming only metadata moved, no financial number shifted
  - **Delete** → `GOAL_DELETED` recompute, goal count 3→2, `savingsPool`
    back to its original value
  - Incidentally re-confirmed the priority-tier waterfall itself: the new
    priority-5 goal correctly showed `savedSoFar: 0` because the two
    existing priority-1/priority-2 goals already fully claimed the
    Rs 10,395 pool between them

**Transactions — pre-implementation design (2026-07-17, not yet coded).**
Per the standing rule that Transactions gets the most care of any route
(it's where every financial rule converges, and it's an *event* stream,
not configuration), this section was written and agreed before any
Transactions code changes — planning, not implementation.

*Current-state audit* (grounded in the actual code, `routes/transactions.py`,
`routes/chat.py`, `routes/confirm.py`):

- Transaction `status` values in use today — exactly three, no more:
  `pending`, `confirmed`, `cancelled`.
- Sources that create a transaction **directly as `confirmed`** (no pending
  step, because the user directly stated the amount): manual form entry,
  unambiguous chat parses.
- Sources that create a transaction **as `pending`** (inferred, needs
  confirmation): notification/SMS detection, offline sync, ambiguous chat
  parses.
- `budgets.spent` is incremented at **five** call sites
  (`transactions.py:70`, `chat.py:144/516/1700`, `confirm.py:184/505`) and
  decremented at **three** (`chat.py:1537/1600/2509`, one a near-duplicate
  of another).
- **`PUT /transactions/{id}` (edit) and `DELETE /transactions/{id}`
  (soft-delete) never touch `spent` at all.** Editing or deleting a
  transaction through the main REST API silently leaves the budget's
  `spent` wrong, permanently — the only place that correctly reverses
  `spent` on edit/delete is chat's `undo_last_expense`/`correction`
  conversational intents, not the REST endpoints a transaction-history
  screen would call. This is a live bug, not a hypothetical one, and it's
  the direct consequence of treating `spent` as a mutable counter (Ground
  Truth Principle, Section 8) instead of deriving it from transactions.

*Transaction state machine* (as it actually exists, not an invented one):

```
created
  │
  ├─ direct (manual form, unambiguous chat) ──────────► confirmed
  │                                                          │
  └─ pending (notification/SMS, offline sync,          edit / recategorize
              ambiguous chat)                                │
        │                                                    ▼
        ├──► confirmed  (user confirms) ───────────────► confirmed
        │         │                                          │
        │    soft-delete                                soft-delete
        │         ▼                                          ▼
        │    confirmed + isDeleted=true              confirmed + isDeleted=true
        │
        └──► cancelled  (user rejects) — never real, Engine never sees it
```

*Operation classification:*

| Operation | Touches money? | Recompute? |
|---|---|---|
| Create (direct-confirmed) | ✅ | ✅ |
| Create (pending) | ❌ (not yet real) | ❌ |
| Confirm pending | ✅ | ✅ |
| Reject/cancel pending | ❌ (never was real) | ❌ — matches existing code, which already comments "No budget changes on cancellation" |
| Edit confirmed (amount/category) | ✅ | ✅ — currently missing entirely; this is the bug above |
| Delete confirmed (soft) | ✅ | ✅ — currently missing entirely; this is the bug above |
| Recategorize | ✅ (per-category shifts even though the month total doesn't) | ✅ |

*The fix, consistent with the Ground Truth Principle:* once Transactions
migrates, `financial_engine.py`'s `_load_data` sums `spent` per category by
querying `transactions` directly (`status == confirmed AND isDeleted ==
false`), the same boundary already stated in Section 8 — never by reading
`budgets.spent`. `budgets` documents stop storing `spent` at all. Every
route that currently does `Increment(amount)`/`Increment(-amount)` on a
budget's `spent` (all eight call sites listed above) is deleted, not
migrated — there is nothing to migrate, because there is no longer a
counter to increment. Create/Confirm/Edit/Delete/Recategorize each just
write the raw transaction change and call `recompute()`; the Engine
re-derives `spent` from scratch every time. This is what actually closes
the edit/delete bug, permanently, rather than patching it as a ninth call
site.

*Progress (2026-07-17):* `financial_engine.py`'s `_load_data` now sums
`spent` per category via `utils.sum_category_expense` (confirmed,
non-deleted transactions) instead of reading `budgets.spent` — the
foundational Engine-side half of this migration. Verified live against
`botbachat@gmail.com`: no drift existed between the old counter and the
real transaction sum before the switch; after switching, the full audit
(including a rebuilt mutation-reversibility test that now creates and
soft-deletes a real transaction, since bumping `budgets.spent` directly no
longer has any effect on the Engine — correctly so) passes end to end.
**Not yet done:** the routes themselves (`transactions.py`, `chat.py`,
`confirm.py`) still increment/decrement `budgets.spent` at all eight call
sites and still don't call `recompute()` anywhere; `PUT`/`DELETE
/transactions/{id}` still don't touch money at all. The Engine now
computes correctly *despite* those stale writes (it ignores
`budgets.spent` entirely), but the bug they represent — and the dead
`spent` field itself — isn't removed until those routes are migrated.

Also worth recording: `GET /budgets` (`routes/budgets.py`) already computes
its `spent` for the API response by summing confirmed transactions
directly — it does **not** trust the stored `budgets.spent` field either,
and hasn't for a while (comment in that code: "Always use transaction-based
spend so category page matches reports"). So the current UI is already
insulated from whatever the stored field says; the two places that *do*
still read it are the rebalance-shortfall calculations in
`routes/budgets.py`'s `create_or_update_budget` and
`budget_service.py`'s `_compute_rebalance_transfers` (both reading a
donor category's `spent` to compute buffer) — these are the same
"old duplicated rebalance logic" already flagged as deferred cleanup in
the Budgets migration detail above, and get fixed together with it, not
piecemeal per Transactions stage.

### Ground Truth Migration Complete

```
Before                              After
──────                              ─────
Budget.spent                        Confirmed Transactions
    │                                    │
    ▼                                    ▼
Source of truth                     Source of truth
```

This is not an implementation detail — it's a permanent architectural
decision, dated here: **as of 2026-07-17, `financial_engine.py` no longer
treats `budgets.spent` as ground truth for anything.** Category spend is
summed fresh from confirmed, non-deleted transactions on every recompute.

**Stronger rule, replacing the weaker "don't write it" framing:** no code
outside the Financial Engine may ever *read or rely on* `budgets.spent` —
not just "don't write to it." Reading it is dangerous even where writing
wouldn't be, because the field is scheduled for deletion once every
consumer is migrated; code that reads it today is code that will silently
break later, not code that's merely redundant today. (The two known,
tracked exceptions — the rebalance-shortfall calculations above — are
temporary and already scheduled for removal alongside the rest of the
duplicated rebalance logic, not a standing carve-out.)

**Field lifecycle decision:** Option A — keep `budgets.spent` on the
document temporarily, stop trusting it everywhere it's still read, delete
the field entirely only once every route is migrated and the UI reads
`financialSummary` directly. Not Option B (stop writing immediately, leave
stale values around indefinitely) and not Option C (delete the field now,
before every consumer is confirmed migrated) — deleting a field
prematurely, while something still silently expects it, is worse than
leaving a soon-to-be-dead one in place a little longer.

### Transactions route migration — staged, not all at once

Each stage below migrates one class of transaction operation to the
`Create/Confirm/Edit/Delete → recompute()` pattern, and is independently
verified against the full audit suite before the next stage starts:

1. **Direct confirmed transactions** — manual form (`/transactions/manual`,
   `/transactions`). The simplest case: already confirmed at creation,
   nothing to wait on.
2. **Pending confirmation** — notification/SMS-detected transactions
   (`routes/confirm.py`'s confirm/reject/bulk-confirm).
3. **Chat Transaction Flows** — `chat.py` is one file but several distinct
   financial actions live inside it; migrating them together would hide
   which one broke if something did. Split into four sub-stages, each
   independently verified against the full audit before the next starts:
   - **3A — Direct chat transactions**: unambiguous expense/income
     ("spent Rs 250 on Food") — creates a confirmed transaction directly,
     same shape as Stage 1's manual-form case.
   - **3B — Ambiguous chat confirmation**: ("spent 300," category
     unknown) — creates a pending transaction, asks a follow-up, confirms
     on yes. Same shape as Stage 2's pending→confirmed case.
   - **3C — Chat corrections**: ("no, it was 350") — edits a confirmed
     transaction's amount/category in place.
   - **3D — Chat undo**: ("undo my last expense") — soft-deletes a
     confirmed transaction. Currently the *only* code path that correctly
     reverses `budgets.spent` on removal — migrating it means letting
     `recompute()` replace that manual `Increment(-amount)` reversal, not
     just adding a call beside it.
4. **Edit** — `PUT /transactions/{id}`, currently the missing-reversal bug
   (distinct from 3C, which is chat's own edit path specifically).
5. **Delete** — `DELETE /transactions/{id}`, the other half of the same bug
   (distinct from 3D, which is chat's own delete path specifically).

**Stage 1 complete (2026-07-17).** `POST /transactions/manual` and
`POST /transactions` both now call `recompute(reason=TRANSACTION_CREATED)`
after writing the transaction; the old `Increment` write in
`/transactions/manual` was deliberately left in place (Option A — nothing
reads it as ground truth anymore, but it isn't deleted until every
consumer is migrated).

Verifying this live produced an unplanned but useful demonstration of the
exact bug this migration exists to fix: a Rs 15 test transaction was
created, correctly incremented the legacy `budgets.spent` counter to 535,
then was soft-deleted for cleanup. Since Delete (Stage 6) isn't migrated
yet, that deletion never reversed the increment — `budgets.spent` was left
permanently wrong at 535 while the Engine, correctly summing only
non-deleted confirmed transactions, reported 520. The audit caught this
immediately as a mismatch against the old counter. The stale value was
corrected by hand (one-time), and `scripts/audit_financial_engine.py`'s
comparison baseline was updated to independently sum confirmed
transactions itself (`sum_category_expense`) rather than trust
`budgets.spent` — consistent with the Ground Truth Migration above, this
script must not keep validating against a source the architecture has
already deprecated. Full audit re-run clean afterward.

**Stage 2 complete (2026-07-17)** — pending → confirmed
(`routes/confirm.py`). Added the `TRANSACTION_CONFIRMED` reason code.
`confirm_transaction` (single) and `bulk_confirm_transactions`
(`action=="confirm"`) now call `recompute()` after the transaction is
confirmed — for the bulk path, exactly once per distinct month actually
touched by a confirm, not once per item. `reject_transaction` and bulk
`action=="cancel"` correctly call no recompute at all, since a
pending→cancelled transaction was never counted by the Engine in the
first place — nothing about financial state changed (matches the
Operation Classification table above).

**A second real, pre-existing bug was found and fixed while migrating
this stage** — not caused by this migration, but only surfaced by it:
`confirm_transaction` built an `update_payload` dict (`status: "confirmed"`
plus any amount/category overrides) but **never actually wrote it to the
transaction document** — `tx_ref.update(update_payload)` was missing
entirely. Every transaction confirmed through the single-confirm endpoint
(the primary path for SMS/notification confirmations) has been staying
`status: "pending"` in Firestore forever, invisible until now because the
legacy `budgets.spent` `Increment()` call a few lines below doesn't check
the transaction's own persisted status — it "worked" by coincidence, while
the transaction itself silently never became real. This means
`GET /transactions/pending/notifications` has likely been showing
already-confirmed transactions as still pending for as long as this
endpoint has existed. Fixed by adding the missing write. Verified live:
before the fix, the Engine correctly reported no spend change after
confirming (because the transaction genuinely wasn't confirmed in
Firestore, whatever the old counter said); after the fix, the Engine
correctly reports the expected spend increase, and the transaction
document's `status` field is verified `"confirmed"` afterward.

Both stages' live testing repeatedly demonstrated the same secondary
effect worth naming explicitly: every test transaction created via the
still-unmigrated legacy `Increment()` code and later soft-deleted for
cleanup leaves `budgets.spent` freshly drifted, requiring a manual
one-time correction each time (via `sum_category_expense`) until Stage 6
(Delete) is migrated. This is expected, not a new bug — it's the same
known gap re-confirming itself on every test, exactly as predicted.

**Stage 3A complete (2026-07-17)** — direct chat transactions
(unambiguous expense/income, e.g. "spent Rs 250 on Food"). The fix lives
in exactly one place: `chat.py`'s shared `_handle_expense_or_income`
helper now calls `recompute(reason=TRANSACTION_CREATED)` once, at the end
of the function, after the transaction is saved — every call site across
the file (multiple intents route through this one helper) gets the fix
for free, with no per-call-site duplication. The idempotency-hit early
return (a duplicate message replay) correctly triggers no recompute,
since nothing new was written. Verified live against
`botbachat@gmail.com`: a Rs 12 chat-originated Food expense correctly
moved `totalSpent` 540→552, tagged `TRANSACTION_CREATED`; cleaned up and
reverted. Full audit clean afterward. No new bug found this stage — 3A's
code was already structurally identical to Stage 1's manual-form path.

**Stage 3B complete (2026-07-17)** — ambiguous chat confirmation
(`chat.py`'s conversational yes/no flow over `pendingAction/current`).
Three distinct code paths confirm a chat-pending transaction, all inside
the main `/chat` handler, none previously calling `recompute()`:

1. The primary yes-path (multi-transaction confirm loop).
2. The "skip budget" path — user declines to set up a budget for a new
   category, but the expense is still confirmed without one.
3. (The old-format fallback with no stored `pendingTxIds` already gets
   Stage 3A's fix for free, since it calls `_handle_expense_or_income`.)

Both (1) and (2) now call `recompute(reason=TRANSACTION_CONFIRMED)` right
after the transaction's status is written and before returning. The pure
cancel/discard path correctly still triggers no recompute — matches Stage
2's precedent, nothing financial happened.

Before coding, three questions were answered against the actual
implementation, not assumed:
- **What counts as the active pending chat transaction?** The explicit
  `pendingTxIds` list stored on `pendingAction/current` at creation time —
  confirmation looks up transactions by ID, never by "the latest message."
- **Can multiple pending chat transactions coexist?** Structurally no —
  `pendingAction/current` is a singleton document, matching the "one
  active pending interaction" assumption. A gap was found here — creating
  a new pending action calls `.set()` unconditionally, silently
  overwriting an unresolved one — but it's conversation-state-management
  behavior, not an Engine or transaction-truth issue, so it's tracked
  under Future Workflow Improvements (Section 9b), not fixed here. Not an
  Engine bug, not a transaction bug — a separate class of gap the
  migration happened to expose.
- **Does confirmation resolve the correct transaction?** Yes, by explicit
  ID, already correct.

**Verified live**, with a self-inflicted incident worth recording
honestly: a pending Food transaction was created and confirmed through
the actual `/chat` endpoint (not a shortcut) — the confirm loop, the
`TRANSACTION_CONFIRMED` recompute, and the resulting `totalSpent`
(540→560) all fired correctly. The verification script then crashed on an
unrelated Windows console encoding issue (printing an emoji) before its
own cleanup ran. The follow-up cleanup query matched two transactions
with the same amount/category, and a loop variable was overwritten,
causing a **real, pre-existing transaction (2026-07-15) to be briefly
soft-deleted instead of the test one**. This was caught immediately,
fully reverted (`isDeleted: False`, all original fields verified intact),
and is unrelated to the Engine or the Stage 3B code change itself — it was
a bug in the throwaway verification script, not in the product. Full
audit re-run clean afterward.

**Testing hygiene lesson, applied from here on**: the Stage 3B cleanup
mistake happened because a cleanup query searched by *attributes*
(amount + category) instead of the *exact transaction ID* the test itself
created. Every test from Stage 3C onward records the created transaction's
ID at creation time and cleans up using that ID directly — never a
search — exactly the fix the mistake called for.

**Stage 3C complete (2026-07-17)** — chat corrections
(`chat.py`'s `correction` intent). Redesigned from soft-delete-and-relog
to an in-place update, per explicit direction: a correction edits the one
transaction; it never creates a second one. Creating a second transaction
for what is conceptually one edit would change the transaction's id,
breaking audit continuity and any existing reference to "this
transaction" (alerts, chat messages' `relatedTransactionId`).

**A third real, pre-existing bug was found and fixed**: the old code only
relogged a corrected expense if a new category was parsed
(`if new_cat: ...`). An amount-only correction — "no, it was 350," no
category mentioned — hit the `else` branch, which soft-deleted the
original expense and relogged nothing. The money silently vanished from
the user's records. Modifying the transaction in place fixes this as a
natural side effect: there's no longer a code path that depends on a new
category being present to do something useful; amount and category are
now independent optional fields on the same update.

New flow: find the target confirmed transaction → build an update payload
from whichever of amount/category/note actually changed → write it to the
*same* document → `recompute(reason=TRANSACTION_EDITED)`.

**A fourth, unrelated but significant finding**: verifying this stage
required exercising the `correction` intent's Firestore query
(`type`+`status`+`isDeleted`+`createdAt`), which failed with
`FailedPrecondition: The query requires an index`. The needed composite
index was already correctly declared in `backend/firestore.indexes.json`
— it had simply never been deployed to the live project. Since
`undo_last_expense` (Stage 3D) uses the identical query shape, **both
chat intents have likely been erroring for every real user who ever
triggered them, since before this migration began** — a bug entirely
unrelated to the Financial Engine, just uncovered by testing in its
neighborhood. Fixed by deploying the index (`firebase deploy --only
firestore:indexes`, after removing two other declared-but-unnecessary
`messages`-collection index entries Firestore itself rejected as
redundant with automatic single-field indexing). A new minimal
`backend/firebase.json` was added so this deploy path exists going
forward. Confirmed working after the index finished building
(~2 minutes).

**Verified live**, twice — an amount-only correction (Rs 100→115, same
transaction id, `isDeleted: false`, `totalSpent` +15, tagged
`TRANSACTION_EDITED`) and a category-change correction (Food→Transport,
amount unchanged, month `totalSpent` unchanged at 570 while Food's spend
dropped 550→520 and Transport's rose 20→50 — exactly the "money didn't
leave the system, it just moved categories" invariant). Both cleaned up
by exact transaction ID. One further incidental mistake this round: an
orphaned test transaction from the *first* (index-missing) attempt was
left uncleaned while the index issue was being investigated, briefly
inflating `totalSpent` by Rs 100 until caught and removed by its exact ID
before the final audit. Full audit clean afterward.

**Stage 3D complete (2026-07-17)** — chat undo (`undo_last_expense`
intent). Kept deliberately tiny, per the guiding question for this stage:
*"Am I changing financial truth, or only raw transaction data?"* — undo
only ever does the latter. No new "undo transaction" concept, no
duplication: find the target confirmed transaction → soft-delete it
(`isDeleted: true`) → `recompute(reason=TRANSACTION_DELETED)`. The
pre-existing legacy budget decrement was left in place untouched (Option
A), same as every additive stage before it. No new bug found — this
intent's logic was already correctly scoped to "the user decided this
transaction shouldn't exist anymore," nothing more.

Verified live: a Rs 18 Food transaction, undone through the actual
`/chat` endpoint, correctly ended as `isDeleted: true` on the same
document, with `totalSpent` dropping by exactly Rs 18 (558→540) tagged
`TRANSACTION_DELETED`. (A small legacy-counter drift appeared during
verification — an artifact of the test transaction being created
directly in Firestore rather than through a route, so the legacy
increment never fired for it, and the undo's legacy decrement then had
nothing real to net against. Not a Stage 3D bug; fixed by hand.) Full
audit and unit tests clean afterward.

### Chat Transaction Integration Complete

Stages 3A-3D, taken together, form one milestone rather than four
separate deliverables — every way a transaction can become or stop being
financially real *through chat* now flows through the Engine:

- ✅ Create transaction (3A)
- ✅ Confirm pending (3B)
- ✅ Correct transaction (3C)
- ✅ Undo transaction (3D)

Chat is no longer special-cased financial logic — it's one interface
among several (manual form, SMS/notification, chat) that all perform the
same small set of operations against the same transaction lifecycle. What
remains is REST `PUT`/`DELETE /transactions/{id}` — not new logic, just
another interface onto operations already implemented, which is why
they're expected to be smaller than any chat sub-stage was.

**Stage 4A complete (2026-07-17)** — REST Edit (`PUT /transactions/{id}`).
Identical shape to Chat Correction (Stage 3C): update the raw transaction,
then recompute. Recomputes whenever the target is `confirmed` and not
`isDeleted`, regardless of which specific fields changed — even a
description-only edit still recomputes, one consistent rule rather than
guessing which edits "probably" touch money. No pre-existing legacy
`Increment` logic existed in this endpoint to begin with (confirmed by the
original Stage 3 code audit), so nothing needed removing — only the
missing recompute call needed adding.

Verified live, all five cases: amount-only (+50 reflected exactly),
category-only (Food/Transport balances moved, month total unchanged),
amount+category together (both effects composed correctly), description-
only (money unchanged, recompute still ran), and editing an
already-deleted transaction (correctly triggers no recompute, since it
was never a financial change).

**Stage 4B complete (2026-07-17)** — REST Delete
(`DELETE /transactions/{id}`). Identical shape to Chat Undo (Stage 3D):
soft-delete, then recompute — gated on the transaction being `confirmed`
and not already deleted. A repeat delete on an already-deleted
transaction returns `alreadyDeleted: true` with no recompute, matching the
idempotency pattern already established in Stage 2's confirm/reject.

Verified live, all four cases: delete-confirmed (totals decreased
correctly), delete-pending (correctly triggered no recompute — a pending
transaction was never counted), delete-twice (second call was a safe
no-op, no double subtraction), delete-already-deleted (same idempotent
response). Full audit and unit tests clean after both stages.

### Final Phase 1 verification — one financial truth across interfaces

Per the closing request for this phase: not testing each entry point in
isolation, but running the *same* scenario through all of them and
confirming an identical result. Spent Rs 200 on Food, once through each
of manual form, chat, a confirmed notification, and the REST API — each
tried independently against the same baseline, reverted before the next:

| Entry point | Δ totalSpent | Δ Food spent | Δ remainingBudget | Δ savingsPool | Δ goalProgress |
|---|---|---|---|---|---|
| Manual form | +200 | +200 | −60 | 0 | 0 |
| Chat | +200 | +200 | −60 | 0 | 0 |
| Confirmed notification | +200 | +200 | −60 | 0 | 0 |
| REST API | +200 | +200 | −60 | 0 | 0 |

All four rows identical. Reverted cleanly back to the exact baseline
afterward. This is the empirical confirmation of Phase 1's actual goal —
not "the Engine computes correctly," which Phase 1's original scenarios
already proved, but **"every interface that creates the same financial
event produces the same financial truth."**

*Explicitly out of scope for this migration* (future-proofed, not built):
transaction splitting. Nothing in this design forecloses it — a split
simply becomes two confirmed transactions instead of one, and the
sum-from-transactions model handles that with no special-casing, unlike
the increment-based model, which would need bespoke logic to un-increment
one amount and increment two.

**Future-proofing for async recompute** — right now `recompute` runs
synchronously inline in the request. If it ever becomes expensive enough
to move to a background worker, that transition is only easy if routes
already think in terms of two separate steps — `save_raw_data()` then
`trigger_recompute()` — rather than one `calculate_everything_here()`. Not
implemented now; just don't blur the two steps back together while
migrating.

**Acceptance step before Phase 2**: once all five routes are migrated,
declare a one-day feature freeze and use the app like a normal user, not a
developer — create a budget, spend, overspend, use savings, create a goal,
delete a transaction, edit a budget. UX issues surface this way that no
unit test catches. Phase 2 doesn't start until this pass is done.

**The Money Conservation invariant is sacred from here on.** Every future
feature — streaks, an AI coach, unusual-spending detection, health scores,
reports, predictions — must preserve it. If a feature would violate it,
the feature is wrong, not the invariant.

### Phase 1.9 — UI Migration

Backend routes writing raw data and calling `recompute()` (Phase 1.5) is
only half the goal — every screen still calculates its own numbers from
raw Firestore data instead of reading `financialSummary`. Phase 1.9 is
*not* a redesign: no new cards, no new charts, no new colors, no
recommendations. The only change allowed is **which line of code a
number comes from**. Layout, animations, spacing, colors — untouched.

**Success criterion**: if someone asks "where is Remaining Budget
calculated?", there is exactly one answer — *inside the Financial
Engine* — never Home, never Reports, never Categories, never Goals.

**The rule going forward**: a Flutter screen must never contain a
financial formula. `income - spent`, `budget.limit - budget.spent`,
`goal.target - goal.saved` inside a `.dart` file is a bug on sight,
the same severity as `budget.spent += amount` was for the backend
(Section 8's Ground Truth Principle, now extended to the UI layer).

**Prerequisite added**: `GET /financial-summary` (`routes/
financial_summary.py`) — the endpoint the UI actually calls. It didn't
exist before this phase; nothing exposed `get_summary()` to Flutter, only
to other backend routes internally. This is a thin read matching the
Engine's public API (`getSummary`, Section 0) — no calculation happens in
the route itself.

**Not for today, but worth naming**: once Phase 2 (Financial Metrics) and
Phase 4 (Recommendation Engine) exist, `GET /financial-summary` will
naturally want to split into three endpoints with different
responsibilities — `GET /financial-summary` (current state: income,
spent, savings, remaining, goals), `GET /financial-metrics` (analysis:
daily safe spend, burn rate, spending pace, days remaining), and
`GET /financial-insights` (advice: recovery suggestions, "goal at risk,"
praise). Keeping this split in mind now avoids one bloated endpoint later
— not built yet, just flagged so Phase 2+ doesn't reach for the easy
"just add a field to the summary" answer when a new responsibility,
not a new field, is what's actually needed.

**Screen migration table** — updated as each screen moves:

| Screen | Calculates? | Reads Summary? |
|---|---|---|
| Home | ✅ (migrated away) | ☑ |
| Categories | ✅ (migrated away) | ☑ |
| Goals | Already summary-driven (Phase 1.5) | ☑ |
| Reports | Already compliant — no local formulas found | ☑ (nothing to migrate) |
| Chat | ✅ (transaction ops + read-only queries both summary-driven) | ☑ |

**Home — done (2026-07-18).** Every local formula replaced with a direct
`financialSummary` field:

| Before | After |
|---|---|
| `_totalBudgetLimit - _totalBudgetSpent` (`_unusedBudget`) | `summary['remainingBudget']` |
| `_incomeForCard - _totalBudgetLimit` (`_pureSavings`) | `summary['savingsPool']` |
| `/income` fetch + fallback (`_declaredIncome`) | `summary['income']` |
| `_budgets.fold(...)` for spent (`_totalBudgetSpent`) | `summary['totalSpent']` |
| Per-category `spent` from a separate `/budgets` fetch | `summary['categoryRemaining'][category]['spent']` |

`_fetchBudgets()` and `_fetchIncome()` were removed entirely — replaced by
one `_fetchFinancialSummary()` call. `_totalBudgetLimit` (used only for
the health-status color threshold, which the Engine doesn't expose as a
flag yet — that's Phase 3) now sums the already-Engine-given per-category
`limit` values from `categoryRemaining` rather than folding a separately-
fetched budgets list — aggregating raw per-category data the Engine
already reports, not re-deriving a new formula. `_isOverAllocatedBudget`
is the one honest exception left: the Engine doesn't yet expose an
"over budget" boolean, so this screen still compares two
already-summary-sourced totals until Phase 3 (Health & Risk Engine) adds
that flag directly. What's deliberately untouched: `_totalExpense`,
`_todayTotalExpense`, `_categoryBreakdown` — these come from the weekly
Reports endpoint, a different (not-yet-Engine-computed) concern, not
Budget/Savings math.

Verified: `flutter analyze` clean (zero issues), and the app builds and
boots successfully in Chrome (Dart VM Service came up, no compile or
runtime errors). Full visual confirmation of the displayed numbers in the
running UI was not done this pass — no browser-driving tool was set up in
this environment, and reaching the Home screen requires signing in first.
The backend endpoint itself was independently verified against the real
account and returns the exact expected shape (see the live test above).

**Categories — done (2026-07-18).** Two files, same feature area, both
migrated: `categories_screen.dart` (the grid/list) and
`category_detail_page.dart` (opened by tapping a category — found to have
its own independent, near-identical duplicate of the same "available"
formula, migrated too since leaving it would have defeated the point).

`categories_screen.dart`:

| Before | After |
|---|---|
| `_totalSpent = _budgets.fold(...)` | `summary['totalSpent']` |
| `_totalBuffer = fold((limit-spent).clamp(0,inf))` per category | `fold(categoryRemaining[cat]['remaining'])` — the Engine already computed this per category, just summed |
| `_netSavings` (income>0 ? income−totalSpent : limit−totalSpent) | `savingsPool + remainingBudget` — proven algebraically identical, now a sum of two Engine fields with zero local subtraction |
| `available = (income−totalLimit).clamp(0,inf) + totalBuffer` (add-category dialog) | `savingsPool + totalBuffer` — `income−totalLimit` clamped *is* `savingsPool` by definition |
| Separate `/budgets` + `/income` fetches | One `/financial-summary` fetch; `_budgets` list rebuilt from `categoryRemaining` entries so every existing renderer (`_buildBucketCard`, `_buildDisplayList`) kept its exact map shape and needed zero changes |

`_fetchBudgets()`/`_fetchIncome()` deleted, replaced by
`_fetchFinancialSummary()` (9 call sites renamed). `_totalLimit` stays a
local sum of Engine-given per-category limits (same treatment as Home),
feeding `_spentPercent` — a presentation-only ratio explicitly left local
per the "trivial UI percentage, note it for later" exception; it belongs
in the Engine once Phase 3 adds a health/percentage field directly.

`category_detail_page.dart`: same treatment, with one deliberate
carefulness — the original `available` formula only clamped *once*, at
the very end (`income − totalAllocated + thisBudgetLimit + otherBuffer`),
not per-term. Substituting the pre-clamped `savingsPool` for
`income − totalAllocated` would silently change behavior in the
(abnormal but possible) globally-over-allocated case. Rather than risk
that edge case, the exact original formula shape was kept — only its four
inputs (`_declaredIncome`, `_totalAllocated`, `_otherUnspentBuffer`,
`_budgetLimit`) now come from one `/financial-summary` call instead of a
hand-rolled loop over separately-fetched `/income` + `/budgets`.
`_computeStatus()` (ok/warning/overspent/low thresholds) is health logic
— left untouched, Phase 3 territory, same as `_isOverAllocatedBudget` on
Home.

Verified against the three questions before moving on:
- **Does Categories make only one financial request?** Yes, per screen.
- **Does Categories calculate any financial numbers?** No, except the two
  explicitly-noted presentation-only percentages/thresholds deferred to
  Phase 3.
- **If the Engine changes tomorrow, would this screen still work without
  modifying its formulas?** Yes — every money value is a direct field
  read; only the two deferred ratios would need a follow-up once the
  Engine exposes them directly.

`flutter analyze` clean on both files (zero issues, only pre-existing
`const`-constructor lint hints). App rebuilt and booted successfully in
Chrome a second time after these changes — same verification depth and
limits as Home (compiles and boots; full visual confirmation of rendered
numbers not done, no browser-driving tool available).

**Reports — audited, no migration needed (2026-07-18).**
`reports_screen.dart` was searched for the same terms (`fold(`, `reduce(`,
`.where(`, `remaining`, `spent`, `calculate`) and found already compliant:
`totalExpense`, `categoryBreakdown`, `dailyBreakdown`, and `overallStatus`
all come pre-computed from `/monthly-report`; goal fields (`savedSoFar`,
`percentComplete`) come pre-computed from `/goals` (already Engine-backed
since Phase 1.5). The one local aggregation — `_headlineAmount` summing
already-fetched daily category breakdowns for a filtered headline number
— is presentation-layer reshaping of already-computed data, not a
re-derivation of financial truth, matching the explicit exception for
"organizing data for visualization." `adaptive_report_chart.dart`'s only
`reduce(` is finding the chart's max Y-axis value for padding — pure
chart-scaling math, not financial. No code changes made; nothing to
migrate.

**A real, concrete finding surfaced by this audit, deliberately not
fixed**: `routes/reports.py`'s `/monthly-report` computes its own
**third, independent implementation** of "overall spending health,"
structurally different from Home's local check:

| Implementation | Location | Logic |
|---|---|---|
| Home's `_updateFinancialStatus` | Flutter, `home_screen.dart` | Aggregate: total spent > total limit → overspent |
| Categories' `_computeStatus`/`_spentPercent` | Flutter, `category_detail_page.dart` | Per-category ratio thresholds |
| Reports' `overall_status` | Backend, `routes/reports.py` | Per-category: **any** category over its own limit → overspent (different condition than Home's aggregate check), plus additional "low"/"exact" states neither Flutter version has |

These three don't just duplicate effort — they can genuinely disagree on
the same data, since "any one category overspent" and "aggregate spent
exceeds aggregate limit" are different conditions. This is exactly why
Phase 3 (Health & Risk Engine) exists: to replace all three with one
canonical `summary['health']` field. Not fixed now — doing so would mean
building Health logic mid-Phase-1.9, which was explicitly out of scope
this phase. Documented here so it isn't lost before Phase 3 starts.

**Chat read-only queries — done (2026-07-18).** Not transaction creation
(already migrated in Stages 3A-3D) — this is the "how much money do I
have left?" style questions. Migrated in both of `chat.py`'s duplicated
endpoint blocks (four call sites total for some intents):

| Intent | Before | After |
|---|---|---|
| `query_month_total` | `sum_month_expense()` — independent re-scan of the month's transactions | `summary['totalSpent']` |
| `query_category_spend` | `sum_category_expense()` — independent re-scan for one category | `summary['categoryRemaining'][cat]['spent']` |
| `query_budget_status` | `fetch_budget()` — **the raw stored `budgets.spent` field, the deprecated mutable counter** | `summary['categoryRemaining'][cat]` (`limit`/`spent`/`remaining`) |
| `query_report` (monthly branch) / `query_past_report` | Manual loop over `transactions`, summing expense + category totals from scratch | `summary['totalSpent']` / `summary['categoryRemaining']` for the expense side |
| `query_top_spend_category` / `query_spend_feedback` | `report_service.py` independently re-queried and re-summed transactions by category | `report_service.py` now reads `get_summary()`'s `categoryRemaining` — one file change, fixes all four chat.py call sites at once |

**A real bug, not just duplication**: `query_budget_status` was reading
`fetch_budget()`'s raw `budgets.spent` — the same deprecated counter
proven to drift in Stages 1-3D. A user asking "what's my Food budget
status?" via chat could have received a stale number. Verified live:
the migrated reply (`Food budget Rs 520, spent Rs 520, baki Rs 0
(100.0%)`) matches the Engine's `categoryRemaining['Food']` exactly.

**A `report_service.py` docstring even documented the same bug it was
working around**: `get_spend_alerts`'s old comment read *"we use
sum_category_expense to be accurate vs b_data.get('spent') which might
be slightly out of sync"* — acknowledging the drift without fixing the
root cause. Now both its functions read the summary directly; there's
nothing left to be out of sync with.

**Deliberately not migrated**: the `daily`/`weekly` branches of
`query_report` (date-range-scoped, not month-scoped — the Engine doesn't
compute these yet, Phase 2/Metrics territory, same reasoning as Reports'
`dailyBreakdown`). Also deliberately preserved: `r_income` in every
report reply stays a sum of logged income **transactions** — a different
concept from the Engine's `summary['income']` (declared income used for
budget planning) — conflating the two would have silently changed what
the reply means, not just where the number comes from.

`get_missing_budget_categories` was left untouched — it checks category
*existence*, not a financial total, so it isn't in scope for this
migration.

Verified: compiles clean, full unit test suite and real-account audit
pass, and both migrated functions tested live against
`botbachat@gmail.com` — `query_budget_status`'s reply matches the Engine
exactly, and `get_top_spending_category`/`get_spend_alerts` return
correct values.

### Financial Formula Elimination — Phase 1.9 acceptance criterion

Before calling Phase 1.9 done, the whole Flutter project (`frontend/lib`)
was searched for: `income -`, `budget.spent`, `budget.limit`,
`goal.target`, `goal.saved`, `remaining =`, `spent =`. Every hit was
individually classified:

- **False positives** — field reads that happen to contain the search
  substring (`goal.targetAmount`, `goal.savedSoFar`, `item['spent']`,
  a password-length countdown unrelated to money) — not formulas.
- **One genuine, structural exception, intentionally kept**:
  `category_budget_onboarding_screen.dart`'s `_remaining = totalIncome -
  totalBudgeted`. This computes a live preview *while the user is still
  composing budgets during onboarding, before anything is saved* — there
  is no `financialSummary` to read yet, because the income/budgets don't
  exist in Firestore until the user finishes and submits. This is not the
  same violation as the others (duplicating math on already-persisted
  data); it's a form showing a running total of its own unsaved input,
  which has no other possible source. Documented here explicitly rather
  than silently exempted.

No other financial formula remains anywhere in the Flutter project.
**Phase 1.9 is complete**: Home, Categories, Goals, Reports, and Chat
queries all read from `financialSummary` (or, for Reports/Goals, from
endpoints that themselves already read from it); the one remaining
exception is named and justified, not overlooked.

Each phase ships and is verified before the next starts — phase N+1 always
assumes phase N's numbers are already trustworthy.

---

## Financial Engine Complete — v1.0 Milestone

Everything above (Phases 0, 1, 1.5, 1.9) is frozen as of 2026-07-18. This
section exists so that Phase 2 (Metrics), Phase 3 (Health), Phase 4
(Recommendations), and Phase 5 (Notifications) build **on top of** this
platform without changing its core behavior — a checkpoint to diff future
work against, not new content of its own.

### Final architecture diagram

```
User Action
    │
    ▼
Raw Data Stored          (income, budgets, transactions, goals)
    │
    ▼
Financial Engine         (recompute)
    │
    ▼
Financial Summary         (financialSummary/{monthKey})
    │
    ▼
Everything Else          (Home, Categories, Goals, Reports, Chat,
                           Notifications, Health, Recommendations)
```

All four entry points that create the same financial event write through
the same raw-data layer and are provably indistinguishable to everything
downstream (see "Final Phase 1 verification" above — identical deltas
across all four):

```
Manual form   ──┐
Chat          ──┼── writes raw data ──► recompute() ──► financialSummary
Notification/SMS ┤
REST API      ──┘
```

```
Chatbot              ──┐
Home / Categories    ──┤
Goals / Reports       ──┼── getSummary(userId, monthKey) ──► all calculated fields
GET /financial-summary ┘
```

### Engine API (frozen — Section 0)

Four public operations, nothing else. No consumer calls a private helper
or gets a dedicated method for a feature-specific output (health, alerts,
recommendations) — those live inside the one summary document.

- `recompute(userId, monthKey)` — the only operation allowed to write
  `financialSummary`.
- `getSummary(userId, monthKey)` — the only way anything reads calculated
  values; self-heals via an internal recompute if the summary is missing.
- `simulateTransaction(userId, transaction)` — hypothetical impact, writes
  nothing.
- `validateTransaction(userId, transaction)` — lightweight afford-check,
  no full simulation.

### Summary schema (actual v1.0 shape — not Section 5's future aspiration)

```
financialSummary/{monthKey}
├── income
├── totalSpent
├── remainingBudget
├── categoryRemaining     (per category: limit, spent, remaining)
├── savingsPool
├── goalProgress          (per goal: id, name, priority, targetAmount,
│                          timeframeMonths, saved, savedSoFar, remaining,
│                          percent, percentComplete, monthlyTarget, status)
├── rebalanceResult       ({"moved": []} — pass-through, not yet populated)
├── metadata
│   ├── version           (summary schema version)
│   ├── engineVersion      (Engine code version)
│   ├── recomputeId        (unique per run)
│   ├── reason             (RecomputeReason constant)
│   ├── durationMs
│   ├── recomputedAt
│   └── decisionLog
└── lastUpdated
```

`health`, `risk`, `streaks`, `reasonCodes`, `notifications` (Section 5) do
**not** exist yet — those are Phase 3/4/5's job to add to this same
document, never a new document or a new method.

### Invariants (Section 7 — unchanged, still absolute)

Money Conservation · No Negative Budgets · Single Source of Truth ·
Deterministic Engine · Idempotence · Order Independence · Confirmed Means
Persisted · Exactly-Once Recompute. Every future phase is checked against
these before it ships; a failing invariant is an Engine bug regardless of
which feature triggered it.

### Route migration table (backend — Phase 1.5)

| Route | Writes raw data only | Calls `recompute()` | Old calc logic removed | Verified live |
|---|---|---|---|---|
| Budgets | ✅ | ✅ | ❌ (rebalance-plan block still computes inline, additive only — deferred with Goals'/Transactions' shared cleanup) | ✅ |
| Income | ✅ | ✅ | ✅ (nothing to remove — clean from the start) | ✅ |
| Goals | ✅ | ✅ | ✅ (`_with_computed_fields` deleted, replaced by zero-math `_merge_engine_fields`) | ✅ (full create/edit/rename/delete lifecycle) |
| Transactions | ✅ (all 5 write paths call `recompute()`) | ✅ | ❌ (8 legacy `Increment()` call sites still present, now inert — Engine ignores `budgets.spent` entirely) | ✅ (Stages 1, 2, 3A-3D, 4A, 4B) |
| Chat | ✅ (transaction ops + read-only queries) | ✅ | ✅ (both duplicated endpoint blocks migrated; `report_service.py` rewritten) | ✅ |

### UI migration table (Phase 1.9)

| Screen | Local formulas found | Migrated | Verified |
|---|---|---|---|
| Home | 5 (`_unusedBudget`, `_pureSavings`, `_declaredIncome`, `_totalBudgetSpent`, per-category spent) | ✅ | `flutter analyze` clean, boots in Chrome |
| Categories | 4 (`_totalSpent`, `_totalBuffer`, `_netSavings`, add-category `available`) across 2 files | ✅ | `flutter analyze` clean, boots in Chrome |
| Goals | Already summary-driven since Phase 1.5 | ✅ | Live lifecycle test |
| Reports | None found — already compliant | N/A | Audited, zero changes |
| Chat | 5 query intents (`query_month_total`, `query_category_spend`, `query_budget_status`, `query_report`, `query_past_report`) + `report_service.py` | ✅ | Live reply matched Engine exactly |

Full visual confirmation of rendered numbers in a signed-in browser session
was **not** done for Home/Categories — only compile (`flutter analyze`)
and boot (Dart VM Service up, no runtime errors) were verified, since no
browser-driving tool was available in this environment. The backend
endpoint each screen calls was independently verified against the real
account.

### Known intentional exceptions (named, not overlooked)

- **`category_budget_onboarding_screen.dart`'s `_remaining = totalIncome -
  totalBudgeted`** — permanent, structural. A live preview of unsaved
  onboarding input; there is no `financialSummary` to read yet because
  nothing has been persisted.
- **Presentation-only ratios/thresholds** — `_spentPercent`
  (categories_screen.dart), `_computeStatus` (category_detail_page.dart),
  `_isOverAllocatedBudget` (home_screen.dart) — all compare or reshape
  already-summary-sourced values; temporary, Phase 3 (Health & Risk Engine)
  removes them by adding a `health`/percentage field directly to the
  summary.
- **Three duplicate health-status implementations** (Home's
  `_updateFinancialStatus`, Categories' `_computeStatus`, Reports'
  `overall_status`) — genuinely disagree on the same data today; explicitly
  Phase 3's job to unify into one canonical `summary['health']`.
- **8 legacy `Increment()` call sites on `budgets.spent`** — inert (the
  Engine never reads `budgets.spent`), safe to delete, not yet done.
  Deferred so Transactions and Chat's duplicated waterfall/rebalance logic
  is deleted everywhere at once rather than piecemeal.
- **Budgets' inline rebalance-plan block** (`create_or_update_budget`) and
  `budget_service.py`'s `_compute_rebalance_transfers` — still compute a
  rebalance plan directly rather than reading it from `rebalanceResult`;
  deferred with the `Increment()` cleanup above.
- **Orphaned pending chat transaction** (Section 9b) — a known UX gap, not
  a financial-correctness bug; not addressed by this migration.

### Acceptance criteria

1. **Phase 1's Definition of Correct** — the four test scenarios (clean
   state, normal spend, overspend-with-buffer, overspend-exhausted) produce
   exact expected numbers, not just "the code runs."
2. **Cross-entry-point identity** — manual form, chat, confirmed
   notification, and REST API each produce byte-identical deltas
   (`totalSpent`, category spent, `remainingBudget`, `savingsPool`,
   `goalProgress`) for the same event.
3. **Financial Formula Elimination** — zero financial formulas remain
   anywhere in `frontend/lib` except the one named structural exception.
4. **Single Source of Truth in practice** — every screen's numbers trace
   back to exactly one `GET /financial-summary` call per screen, not a
   scatter of independent fetches.

All four hold as of 2026-07-18.

### Test coverage summary

- **`backend/tests/test_financial_engine.py`** — unit tests for the four
  Phase 1 scenarios, mutation reversibility, and determinism.
- **`backend/scripts/audit_financial_engine.py`** — real-account audit
  (`botbachat@gmail.com`) run after every stage: overall totals, every
  category, every goal, determinism, mutation-reversibility, rebalance
  priority order, simulated-vs-committed rebalance.
- **Live ad-hoc verification** — every migrated route/screen/chat intent
  was additionally tested against the real account with before/after
  diffs, not just unit-tested: Budgets, Income, Goals (full lifecycle),
  Transactions (Stages 1, 2, 3A-3D, 4A, 4B), Chat (transaction ops +
  5 query intents), Home, Categories.
- **Frontend** — `dart analyze` clean on every touched file; Home and
  Categories additionally boot-tested in Chrome via a real Flutter web
  build (compile + runtime boot confirmed, full visual confirmation not
  done — no browser-driving tool available).
- **5 real, pre-existing production bugs** found and fixed during
  migration (Section 9), plus 2 user-reported bugs (chat-correction
  refresh trigger, income-notification category question) found and
  fixed during UAT — the migration's correctness evidence, not just proof
  the code moved.

**From here, Phase 2 (Financial Metrics) starts.** It adds fields to this
same summary document — it does not change the Public API, the route
migration pattern, or any invariant above.

---

## Phase 2.0 — Metrics Design (no code — design only)

Before any metric is implemented, it must survive one question:

> **Can this metric ever lie to the user?**

If yes: either improve it until it can't, or don't build it. This section
is that design pass. Nothing in it is implemented yet.

**Purpose statement, the top-level filter for everything below:**

> The purpose of the Metrics Engine is not to describe the user's
> finances, but to help them make better spending decisions using
> trustworthy, explainable metrics.

Two words carry all the weight: **trustworthy** and **explainable**. A
metric that can't be explained back to the user in one sentence tracing to
`financialSummary` doesn't ship.

And the actual product question, which every metric must serve —
Phase 2 is not "generate statistics," it exists only to answer:

> "How do I help a student survive the month without running out of
> money?"

### Why this is harder than it looks — the logging-vs-spending gap

The Engine knows *when a transaction was logged*, never *when the money
was actually spent*. Every metric below inherits this gap, and it can
make a metric actively lie, not just be imprecise:

- **Forgotten logging** — a day with unlogged spending looks artificially
  cheap; a Safe-Spend number computed against it is optimistic, not
  accurate.
- **Batched logging** — three quiet days followed by one day of catch-up
  logging makes day 4 look like a spike in any per-day chart, when the
  real pattern was flat.
- **Deliberate non-logging** — a user who skips logging expensive
  purchases makes every downstream prediction look better than reality,
  silently.
- **Same-day multiple transactions** — must sum, not overwrite; four
  purchases of 150+100+50+300 today is a 600 day, not a 300 day (whichever
  was logged last).

None of this is solvable by better math — it's solvable by **naming the
assumption** (transactions are logged promptly and honestly) and lowering
**confidence** when there's reason to believe the assumption is strained,
rather than presenting every metric with the same false authority.

### The ladder — every metric is exactly one of these five, never blurred

```
Facts          — 100% true, direct from financialSummary, never predicted
    ↓
Calculations   — mathematically true given the facts (e.g. a ratio)
    ↓
Guidance       — a recommendation, not a fact ("suggested" framing required)
    ↓
Predictions    — assume current behavior continues; explicitly a forecast
    ↓
Coaching       — advice/tone layer on top of the above
```

| Level | Examples | Can it be "wrong"? |
|---|---|---|
| **Facts** | Remaining Budget, Savings Pool, Category Remaining, Total Spent, Income, Days Remaining | No — these already exist in `financialSummary` |
| **Calculations** | Budget Utilization (`spent / limit`) | No — pure math on facts, still trustworthy |
| **Guidance** | Recommended Daily Spend, Suggested Weekly Limit | Yes — must be worded as a suggestion, never a guarantee |
| **Predictions** | Projected Savings, Expected Overspend, End-of-month Balance | Yes — assumes current behavior continues; a forecast, not a fact |
| **Coaching** | "Spend Rs 150 less for 3 days," "You're recovering well" | Yes — advice, tone matters as much as the number |

A UI label or chat reply must never present a Level 3+ value with Level 1
authority. This is why **"Safe Spending" is being renamed** — it phrases a
guidance-level number as a guaranteed fact. Candidates: **Today's
Spending Guide**, **Suggested Daily Budget**, **Recommended Daily Spend**.
Wording carries real weight: "Safe to spend: Rs 450" (a guarantee) versus
"Based on your current records, you can spend about Rs 450 today" (an
honest estimate) are the same number with a different, more honest claim
attached.

### App philosophy — what BachatBot actually believes (write it down once, design every metric against it)

1. **Savings should never be touched first.** Already implemented (Money
   Priority Rule, Section 1) — the Waterfall exhausts own-category then
   other-category buffer before touching the Savings Pool.
2. **Overspending one day is okay. Continuing to overspend is the
   problem.** A single bad day is not a crisis; a metric that treats it
   as one (streaks, alerts) is designed wrong.
3. **The app encourages recovery, not punishment.** Never "You
   overspent." Always something like "You spent Rs 250 extra today.
   Spending about Rs 80 less over the next 3 days will bring you back on
   track."
4. **One expensive purchase isn't automatically bad.** A laptop, exam fee,
   or medicine shouldn't trip the same alert as reckless discretionary
   spending — context (category, frequency, history) matters, amount
   alone never triggers a judgment.
5. **Recommendations must always explain themselves.** Never "Spend
   less." Always something traceable: "Food budget has Rs 900 left with
   10 days remaining. Keeping meals around Rs 90/day will help you finish
   the month comfortably."

### Per-metric assumption table

The discipline for every metric before it's built — if a row can't be
filled in honestly, the metric isn't ready:

| Metric | What it answers | Assumptions | Can it be wrong? | Confidence |
|---|---|---|---|---|
| Days Remaining | How many days are left this month? | Server clock/date is correct | No | Always high (a calendar fact) |
| Budget Utilization | How much of each category is used? | Categories are assigned correctly | Rarely | High |
| Spending Pace | Am I ahead of or behind budget for how far the month has gone? | Transaction dates are accurate | Yes | Medium |
| Recommended Daily Spend | How much can I spend today (per remaining budget/days)? | Expenses are logged promptly and honestly | Yes | High if logging is regular, drops otherwise |
| Recovery Plan | How much less should I spend to get back on track? | Same as above, plus that the user wants to recover, not just informed | Yes | Medium |
| Category Pressure | Is this category's usage risky given time left? | Same logging assumption; category assignment is correct | Yes | Medium |
| Savings Stability | Will the Savings Pool survive if this pace continues? | Current pace continues (a prediction, explicitly) | Yes | Medium |
| Projected Savings (future, Level 4) | How much will I save by month-end? | Current behavior continues unchanged | Yes | Medium |
| Unusual Spending (deferred, not Phase 2) | Is this transaction abnormal? | Needs category + weekday + history + frequency + timing, not amount alone — a single Rs 4000 grocery run may be a normal monthly pattern, not an anomaly | Yes, badly, if amount is used alone | Low until history/baseline exists |
| Healthy Spending Streak (deferred, not Phase 2) | Was today a "healthy" day? | No agreed definition yet — see below | Yes | Not buildable yet |

**Why Healthy Spending Streak isn't Phase 2 material — the definition
itself doesn't exist yet:**

- Option A, "didn't exceed today's allowance" — fails for a user who
  intentionally front-loads a planned monthly grocery run.
- Option B, "stayed inside category budgets" — fails because one large
  *planned* expense can still be a perfectly healthy day.
- Option C, "didn't require the Savings Pool" — the closest fit, because
  it matches Rule 1 above (Savings is the last resort) rather than an
  arbitrary daily-average threshold. Still not defined precisely enough
  to build; flagged for whenever Streaks is actually scheduled, not now.

### Metrics to build, in order — and why this order

Seven metrics, not twenty. Each depends only on `financialSummary` (Facts)
or on metrics already built earlier in this same list — never on
something not yet defined:

1. **Days Remaining** — simplest possible metric; every other metric in
   this list depends on it.
2. **Budget Utilization** (`spent / limit` per category) — pure math on
   facts already in `categoryRemaining`.
3. **Spending Pace** — not just "73% of budget used," but that number
   *against* how much of the month has elapsed ("73% used, 50% of month
   passed" is meaningfully different information than either number
   alone — it's the first metric that answers "ahead or behind," not
   just "how much").
4. **Recommended Daily Spend** — deliberately **not** `remainingBudget /
   daysRemaining` (ignores category structure); computed as **remaining
   category budgets ÷ remaining days**, because categories matter and a
   single pooled number can recommend spending that's fine in aggregate
   but impossible within any one category.
5. **Recovery Plan** — when actual spend exceeds the recommended pace,
   compute the shortfall spread across remaining days ("spend about
   Rs 35 less each day for the next week") instead of a pass/fail
   judgment. This is the concrete implementation of Philosophy Rule 3.
6. **Category Pressure** — combines Budget Utilization *and* Days
   Remaining for that category, because 80% used with 2 days left is
   fine and 80% used with 20 days left is risky — utilization alone
   can't distinguish these, only utilization-over-time can.
7. **Savings Stability** — not "how much savings exists" (that's already
   a Fact — `savingsPool`), but "if this pace continues, does it
   survive?" — the first metric that's explicitly a Level 4 Prediction
   and must be worded as one.

**Deliberately not building this phase** (each needs a prerequisite this
phase doesn't yet have):
- ❌ **Streaks** — no agreed definition of a "healthy day" yet (see above).
- ❌ **Unusual Spending** — needs a spending history/baseline, which
  doesn't exist yet; amount-alone detection is provably wrong (the
  Rs 4000 monthly-groceries example).
- ❌ **AI Suggestions / Coaching text generation** — needs the metrics
  (Level 1-4) to exist first; coaching is Level 5, built last, on top.
- ❌ **Health Colors** — same reason; Phase 3's job, needs metrics as
  input.

### Deliverable shape (design only — not the literal field names yet)

```
Financial Summary                    (existing — Facts)
├── Remaining Budget
├── Savings Pool
├── Category Remaining
├── Income
└── Goal Progress
        │
        ▼
Financial Metrics                    (new — Phase 2 implementation)
├── Days Remaining
├── Budget Utilization
├── Spending Pace
├── Recommended Daily Spend
├── Recovery Plan
├── Category Pressure
└── Savings Stability
```

Every entry in Financial Metrics must be traceable back to Financial
Summary in one sentence a chatbot reply could say out loud — e.g. "You
have Rs 2,640 left across your budgets and 12 days remaining, so a
recommended spend of about Rs 220/day." No black-box numbers. This is the
acceptance bar for Phase 2 implementation, once it starts: not "the math
is correct" alone, but "every number can explain itself using only facts
already in `financialSummary`."

### Metrics never modify money

**Metrics can only read.** The Metrics Engine consumes `financialSummary`
and produces interpretations of it — it never writes to `financialSummary`,
never calls anything that changes budgets, transactions, goals, or income,
and never triggers a `recompute()` itself. Only the Financial Engine
changes financial state (Section 0's Public API is still the only writer
in the entire system).

```
Metrics Engine
    │
    ▼
Suggest                    (e.g. "spend Rs 35 less/day this week")
    │
    ▼
User confirms / acts       (a real decision, made by the user)
    │
    ▼
Financial Engine changes state     (via a normal raw-data write + recompute,
                                     same as every other route)
```

What must never happen: `Metrics Engine → Reduce Savings` or any other
direct mutation. If a future feature (Recommendation Engine, Notification
Engine) ever wants to *act* rather than *suggest*, that action still goes
through a normal user-facing confirmation and a normal Engine write — it
does not get a shortcut because it originated from a metric. This is the
Product Philosophy statement (top of this document) applied specifically
to Phase 2 and beyond.

### Evidence-based confidence

Confidence is not a vibe — it names the evidence a number rests on, so a
user (or a future developer) can see *why* a metric should or shouldn't be
trusted, not just that it carries a label:

| Confidence | Meaning |
|---|---|
| **High** | Based entirely on confirmed financial records — no assumption about future or unlogged behavior. |
| **Medium** | Assumes transactions are logged reasonably promptly; accurate if the user logs regularly, degrades if they batch-log or skip days. |
| **Low** | Depends on user behavior continuing unchanged, or on incomplete/short history — genuinely a forecast, not a read of the past. |

### Metric scope — Global vs. Per Category

Every metric states, once, whether it produces a single value for the
month or one value per category. Mixing this up is how an endpoint ends
up with an ambiguous shape (a number that's sometimes global, sometimes
keyed by category, depending on which metric you ask for):

| Metric | Scope |
|---|---|
| Days Remaining | Global |
| Budget Utilization | Per Category |
| Recommended Daily Spend | Global |
| Spending Pace | Global |
| Recovery Plan | Global |
| Category Pressure | Per Category |
| Projected Savings | Global |

This is also a routing signal for later phases, not just a data-shape
note: Home mostly displays Global metrics, Categories displays Per
Category metrics, Reports displays both, and Chat can be asked either
kind of question ("how much can I spend today" vs. "how much of my Food
budget is used").

### Metric type — Descriptive, Analytical, Advisory, Predictive

Every metric also states, once, which of four kinds it is. This is
distinct from the Ladder (Facts→Calculations→Guidance→Predictions→
Coaching, Phase 2.0's original design) — the Ladder says how much
certainty a number carries; Metric Type says what *job* the number is
doing for the user:

| Metric | Type |
|---|---|
| Days Remaining | Descriptive |
| Budget Utilization | Descriptive |
| Spending Pace | Analytical |
| Recommended Daily Spend | Advisory |
| Recovery Plan | Advisory |
| Category Pressure | Analytical |
| Projected Savings | Predictive |

- **Descriptive** — tells the user what *is*. No interpretation.
- **Analytical** — explains what a set of facts *means* (e.g. ahead of
  or behind pace).
- **Advisory** — suggests what to *do*. Must be worded as a suggestion,
  never a permission or a guarantee, and is held to one extra acceptance
  criterion (below): it must never contradict the product philosophy.
- **Predictive** — estimates what *may happen* if current behavior
  continues.

Any metric classified **Advisory** carries the same worded-as-guidance
requirement the Ladder already established for Level 3 ("Guidance") —
this table exists so that requirement is checked explicitly per metric,
not left implicit.

**Consumption tree — who reads which type, later phases:**

```
Descriptive + Analytical + Advisory + Predictive
    │
    ▼
Health Engine (Phase 3)            consumes ALL of them
    │
    ▼
Recommendation Engine (Phase 4)    consumes Advisory + Predictive
    │
    ▼
Notification Engine (Phase 5)      consumes Health + Recovery Plan (Advisory)
    │
    ▼
Chatbot (Phase 6)                  consumes everything
```

This is why the type classification matters beyond bookkeeping: it's the
actual routing table for which future engine is allowed to depend on
which metric. Health needing a Descriptive fact it wasn't given, or
Notifications reaching past Health straight into raw Descriptive metrics,
would be a violation of this tree the same way a UI screen reaching past
`financialSummary` back into raw Firestore data was a Phase 1.9
violation.

### API shape — per-category metrics must grow without breaking clients

A Global metric is a bare field: `"daysRemaining": 14`. A Per Category
metric is **never** a bare number keyed by category (`"Food": 60`) —
it's an object per category, even when only one field exists today:

```
"budgetUtilization": {
  "Food": { "utilization": 60.0 }
}
```

not

```
"budgetUtilization": {
  "Food": 60.0
}
```

The reason is the same one that shaped `financialSummary`'s
`categoryRemaining` from the start: a later phase (Category Pressure,
Phase 2.6; Health, Phase 3) adds a sibling field to the same per-category
object —

```
"budgetUtilization": {
  "Food": { "utilization": 60.0, "pressure": "medium", "health": "ok" }
}
```

— without ever changing the shape a client already parses, only adding a
key it can choose to ignore. A bare number keyed by category cannot grow
this way without becoming a breaking change.

### Metrics Engine metadata and versioning

The Metrics Engine gets its own version, independent of
`financial_engine.py`'s `ENGINE_VERSION` — the same discipline already
applied there (Section 4), so that "which version of the Metrics Engine
produced this response" is always answerable months from now, the same
way `recomputeId`/`engineVersion` already answer it for `financialSummary`:

```python
METRICS_ENGINE_VERSION = 1
```

Every `/financial-metrics` response carries:

```
"metadata": {
  "metricsEngineVersion": 1,
  "monthKey": "2026-07",
  "generatedAt": "2026-07-18T12:23:03+00:00",
  "generationMs": 8
}
```

Unlike `financialSummary`'s `metadata`, there's no `recomputeId` or
`reason` here — Metrics Engine calls aren't recomputes, they're pure
reads computed fresh on every request (Days Remaining's own design
already established this: nothing is stored, nothing needs a reason code
for why it changed). `generatedAt`/`generationMs` exist purely so a slow
or stale-looking response is traceable later, the same motivation
`durationMs` served for the Financial Engine.

### Per-metric lifecycle — the contract every metric must satisfy before it's built

Every metric answers these nine questions before a line of Phase 2 code is
written. A metric with a blank row isn't ready.

**1. Days Remaining**

| Question | Answer |
|---|---|
| What question does it answer? | How many days are left in the current month? |
| Input data | Current date, month key |
| Output | `daysRemaining` (integer) |
| Type | Fact |
| Confidence | High — a calendar fact, no assumption involved |
| Update trigger | Recomputed daily (date change), not tied to a financial event |
| Where used | Home, Recommended Daily Spend, Recovery Plan, Category Pressure |
| Can it trigger alerts? | No |
| Can it trigger coaching? | No |

**2. Budget Utilization**

| Question | Answer |
|---|---|
| What question does it answer? | How much of each category's budget has already been used? |
| Input data | `categoryRemaining[cat].limit`, `categoryRemaining[cat].spent` |
| Output | `budgetUtilization[cat]` (percent, e.g. Food 72%) |
| Type | Calculation |
| Confidence | High — pure math on confirmed facts |
| Update trigger | Every `recompute()` (same trigger the Engine already uses) |
| Where used | Reports, Chat, Health Engine (Phase 3), Category Pressure |
| Can it trigger alerts? | No (Health Engine may build an alert on top of it later — this metric itself doesn't) |
| Can it trigger coaching? | No |

**3. Spending Pace**

| Question | Answer |
|---|---|
| What question does it answer? | Am I ahead of or behind budget for how far the month has gone? |
| Input data | Budget Utilization (per category and/or overall), `daysRemaining`, total days in month |
| Output | `spendingPace` (e.g. "73% used, 50% of month passed" → ahead/behind) |
| Type | Calculation |
| Confidence | Medium — depends on transaction dates being accurate, not just amounts |
| Update trigger | Every `recompute()` |
| Where used | Home, Reports, Chat, Recovery Plan |
| Can it trigger alerts? | No |
| Can it trigger coaching? | Yes — feeds the wording of a pace-based nudge |

**4. Recommended Daily Spend**

| Question | Answer |
|---|---|
| What question does it answer? | How much can I reasonably spend today without increasing the risk of running out of money? |
| Input data | Remaining **category** budgets (not the pooled total), Days Remaining |
| Output | `recommendedDailySpend` (e.g. Rs 245/day) |
| Type | Guidance |
| Confidence | Medium — late/batched logging directly affects this number |
| Update trigger | Every `recompute()` |
| Where used | Home, Chat, Reports |
| Can it trigger alerts? | No |
| Can it trigger coaching? | Yes |

**5. Recovery Plan**

| Question | Answer |
|---|---|
| What question does it answer? | If I overspent against the recommended pace, how much less should I spend to get back on track? |
| Input data | Recommended Daily Spend, actual spend-to-date, Days Remaining |
| Output | `recoveryPlan` (e.g. "spend about Rs 35 less each day for the next week") |
| Type | Guidance (built from a Prediction-level input — dependent metrics inherit the lower confidence of what they're built on) |
| Confidence | Medium — inherits Recommended Daily Spend's logging assumption |
| Update trigger | Every `recompute()` |
| Where used | Chat, Notifications (future) |
| Can it trigger alerts? | No — this itself is the non-alert alternative (Philosophy Rule 3: recovery, not punishment) |
| Can it trigger coaching? | Yes — this **is** the coaching-layer input |

**6. Category Pressure**

| Question | Answer |
|---|---|
| What question does it answer? | Is this category's usage risky given the time left in the month? |
| Input data | Budget Utilization (per category), Days Remaining |
| Output | `categoryPressure[cat]` (e.g. Low/Medium/High — combines % used with time left, not % used alone) |
| Type | Calculation (a combination of two Facts/Calculations, not a forecast) |
| Confidence | Medium — inherits Budget Utilization's high confidence but time-scaling assumes even future spend distribution |
| Update trigger | Every `recompute()` |
| Where used | Reports, Chat, Health Engine (Phase 3) |
| Can it trigger alerts? | Not itself — a future Health/Notification Engine may read it to decide, this metric only reports the value |
| Can it trigger coaching? | Yes |

**7. Savings Stability**

| Question | Answer |
|---|---|
| What question does it answer? | If this spending pace continues, does the Savings Pool survive the rest of the month? |
| Input data | Savings Pool (fact), Spending Pace, Days Remaining |
| Output | `savingsStability` (a Prediction — explicitly worded as one, e.g. "at this pace, your savings buffer may be used by day X") |
| Type | Prediction |
| Confidence | Low — assumes current pace continues unchanged, the most forecast-dependent metric in this set |
| Update trigger | Every `recompute()` |
| Where used | Home, Chat, Notifications (future) |
| Can it trigger alerts? | Not itself in Phase 2 — reserved for the Notification Engine to consume later |
| Can it trigger coaching? | Yes |

### Metric dependency graph

*(Superseded by the accurate, code-verified version in "Phase 2 Review &
Freeze" at the end of this section — kept here for history. The original
draft below got two things wrong once Phases 2.4-2.5 were actually built:
Spending Pace does not consume the Days Remaining or Budget Utilization
metric *outputs* — it independently re-aggregates `totalSpent`/category
limits/elapsed-days-in-month, all Facts, not metrics; and Recovery Plan
does not depend on Category Pressure at all. See the corrected ledger
below for what the code actually reads.)*

Drawn explicitly so that changing one metric's definition makes its blast
radius obvious, without needing to trace call sites by hand. Corrected
from an earlier draft that had Budget Utilization depending on Days
Remaining — it doesn't; it only needs `categoryRemaining`, so each metric
depends on the *minimum* it actually needs, not on whatever else happens
to be built first:

```
Financial Summary (facts)
├── Category Remaining ──► Budget Utilization ──┐
├── Days Remaining ───────────────────────────────┼──► Category Pressure
│         │                                      │
│         ├──► Recommended Daily Spend ──► Recovery Plan ──► Recommendations (Phase 4) ──► Notifications (Phase 5)
│         │
│         └──────────────────────────────────────┴──► Spending Pace ──► Projected Savings
└── Savings Pool ─────────────────────────────────────────────────────────► Projected Savings
```

Reading it: **Days Remaining** and **Budget Utilization** are the only two
root metrics — each reads directly from `financialSummary` with no
metric-level dependency. **Spending Pace** depends on both Budget
Utilization and Days Remaining (percent used *against* percent of month
elapsed). **Recommended Daily Spend** depends only on Days Remaining
(divided into remaining category budgets, which are a Fact, not a
metric). **Category Pressure** depends on Budget Utilization + Days
Remaining. **Recovery Plan** depends on Recommended Daily Spend.
**Projected Savings** (renamed from the earlier "Savings Stability" —
same metric, clearer name matching its Level-4-Prediction type) depends
on Spending Pace + the Savings Pool fact, and is deliberately last: it's
the most assumption-heavy metric, so every simpler, more deterministic
metric is proven correct first, giving it trustworthy inputs to build on
rather than untested ones.

### Per-metric implementation workflow — one metric is one small project

Not "build all seven in the backend, then test them together." Each
metric goes through its own full cycle before the next one starts:

```
Design (this document, filled in) → Implement → Unit Test →
Real-account Test → API → UI → Done
```

Only once a metric is fully "Done" — including its own UI surface, not
just its backend field — does the next metric in the dependency-first
order (Days Remaining → Budget Utilization → Recommended Daily Spend →
...) begin. This mirrors the discipline already followed for Phase 1.5's
route-by-route migration: migrate one, verify live, document, only then
move on.

### Metric Acceptance Criteria

The same discipline applied to the Financial Engine itself (the Phase
1.9 Financial Formula Elimination criterion) applies to every metric. A
metric is not "done" because the number is correct — it's done when
every row below is "Yes":

| Criteria | Question | Example |
|---|---|---|
| **Correct?** | Produces the mathematically correct value? | Days Remaining matches a manual calendar count |
| **Deterministic?** | Same inputs always produce the same output? | Same date + month always yields the same `daysRemaining` |
| **Explainable?** | Can it be explained in one sentence? | "13 days are left in July, including today" |
| **Independent?** | Doesn't rely on any UI-side calculation? | Flutter only displays the field; it never computes it |
| **Tested?** | Unit test + real-account verification, both? | Edge-case unit tests + a live check against `botbachat@gmail.com` |
| **API Ready?** | Exposed through the metrics endpoint? | `GET /financial-metrics` returns it |
| **UI Ready?** | At least one screen displays it? | Shown under Remaining Budget on Home |
| **Consistent with Product Philosophy?** *(Advisory metrics only)* | Does this recommendation ever encourage spending Savings, or state a suggestion as a guarantee? | Recommended Daily Spend must divide only remaining *category* budgets — never Savings Pool — and must always read as "aim for," never "you can safely spend" |

If any answer is "No," the metric isn't done — it stays in progress,
named as such, the same way a route was never rounded up to "migrated"
in Phase 1.5 until all eight of its criteria passed. The Product
Philosophy row only applies to metrics classified **Advisory** (see
Metric Type above) — Descriptive/Analytical/Predictive metrics don't
suggest an action, so there's nothing to check against the philosophy.

### Phase 2 build order (revised)

```
Phase 2.1  Days Remaining
Phase 2.2  Budget Utilization
Phase 2.3  Recommended Daily Spend
Phase 2.4  Spending Pace
Phase 2.5  Recovery Plan
Phase 2.6  Category Pressure
Phase 2.7  Projected Savings   (formerly "Savings Stability" — same metric)
```

Each phase runs its own full Design → Implement → Unit Test →
Real-account Test → API → UI → Done cycle before the next phase starts.

---

## Phase 2.1 — Days Remaining

### Design

**What exactly is "Days Remaining"?** Decided once, documented here,
never silently changed:

> **Days Remaining = (total days in the current calendar month) − (today's
> day-of-month) + 1.** Today counts. On July 18, with July having 31 days,
> Days Remaining = 31 − 18 + 1 = **14**.

Worked example for the acceptance table above: July 18 → 14, not 13 —
inclusive-of-today counting means the user's remaining budget still has
to stretch across *today* as well as every day after it, which is the
correct frame for "how much can I still spend," not "how many days are
left after today."

**Date source — reused, not invented.** The Financial Engine already has
exactly one place dates come from: `utils.get_current_month_key()`, which
calls `datetime.now(timezone.utc)`. Days Remaining uses that same UTC
clock, not a new one, not the phone's local time, not a Nepal-local
timezone conversion. This was already true before Phase 2 — a pre-existing
utility, `utils.get_days_remaining_in_month()`, already implements exactly
this inclusive-of-today, UTC-based definition and is already in
production use (`routes/reports.py`'s survival-budget calculation). Phase
2.1 does not reimplement this; it reuses the existing function directly,
consistent with "reuse the exact same date source, don't invent another
one."

**Floor at 1, never 0.** `get_days_remaining_in_month()` already applies
`max(days_remaining, 1)`. Decision, documented: the last day of the month
is Days Remaining = **1**, not 0 — "today" is always at least one day to
still make spending decisions in, so it never reaches zero while the
month is still open.

**Scope: current month only.** `financialSummary` documents exist per
`monthKey`, and Reports lets a user view past months. Days Remaining is
only a meaningful concept for the *current* month — a closed past month
has no "remaining" days, and a future month key isn't valid input at all.
Decision: if the requested `monthKey` is not the current month, Days
Remaining returns **0**, distinguishable from a real "last day of the
month" value of 1 by callers that already know they requested a
non-current month.

**Update trigger.** Unlike every other metric, Days Remaining does not
depend on any financial data at all — it depends only on the current
date. It is therefore **not** wired into `recompute()`'s financial-event
triggers (Section on Recompute triggers) — it doesn't need a budget
edit or a transaction to change; it changes once, at midnight UTC, and is
simply computed fresh on every `GET /financial-metrics` call rather than
cached in a stored document. This is consistent with "Metrics can only
read" — there's nothing to store or invalidate; it's a pure function of
`(monthKey, now)`.

**Edge cases, decided in advance:**

| Case | Expected `daysRemaining` |
|---|---|
| July 1 | 31 |
| July 15 | 17 |
| July 18 (today, at time of writing) | 14 |
| July 31 (last day) | 1 (never 0 — the floor) |
| February, non-leap year, Feb 28 (last day) | 1 |
| February, leap year, Feb 29 (last day) | 1 |
| February, leap year, Feb 1 | 29 |
| `monthKey` requested is a past month (e.g. asking for June while it's July) | 0 |
| `monthKey` requested is the current month | the real calculated value (never floored to 0) |

**A pre-existing duplicate this design surfaces, not fixed now:**
`routes/reports.py` (lines ~273-282) already independently computes a
"survival budget per day" (`total_remaining / days_remaining`) and a
"pace warning" (`pct_used` vs `pct_month_elapsed`) — these are, by name and
formula, early, undocumented versions of **Recommended Daily Spend**
(Phase 2.3) and **Spending Pace** (Phase 2.4). Flagged here so those two
future phases know to migrate `reports.py` off this local calculation
when they're built — not addressed in Phase 2.1, which only touches Days
Remaining.

### Implementation

- `utils.get_days_remaining_in_month(dt: datetime = None)` gains an
  optional `dt` parameter (default `None` → `datetime.now(timezone.utc)`,
  identical to today's behavior) so tests can inject a specific date
  without inventing a second date source. Every existing caller
  (`routes/reports.py`) is unaffected — it calls with no arguments.
- New `backend/services/metrics_engine.py` — the Metrics Engine module,
  read-only by construction (imports `utils`, never
  `services/financial_engine.py`'s write path, never touches Firestore
  writes). `compute_days_remaining(month_key, reference_date=None)`
  applies the current-month-only rule above; `get_metrics(db, uid,
  month_key=None)` is the Phase 2 equivalent of `get_summary` — currently
  returns only `{"daysRemaining": ...}` plus a small metadata block, and
  is the single function every future metric phase adds one more field
  to.
- New `backend/routes/financial_metrics.py` — `GET /financial-metrics`,
  the same thin-read shape as `routes/financial_summary.py`: no
  calculation in the route itself, just `get_metrics(db, uid, month_key)`.
- Registered in `main.py` alongside the other routers.

### Test coverage (written before moving to the next phase)

Unit tests in `backend/tests/test_metrics_engine.py`, each pinned to an
injected `reference_date`:

- July 1 → 31
- July 15 → 17
- July 31 → 1 (the floor, not 0)
- February 28 (non-leap year) → 1
- February 29 (leap year) → 1
- February 1 (leap year) → 29
- Month rollover — July 31 vs August 1 produce independent correct values,
  not an off-by-one across the boundary
- Requested `monthKey` not equal to the current month → 0

Real-account verification: `GET /financial-metrics` for the current month
against `botbachat@gmail.com`, checked against a manual calendar count for
today's actual date — pass.

### API

```
GET /financial-metrics?monthKey=2026-07

{
  "success": true,
  "data": {
    "daysRemaining": 14,
    "metadata": { "version": 1, "monthKey": "2026-07" }
  }
}
```

Exposing only one field is intentional, not incomplete — the endpoint
grows one field per completed phase, the same way `financialSummary`
grew one field at a time rather than shipping its full future shape on
day one.

### UI

No redesign. Days Remaining is shown as a small line under Remaining
Budget on Home — "14 days remaining" — nothing else changes layout,
color, or spacing.

### Phase 2.1 — Done (2026-07-18)

Implementation, in the same order as the design above:

- `utils.get_days_remaining_in_month()` gained an optional `dt` parameter
  (default `None`, identical behavior to before) — no new date source, the
  existing caller (`routes/reports.py`) untouched.
- `backend/services/metrics_engine.py` (new) — `compute_days_remaining()`
  and `get_metrics()`. Imports only `utils`; never imports
  `financial_engine.py`'s write path, never touches Firestore writes —
  satisfies "Metrics never modify money" by construction, not by
  convention.
- `backend/routes/financial_metrics.py` (new) — `GET /financial-metrics`,
  registered in `main.py` alongside the other routers.
- `frontend/lib/screens/home_screen.dart` — added `_fetchFinancialMetrics()`
  (same pattern as `_fetchFinancialSummary()`), `_daysRemaining` getter
  reading `_metrics['daysRemaining']` directly (no formula).
- `frontend/lib/widgets/balance_card.dart` — added an optional
  `daysRemaining` field, rendered as one small line ("14 days remaining
  this month") under the Unused Budget amount. No layout, color, or
  spacing change beyond that one line.

**Metric Acceptance Criteria — all seven checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — matches a manual calendar calculation (verified below) |
| Deterministic? | Yes — 9 unit tests pin explicit dates and assert exact values |
| Explainable? | Yes — "14 days are left in July, including today" |
| Independent? | Yes — Flutter only displays `_metrics['daysRemaining']`, computes nothing |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (9 scenarios, all passing) + real-account verification |
| API Ready? | Yes — `GET /financial-metrics` |
| UI Ready? | Yes — shown on Home under Unused Budget |

**Unit tests** (`backend/tests/test_metrics_engine.py`, all 9 passing):
July 1→31, July 15→17, July 18→14, July 31→1 (the floor, not 0),
Feb 28 non-leap→1, Feb 29 leap→1, Feb 1 leap→29, month rollover
(July 31 vs Aug 1 independently correct), non-current `monthKey`→0.

**Real-account verification**: called `get_metrics()` directly against
`botbachat@gmail.com` for the current month (2026-07-18) — returned
`daysRemaining: 14`, matching an independent manual calendar calculation
exactly (31 total days in July − 18 + 1 = 14).

**Frontend verification**: `dart analyze` clean on both touched files
(zero issues); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification depth
and limits as Phase 1.9's Home/Categories work (compiles and boots; full
visual confirmation of the rendered line not done, no browser-driving
tool available in this environment).

**Infrastructure note, unrelated to this metric**: this environment was
missing `apscheduler` and `passlib` (both pre-existing `main.py`
dependencies, not introduced by Phase 2.1) — installed to allow
`main.py` to import; a third missing dependency, `cloudinary`
(`routes/upload.py`), was left uninstalled since it wasn't required to
verify this phase (verification used `services/metrics_engine.py`
directly against real Firestore data, the same approach
`audit_financial_engine.py` has used throughout this project, not a full
HTTP+auth round trip).

**Days Remaining is Done, per every row of the Metric Acceptance
Criteria table.** Phase 2.2 (Budget Utilization) is next, on separate
confirmation.

---

## Phase 2.2 — Budget Utilization

### Design

**Purpose — one question, not three.** This metric answers only:

> "How much of this category's budget has already been used?"

Not whether that's healthy, risky, or whether the user should spend more
— those are Health (Phase 3) and Coaching (Phase 4) questions, answered
on top of this number, never inside it.

**Scope**: Per Category (see the Metric Scope table above).

**Inputs — from `financialSummary` only, never raw budgets.** For each
category, `categoryRemaining[category]` already provides `spent`,
`remaining`, `limit` — the Metrics Engine reads these, it never
independently sums transactions or reads a `budgets` document itself.
That would be the exact `budgets.spent`-drift mistake Section 8 already
eliminated, reintroduced one layer up.

**Formula:**

```
utilization = (spent / limit) × 100
```

**Edge cases, decided in advance:**

- **`limit == 0`** (e.g. a category with no budget set, like an unused
  "Shopping" bucket) → **utilization = 0%**. Decision: not 100%, not
  undefined — there's no usable budget to measure usage against, so "0%
  used of nothing" is the least misleading answer. This also means
  `1/0` is **not** treated as a divide-by-zero error; it's the same
  `limit == 0` case, resolved to 0% regardless of `spent`.
- **Over budget** (`spent > limit`, e.g. 3400/3000) → **not clamped**,
  returns **113.33%** (or whatever the exact ratio is). Decision:
  clamping to 100% would silently hide *how far* over a category is,
  and Phase 3's Health Engine and Phase 2.6's Category Pressure both need
  the real magnitude, not a ceiling-flattened one.
- **Deleted / inactive category** — never appears here at all. The
  Financial Engine already decides what's active when it builds
  `categoryRemaining` (Section 8's Ground Truth Principle); the Metrics
  Engine only reads what it's given, it doesn't filter or re-derive
  activeness itself.
- **Negative `spent` or `limit`** — should never happen (Section 7's No
  Negative Budgets invariant). If it does, that's a Financial Engine
  invariant failure to fix at the source, not something the Metrics
  Engine works around, clamps, or silently corrects. This function
  trusts its input and computes the formula as given — masking a bad
  upstream value here would hide the very bug the invariant exists to
  catch.

**Output shape** (per the API-shape principle above — an object per
category, not a bare number, so later fields can be added without a
breaking change):

```
"budgetUtilization": {
  "Food": { "utilization": 60.0 },
  "Shopping": { "utilization": 0.0 }
}
```

### Metric Acceptance Criteria

| Criteria | Answer |
|---|---|
| Correct? | `spent / limit × 100` exactly — e.g. 1800/3000 → 60% |
| Deterministic? | Same `categoryRemaining` input always produces the same percentage |
| Explainable? | "You've used 60% of your Food budget because you've spent Rs 1,800 out of your Rs 3,000 limit." |
| Independent? | No UI math — Flutter displays `budgetUtilization[cat].utilization` directly |
| Tested? | Unit tests below + real-account verification |
| API Ready? | Exposed via `GET /financial-metrics`, alongside `daysRemaining` |
| UI Ready? | Categories screen displays it wherever a per-category percentage already exists |

### Test plan (written before implementation, run after)

- 50 spent / 100 limit → 50%
- 0 spent / 100 limit → 0%
- 100 spent / 100 limit → 100%
- 120 spent / 100 limit → 120% (not clamped)
- 0 spent / 0 limit → 0% (the `limit == 0` rule)
- 1 spent / 0 limit → 0% (same rule — `spent` never matters when `limit`
  is 0)

### API

`budgetUtilization` is added as a sibling field to `daysRemaining` inside
the same `GET /financial-metrics` response — no new endpoint:

```
GET /financial-metrics?monthKey=2026-07

{
  "success": true,
  "data": {
    "daysRemaining": 14,
    "budgetUtilization": {
      "Food": { "utilization": 60.0 },
      "Shopping": { "utilization": 0.0 }
    },
    "metadata": {
      "metricsEngineVersion": 1,
      "monthKey": "2026-07",
      "generatedAt": "...",
      "generationMs": 9
    }
  }
}
```

### UI

No redesign. Categories already displays a per-category percentage
locally — `_buildBucketCard`'s `percent = spent/limit`, the badge and
progress bar on each category card. Phase 2.2 replaces that local
calculation with `budgetUtilization[cat].utilization` — same spot on
screen, same visual, only the source of the number changes.

**Correction on a mislabel in this design's first draft**: `_spentPercent`
(flagged in Phase 1.9) is a **different, still-open exception** — it's a
*global* aggregate (`_totalSpent / _totalLimit`), not a per-category
value, so it isn't this metric's target and stays untouched by Phase 2.2.
It remains presentation-only, pending whichever future Global metric
(Spending Pace, Phase 2.4, is the closest fit) eventually replaces it.

### Phase 2.2 — Done (2026-07-18)

Implementation:

- `services/metrics_engine.py` — added `compute_budget_utilization()`
  (pure function on `categoryRemaining`, no Firestore access) and
  `METRICS_ENGINE_VERSION` (renamed from the ad hoc `METRICS_SCHEMA_VERSION`
  Phase 2.1 introduced, per this phase's versioning-discipline addition).
  `get_metrics()` now calls `get_summary()` once, times itself with
  `time.perf_counter()`, and returns `daysRemaining`, `budgetUtilization`,
  and the new `metadata` shape (`metricsEngineVersion`, `monthKey`,
  `generatedAt`, `generationMs`).
- `frontend/lib/screens/categories_screen.dart` — `_fetchFinancialSummary()`
  now fetches `/financial-summary` and `/financial-metrics` together
  (`Future.wait`), attaches `utilization` onto each `_budgets` entry.
  `_buildBucketCard` reads `item['utilization']` instead of computing
  `spent/limit`; the existing display clamps (0.0-2.0 for the
  over/critical thresholds, 0.0-1.0 for the progress bar) are unchanged —
  they're this screen's own visual bounds, not a re-derivation of the
  ratio itself.

**Metric Acceptance Criteria — all seven checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — `spent/limit × 100` exactly, verified against live data |
| Deterministic? | Yes — 7 unit tests pin exact input/output pairs |
| Explainable? | Yes — "You've used 100% of your Food budget because you've spent Rs 520 out of your Rs 520 limit" |
| Independent? | Yes — `_buildBucketCard` reads `item['utilization']` directly, no local division |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (7 new scenarios, all passing) + real-account verification |
| API Ready? | Yes — `budgetUtilization` added to the existing `GET /financial-metrics` response |
| UI Ready? | Yes — Categories' per-category badge/progress bar |

**Unit tests** (all passing, 16 total across both phases now): 50/100→50%,
0/100→0%, 100/100→100%, 120/100→120% (not clamped), 0/0→0%, 1/0→0%
(the `limit==0` rule, `spent` irrelevant), plus a multi-category
independence check.

**Real-account verification**: called `get_metrics()` directly against
`botbachat@gmail.com` — returned `Food: 100%` (spent 520/limit 520),
`Transport: 25%` (spent 20/limit 80), cross-checked against an
independent manual calculation from the same `categoryRemaining` data —
both matched exactly.

**Frontend verification**: `dart analyze` clean on `categories_screen.dart`
(only pre-existing `const`-constructor info hints, same ones noted in
Phase 1.9); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification depth
as every prior UI phase.

**Budget Utilization is Done, per every row of the Metric Acceptance
Criteria table.** Phase 2.3 (Recommended Daily Spend) is next, on
separate confirmation.

---

## Phase 2.3 — Recommended Daily Spend

The most important metric in the app — everything built on top of it
(Recovery Plan, Category Pressure, future Recommendations/Notifications)
inherits whatever this one gets wrong. Frozen carefully, for that reason.

### Design

**Scope**: Global. **Type**: Advisory.

**What question does it actually answer?** Not "how much money does the
user have" (that's Facts, already in `financialSummary`) and not "how
much can they technically spend" (that would imply Savings Pool is
fair game). It answers:

> "If the user wants to finish the month without breaking their budget,
> how much should they **aim** to spend per day, from now onward?"

*Aim to* is deliberate wording, not decoration — this is guidance, not a
permission slip.

**Formula:**

```
recommendedDailySpend = (sum of remaining category budgets) / daysRemaining
```

**Decision, frozen: Savings Pool is never included.** The product
philosophy (top of this document) has held since Phase 1 that Savings is
the last resort (Money Priority Rule, Section 1) — a recommendation that
already assumes Savings would be quietly telling the user it's fine to
spend it, which contradicts that philosophy on day one of the metric's
existence. Only `categoryRemaining[cat].remaining` for categories with a
budget set (`limit > 0`) is summed; `savingsPool` never enters this
formula, full stop.

**Decision, frozen: recomputed from the current remaining, every time —
not fixed at the start of the month.** If the user spends Rs 100 in the
morning, the recommendation for the rest of the day already reflects
that Rs 100 gone; if they spend Rs 300 more in the afternoon, it drops
again. This is what "from now onward" in the definition above means —
the metric always divides *current* remaining category budgets by
*current* days remaining, exactly the same "computed fresh on every
call, nothing stored" design Days Remaining already established. There
is no separate "starting" value to reconcile against; every call is a
fresh division of the two current Facts feeding it.

**Confidence: Medium, always** — never High. This inherits the same
logging-vs-spending gap named back in Phase 2.0: the formula is exact
arithmetic on `categoryRemaining`, but `categoryRemaining` itself can be
optimistic if the user hasn't logged everything yet. The wording
reflects this directly — the chatbot/UI must say "Based on your recorded
expenses, your recommended daily spending is about Rs 250," never "You
can safely spend Rs 250." The first sentence names its own evidence and
implicitly admits it could be wrong if recording is incomplete; the
second claims a safety guarantee the data cannot actually back.

**Edge cases, decided in advance:**

- **`daysRemaining == 1`** — no special case; the formula already
  produces "spend the rest today" (e.g. remaining 1500 / 1 day = 1500).
- **Remaining category budgets sum to 0** → **0/day**. Correct as-is —
  there's genuinely nothing left to recommend spending.
- **Negative remaining** (shouldn't happen given the No Negative Budgets
  invariant on real per-category data — Section 7 already guarantees
  each category's `remaining` is floored at 0 — but the function still
  defends against it for any caller/test that passes a raw value) →
  **clamped to 0/day, never a negative number.** A negative daily
  recommendation is meaningless; the point of "you're over" belongs to
  Recovery Plan (Phase 2.5), not to this metric pretending a negative
  number is guidance.
- **No budgets exist at all** (no category has `limit > 0`) → **`null`**,
  not `0` and not a fabricated number. Returning `0` here would look
  identical to "you've used your whole budget," a completely different
  and false statement when the truth is "no budget was ever set." Faking
  precision where none exists is exactly what the Phase 2.0 "can this
  metric ever lie" test exists to catch.

**Output shape** (object, not a bare number — same forward-compatible
principle as Budget Utilization):

```
"recommendedDailySpend": {
  "value": 250.0,
  "confidence": "medium"
}
```

or, when no budgets exist:

```
"recommendedDailySpend": null
```

Future fields (`basedOnCategories`, `daysRemaining` echoed back for
convenience, etc.) can be added to the object later without breaking a
client that only reads `.value`.

### Metric Acceptance Criteria

| Criteria | Answer |
|---|---|
| Correct? | `sum(remaining category budgets) / daysRemaining`, exactly |
| Deterministic? | Same `categoryRemaining` + `daysRemaining` always produce the same value |
| Explainable? | "You have Rs 700 left across your budgets and 14 days remaining, so about Rs 50/day." |
| Independent? | UI reads `.value`/`.confidence` directly, computes nothing |
| Tested? | Unit tests below + real-account verification, including a spend-then-undo round trip |
| API Ready? | Added to `GET /financial-metrics` as a sibling of `daysRemaining`/`budgetUtilization` |
| UI Ready? | One line under Remaining Budget on Home |
| **Consistent with Product Philosophy?** | Never includes Savings Pool; always worded as "aim for"/"recommended," never "safe to spend" |

### Test plan (written before implementation, run after)

- Remaining 1200, Days 12 → 100/day
- Remaining 0, Days 10 → 0/day
- Remaining -500 (synthetic, defends against a value the real invariants
  should already prevent), Days 5 → 0/day, never -100
- No budgets at all → `null`
- Remaining 1500, Days 1 → 1500/day
- Real-account test: remaining categories total Rs 700, 14 days remaining
  → expect 50/day; spend Rs 140; confirm the recommendation drops to
  match the new remaining total divided by the same days-remaining;
  undo the transaction; confirm it returns to 50/day.

### API

```
GET /financial-metrics?monthKey=2026-07

{
  "success": true,
  "data": {
    "daysRemaining": 14,
    "budgetUtilization": { "Food": { "utilization": 100.0 }, "Transport": { "utilization": 25.0 } },
    "recommendedDailySpend": { "value": 50.0, "confidence": "medium" },
    "metadata": { "metricsEngineVersion": 1, "monthKey": "2026-07", "generatedAt": "...", "generationMs": 9 }
  }
}
```

### UI

No redesign — one small line under Remaining Budget on Home, next to the
existing Days Remaining line: "Recommended Today: Rs 250." Nothing else
changes.

**Not started yet.** This design — purpose, the Savings-Pool exclusion,
the recompute-from-current-remaining behavior, confidence wording, edge
cases, output shape, acceptance criteria (including the new Product
Philosophy row), and test plan — is the freeze before any Phase 2.3 code.
Implementation follows on the user's go-ahead, same as Phases 2.1-2.2.

### Phase 2.3 — Done (2026-07-18)

Implementation:

- `services/metrics_engine.py` — added `compute_recommended_daily_spend()`.
  Sums only `categoryRemaining[cat].remaining` for categories with
  `limit > 0` (never `savingsPool`); returns `None` if no category has a
  budget set or if `daysRemaining <= 0`; clamps the summed remaining to a
  floor of 0 before dividing, so the result is never negative.
  `get_metrics()` now computes `days_remaining` once and threads it into
  both `compute_recommended_daily_spend()` and the response, added as a
  sibling field alongside `daysRemaining`/`budgetUtilization`.
- `frontend/lib/screens/home_screen.dart` — `_recommendedDailySpend`
  getter reads `_metrics['recommendedDailySpend']?['value']`, `null`-safe
  by construction (no fallback to 0).
- `frontend/lib/widgets/balance_card.dart` — one line under Days
  Remaining: "Aim for Rs X/day for the rest of the month" — worded as
  guidance per the Product Philosophy acceptance criterion, not "safe to
  spend." Hidden entirely (not shown as Rs 0) when `recommendedDailySpend`
  is `null`.

**Metric Acceptance Criteria — all eight checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — `sum(remaining budgeted categories) / daysRemaining`, verified against live data |
| Deterministic? | Yes — 8 unit tests pin exact input/output pairs |
| Explainable? | Yes — "You have Rs 60 left across your budgets and 14 days remaining, so aim for about Rs 4.3/day." |
| Independent? | Yes — Flutter reads `.value` directly, computes nothing |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (8 new scenarios, all passing) + real-account verification including a spend-then-undo round trip |
| API Ready? | Yes — `recommendedDailySpend` added to `GET /financial-metrics` |
| UI Ready? | Yes — one line on Home under Days Remaining |
| **Consistent with Product Philosophy?** | Yes — `savingsPool` never enters the formula; wording is "aim for," never "safe to spend" |

**Unit tests** (all passing, 24 total across three phases now): Remaining
1200/Days 12→100/day, Remaining 0/Days 10→0/day, Remaining -500
(synthetic)/Days 5→0/day (never negative), no budgets→`null`, empty
`categoryRemaining`→`null`, Remaining 1500/Days 1→1500/day, a
multi-category case that ignores `limit==0` categories, and
`daysRemaining==0`→`null` (not a division error).

**Real-account verification, two rounds against `botbachat@gmail.com`**
(month `2026-07`, baseline `4.29/day` = (Food remaining 0 + Transport
remaining 60) / 14 days):

1. Spent Rs 40 on **Food** (already at its limit, remaining 0) — the
   recommendation stayed **unchanged** at 4.29/day. Undid the transaction
   (exact transaction ID recorded at creation, cleaned up by that ID) —
   confirmed unchanged throughout.
2. Spent Rs 40 on **Transport** (had Rs 60 of buffer) — the
   recommendation dropped to **1.43/day**, matching the manually
   calculated expected value `(0 + 20) / 14` exactly. Undid the
   transaction — confirmed it returned to the exact baseline `4.29/day`.

**A genuine, non-obvious finding from round 1, not a bug**: when an
overspend in a category that's already at its limit gets absorbed by the
Savings Pool (via the Money Priority Rule's waterfall) rather than by
another category's buffer, Recommended Daily Spend doesn't move at all —
because it only sums category buffers, by design, and money the waterfall
routed into Savings was never part of that sum to begin with. This is the
Savings-Pool-exclusion decision working exactly as intended: the metric
correctly stays silent about spending that Savings, not the categories,
absorbed.

**Frontend verification**: `dart analyze` clean on both touched files
(zero issues); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification depth
as every prior UI phase.

**Recommended Daily Spend is Done, per every row of the Metric
Acceptance Criteria table, including the new Product Philosophy check.**
Phase 2.4 (Spending Pace) is next, on separate confirmation.

---

## Phase 2.3a — Category Daily Target (added 2026-07-18, discovered during Phase 4.0 design)

**A narrow, explicit amendment to the Phase 2 Complete freeze.** Phase 2
was declared frozen after Phase 2.7 — that freeze meant the seven
existing metrics' formulas don't change, not that Phase 2 could never
grow a new metric when a genuine, previously-missed gap surfaces. This
is exactly that: while designing Phase 4.0's Recommendation Matrix, the
`REDUCE_CATEGORY_SPENDING` recommendation needed a per-category daily
figure ("keep Food spending below Rs 80/day") — and no existing metric
computes one. Recommended Daily Spend (Phase 2.3) is deliberately
*Global* (Rule: never includes Savings Pool, sums *all* budgeted
categories together). Inventing a per-category number inside the
Recommendation Engine to fill that gap would have been exactly the
duplication this whole architecture exists to prevent — the same
reasoning that pushed Category Pressure's materiality check down into
Metrics Engine rather than doing it in Health. The fix belongs in Phase
2, not Phase 4.

### Design

**Scope**: Per Category. **Type**: Advisory (same classification as
Recommended Daily Spend — a suggestion, never a guarantee). **Confidence:
Medium** — same reasoning as Recommended Daily Spend: it assumes prompt,
honest logging, so it can never claim Spending Pace's High confidence.

**The one question this answers**: "How much can I spend today in *this
specific category*, given only its own remaining budget?" Not "how much
overall" (that's Recommended Daily Spend), not "what should I do to
recover" (that's Recovery Plan) — a narrower, per-category counterpart
to Recommended Daily Spend, nothing more.

**Formula:**

```
categoryDailyTarget[cat] = categoryRemaining[cat].remaining / daysRemaining
```

for every category with `limit > 0` (budgeted).

**Decision, frozen: no inter-category borrowing — this is a strict,
isolated per-category view, deliberately not the same thing Recovery
Plan already computes.** Recommended Daily Spend and Recovery Plan both
pool *across* categories (summing all remaining category budgets
together, or explicitly redistributing via the Waterfall). Category
Daily Target does the opposite on purpose: "if you only ever spend from
*this* category's own remaining, here's today's rate" — a planning tool
for a category still operating normally, not a recovery tool for one
that's already exhausted. **These two concepts are kept separate, never
merged into one metric**, per the explicit design decision: mixing
"normal per-category planning" with "recovery after overspending" would
make a single metric answer two different questions depending on
context, which is exactly the ambiguity the Ladder/Type system exists to
prevent.

**Edge cases, decided in advance:**

- **Category exhausted** (`remaining == 0`, already floored there by the
  Financial Engine's No Negative Budgets invariant, Section 7) →
  **`value = 0`**, included in the output, not omitted. A 0/day target
  is meaningful information ("nothing left in this category today"),
  distinct from a category that was never budgeted at all.
- **Category never budgeted** (`limit <= 0`) → omitted entirely from the
  output map — same treatment Budget Utilization and Category Pressure
  already give this case; nothing to compute against.
- **No budgeted categories at all** → the whole metric returns `null`.
- **`daysRemaining <= 0`** (non-current month, or the metric is somehow
  asked to run past month-end) → `null` — same current-month-only scope
  every other days-based metric already observes.
- **Never clamped, never negative** — `remaining` is already
  non-negative by the Financial Engine's own invariant before this
  metric ever sees it, so no additional clamping logic is needed here.

**Output shape** — a per-category map, same forward-compatible object
shape as Budget Utilization/Category Pressure's `byCategory`:

```
"categoryDailyTarget": {
  "Food": { "value": 20.0, "confidence": "medium" },
  "Transport": { "value": 40.0, "confidence": "medium" }
}
```

or `null` if no category has a budget at all.

### Metric Acceptance Criteria

| Criteria | Answer |
|---|---|
| Correct? | `categoryRemaining[cat].remaining / daysRemaining`, exactly, per category |
| Deterministic? | Same `categoryRemaining` + `daysRemaining` always produce the same per-category targets |
| Explainable? | "Food has Rs 280 left across 14 days, so about Rs 20/day." |
| Independent? | UI/Recommendation Engine read `.value` directly, compute nothing |
| Tested? | Unit tests + real-account verification |
| API Ready? | Added to `GET /financial-metrics` as `categoryDailyTarget` |
| UI Ready? | Categories screen / category detail can show it, no redesign |
| Consistent with Product Philosophy? | Never includes Savings Pool (same as Recommended Daily Spend); never invents a number for an unbudgeted category |

### Test plan

- Normal category with buffer → `remaining / daysRemaining`, exact match
- Exhausted category → `0`, included (not omitted)
- Unbudgeted category → omitted from the map entirely
- No budgeted categories at all → `null`
- `daysRemaining <= 0` → `null`
- Multiple categories → independent values, matching the earlier
  Category Pressure precedent for independence

### Not started yet — implementation follows immediately in this session

This design (purpose, formula, the deliberate no-borrowing decision
keeping this separate from Recovery Plan, edge cases, output shape,
acceptance criteria, test plan) is the freeze for this narrow Phase 2
addition. Implementation, tests, real-account verification, and API/UI
wiring follow next, then Phase 4.0's Recommendation Matrix is updated to
reference this metric by name instead of the `null`-placeholder gap it
previously named.

### Phase 2.3a — Done (2026-07-18)

Implementation:

- `services/metrics_engine.py` — added `compute_category_daily_target(category_remaining,
  days_remaining)`, a pure function reusing the exact per-category
  budgeted-filter pattern already established by Budget Utilization and
  Category Pressure. `get_metrics()` now includes `categoryDailyTarget`
  as a sibling field, computed from the same `category_remaining`/
  `days_remaining` already in scope — no new inputs threaded through.
- `frontend/lib/screens/category_detail_page.dart` — `_fetchBudgetMeta()`
  now also calls `/financial-metrics` (alongside the existing
  `/financial-summary` call) and reads
  `categoryDailyTarget[widget.category].value` directly. One new line
  under the existing progress bar: "Aim for Rs X/day in {category} for
  the rest of the month" — hidden entirely when `null` (unbudgeted
  category or no days remain), never shown as a fabricated 0.

**Metric Acceptance Criteria — all eight checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — `categoryRemaining[cat].remaining / daysRemaining`, verified against live data |
| Deterministic? | Yes — 6 unit tests pin exact input/output pairs |
| Explainable? | Yes — "Food has Rs 280 left across 14 days, so about Rs 20/day" |
| Independent? | Yes — UI reads `.value` directly, computes nothing |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (6 new scenarios, all passing) + real-account verification |
| API Ready? | Yes — `categoryDailyTarget` added to `GET /financial-metrics` |
| UI Ready? | Yes — one line on the category detail page |
| Consistent with Product Philosophy? | Yes — never includes Savings Pool; an exhausted category gets an honest `0`, never a fabricated positive number |

**Unit tests** (all passing, 61 total across Phase 2 + Phase 3 now):
normal category with buffer → exact `remaining/daysRemaining`; exhausted
category → `0`, included (not omitted); unbudgeted category → omitted
entirely from the map; no budgeted categories at all → `null`;
`daysRemaining <= 0` → `null`, not a division error; multiple categories
→ independent values.

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`, `daysRemaining=14`): `Food` (exhausted, `remaining=0`) →
`0.0`, correctly included rather than omitted; `Transport`
(`remaining=60`) → `4.2857`, matching `60/14` exactly. Both
cross-checked against an independent manual calculation from the same
`categoryRemaining` data.

**Frontend verification**: `dart analyze` clean on
`category_detail_page.dart` (only pre-existing style hints unrelated to
this change); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification
depth as every prior UI phase.

**Category Daily Target is Done, per every row of the Metric Acceptance
Criteria table.** The Phase 2 Complete freeze (declared after Phase 2.7)
now covers eight metrics, not seven — this addition, and only this
addition, is exempted from that freeze; the original seven's formulas
are unchanged. Phase 4.0's Recommendation Matrix is updated next to
reference this metric by name.

---

## Phase 2.4 — Spending Pace

The first metric that answers "how am I doing?" rather than "how much is
left?" — three interpretations were considered and two rejected before
settling on this design:

- **Rejected: percentage of budget spent** — that's already Budget
  Utilization (Phase 2.2); rebuilding it under a new name adds nothing.
- **Rejected: money spent today** — that's just today's spending, not a
  pace, and says nothing about whether that pace is sustainable.
- **Chosen: is spending ahead of or behind how far the month has
  progressed?** — the only interpretation that actually answers "am I
  likely to survive the month," because Rs 5,000 spent by Day 28 is fine
  and the same Rs 5,000 spent by Day 5 is not — time is what makes the
  number meaningful, not the raw percentage alone.

### Design

**Scope**: Global. **Type**: Analytical — this metric only *describes*
whether spending is ahead of, on, or behind schedule; it never
recommends an action (that's Recovery Plan, Phase 2.5) and it never
outputs a health color (that's Phase 3, which will *consume* this metric
rather than recompute its own thresholds — see the architectural note
below).

**Formula:**

```
timeProgress   = elapsedDays / totalDaysInMonth
budgetProgress = totalSpent / totalBudget
difference     = budgetProgress - timeProgress
```

`totalBudget` is the sum of `categoryRemaining[cat].limit` across
categories with `limit > 0` — the same aggregation `_totalBudgetLimit`
already performs on Home (a total of Facts the Engine already reports,
not a new formula). `totalSpent` is `financialSummary['totalSpent']`
directly, already a Fact.

**Confidence: High, always** — unlike Recommended Daily Spend, this
metric makes no assumption about *future* logging; it only describes
*today's* numbers against *today's* date, both of which are already
fully trusted (`totalSpent` is derived from confirmed transactions,
`elapsedDays`/`totalDaysInMonth` are calendar facts). There is nothing
this metric assumes will keep being true — it has no forward-looking
claim to hedge, unlike Recommended Daily Spend's dependence on prompt
logging continuing.

**Classification — the Engine returns a raw `difference`, a separate
interpretation layer classifies it into a `status`:**

| Difference | Status |
|---|---|
| ≤ −0.10 | `ahead` |
| −0.10 to +0.10 | `on_pace` |
| +0.10 to +0.25 | `slightly_fast` |
| \> +0.25 | `too_fast` |

These thresholds are a first cut, expected to be tuned later — that's
exactly why the raw `difference` is also returned alongside the label,
not discarded once classified.

**No clamping.** Over-budget spending (`budgetProgress` > 100%) produces
a `difference` above what any threshold needs, correctly landing in
`too_fast` — the same "don't hide the real magnitude" decision Budget
Utilization already made for the same reason (Phase 3 and any future
coaching need the real number, not a flattened one).

**Edge cases, decided in advance:**

- **No budget set at all** (`totalBudget == 0`, i.e. no category has
  `limit > 0`) → **`null`**. Same reasoning as Recommended Daily Spend:
  a pace comparison against a budget that doesn't exist would be a
  fabricated number, not a real description.
- **First day of the month** (`elapsedDays == 1`) — no special case; the
  formula already works (`timeProgress = 1/totalDays`).
- **Last day of the month** (`elapsedDays == totalDays`) — `timeProgress
  = 100%`; also no special case.

**What this metric must never do**: recommend an action ("spend less
tomorrow" is Recovery Plan's job, not this one's) or assign a health
color (Phase 3's job). It only ever states one fact: whether spending is
ahead of, on, or behind the month's progress.

**Output shape:**

```
"spendingPace": {
  "difference": 0.12,
  "status": "slightly_fast",
  "confidence": "high"
}
```

or `null` if no budget exists.

### Architectural note — this is what breaks the hardcoded health-percentage habit

Phase 1.9 (UI Migration) already found and documented three duplicate,
disagreeing health-status implementations (Home's
`_updateFinancialStatus`, Categories' `_computeStatus`,
`routes/reports.py`'s `overall_status`), all hardcoding their own
`spent > 80%`-style thresholds directly against raw numbers. Phase 3
(Health & Risk Engine) is where those get unified — and the decision,
frozen here rather than left to be rediscovered in Phase 3, is that
Phase 3 **consumes** Budget Utilization + Spending Pace + Recommended
Daily Spend as its inputs, rather than recomputing its own thresholds
against raw `spent`/`limit` again. That keeps the separation clean:
**Phase 2 computes facts and analysis, Phase 3 only interprets them into
colors.** Not built now — named here so Phase 3 starts from this
decision instead of re-deriving it.

### Metric Acceptance Criteria

| Criteria | Answer |
|---|---|
| Correct? | `(totalSpent/totalBudget) − (elapsedDays/totalDays)`, exactly |
| Deterministic? | Same `totalSpent`/`totalBudget`/date always produce the same difference and status |
| Explainable? | "You've used 60% of your budget, but 50% of the month has passed — you're spending about 10% faster than the month is going." |
| Independent? | UI reads `.status` (and optionally `.difference`) directly, computes nothing |
| Tested? | Unit tests below + real-account verification |
| API Ready? | Added to `GET /financial-metrics` as a sibling field |
| UI Ready? | A status badge on Home (no raw number shown) |
| Consistent with Product Philosophy? *(N/A — Analytical, not Advisory)* | This metric makes no recommendation, so there's nothing to check against the savings-last rule |

### Test plan (written before implementation, run after)

- Day 15/30, Spent 500/Budget 1000 → `on_pace` (timeProgress 50% = budgetProgress 50%)
- Day 20/30, Spent 500/Budget 1000 → `ahead` (timeProgress 66.7% > budgetProgress 50%)
- Day 10/30, Spent 700/Budget 1000 → `too_fast` (timeProgress 33.3% ≪ budgetProgress 70%)
- No budget → `null`
- Over budget: Spent 1200/Budget 1000 (120%), Day 15/30 → `too_fast`, not clamped

### API

```
GET /financial-metrics?monthKey=2026-07

{
  "success": true,
  "data": {
    "daysRemaining": 14,
    "budgetUtilization": { ... },
    "recommendedDailySpend": { ... },
    "spendingPace": { "difference": 0.12, "status": "slightly_fast", "confidence": "high" },
    "metadata": { ... }
  }
}
```

### UI

No numbers shown — a short status badge only, per the design: "✓ On
Pace" or "▲ Spending Faster Than Planned." Placed on Home, near the
other Metrics Engine lines. Layout otherwise untouched.

**Not started yet.** This design — the three interpretations considered
and two rejected, the formula, confidence reasoning, classification
thresholds, no-clamping decision, edge cases, the Phase 3 architectural
note, acceptance criteria, and test plan — is the freeze before any
Phase 2.4 code. Implementation follows on the user's go-ahead, same as
Phases 2.1-2.3.

### Phase 2.4 — Done (2026-07-18)

Implementation:

- `services/metrics_engine.py` — added `_classify_pace()` (private
  threshold table, per the spec's "the Engine returns a raw difference,
  a separate interpretation layer classifies it" design) and
  `compute_spending_pace(total_spent, total_budget, elapsed_days,
  total_days)` — a pure function, no Firestore access. `get_metrics()`
  now also computes `total_budget` (sum of `categoryRemaining[cat].limit`
  across budgeted categories — the same aggregation Home's
  `_totalBudgetLimit` already performs) and calls
  `utils.get_days_passed_in_month()`/`get_total_days_in_month()` — both
  pre-existing, reused directly, no new date source introduced.
- `frontend/lib/screens/home_screen.dart` — `_spendingPaceStatus` getter
  reads `_metrics['spendingPace']?['status']` only — the raw
  `difference` is deliberately never surfaced to Flutter.
- `frontend/lib/widgets/balance_card.dart` — a `_paceLabel` mapping from
  status to short text ("✓ On Pace" / "✓ Ahead of Pace" / "▲ Spending a
  Bit Fast" / "▲ Spending Faster Than Planned"), shown as one line below
  Recommended Daily Spend. No numbers, per the design.

**Metric Acceptance Criteria — all eight checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — `(totalSpent/totalBudget) − (elapsedDays/totalDays)`, verified against live data |
| Deterministic? | Yes — 7 unit tests pin exact input/output pairs |
| Explainable? | Yes — "You've used 90% of your budget, but 58% of the month has passed — you're spending faster than planned." |
| Independent? | Yes — Flutter reads `.status` only, computes nothing |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (7 new scenarios, all passing) + real-account verification |
| API Ready? | Yes — `spendingPace` added to `GET /financial-metrics` |
| UI Ready? | Yes — a status badge on Home |
| Consistent with Product Philosophy? | N/A (Analytical, not Advisory) — makes no recommendation, confirmed by inspection: the implementation never touches `savingsPool` and never emits an action string |

**Unit tests** (all passing, 31 total across four phases now): Day
15/30, Spent 500/Budget 1000 → `on_pace`; Day 20/30, Spent 500/Budget
1000 → `ahead`; Day 10/30, Spent 700/Budget 1000 → `too_fast`; no budget
→ `null`; over budget (Spent 1200/Budget 1000, Day 15/30) → `too_fast`
with the real unclamped difference (0.7); confidence is always `"high"`;
`totalDays == 0` → `null`, not a division error.

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`, Day 18 of 31): `totalSpent=540`, `totalBudget=600`
(`elapsed=18`, `totalDays=31`) → `timeProgress=58.06%`,
`budgetProgress=90%`, `difference=+0.319` → `too_fast`. Cross-checked
against an independent manual calculation from the same numbers — exact
match.

**Frontend verification**: `dart analyze` clean on both touched files
(zero issues); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification depth
as every prior UI phase.

**Spending Pace is Done, per every row of the Metric Acceptance Criteria
table.** With Days Remaining, Budget Utilization, Recommended Daily
Spend, and Spending Pace all in place, the three core building blocks
the user identified — "how much have I used," "how much should I aim to
spend," "am I ahead or behind" — now exist as a consistent, tested
foundation. Phase 2.5 (Recovery Plan) is next, on separate confirmation.

---

## Phase 2.5 — Recovery Plan

Every prior Phase 2 metric answered "what happened" or "how am I doing."
This is the first one that answers **"what should I do now"** — the
first feature that carries BachatBot's actual identity, so it gets the
most design care of anything in Phase 2.

### Design

**Scope**: Global. **Type**: Advisory. **Confidence: Medium, always** —
like Recommended Daily Spend (which it depends on), this assumes future
spending behavior, so it can never claim High confidence the way
Spending Pace can.

**The one question this metric answers, and nothing else:**

> "If I continue from today, how should I adjust my spending?"

Not "what happened" (Section 9's bug history / past-tense territory),
not a health color (Phase 3), not a notification (Phase 5) — only a
forward-looking adjustment, and only when one is actually needed.

**First principle: this is not a punishment.** "You overspent, spend
only Rs 50/day" frames the user as having failed. The actual question is
"given where you are today, what's the smallest adjustment needed to
still finish the month successfully" — recovery, not penance, matching
the product's founding goal (help a student survive the month).

**Inputs — reused metrics only, never raw transactions:**

```
categoryRemaining (Fact)
Days Remaining
Recommended Daily Spend
Spending Pace
```

Recovery Plan never queries transactions itself and never reads
`savingsPool`. Reusing already-computed metrics instead of raw data keeps
the dependency graph exactly what Phase 2.0's dependency graph already
described — Recovery Plan depends on Recommended Daily Spend, which is
downstream of Days Remaining and `categoryRemaining`, and now also reads
Spending Pace as a sibling — no new root dependency is introduced.

**Decision, frozen: never recommend Savings.** Even if `savingsPool` has
already absorbed real overspend, this metric never says "use your
savings" — it says "Your Food budget is exhausted, try spending less in
other categories." The Engine may already have moved money into Savings
by the time this runs; explaining *that it happened* is the Chatbot's
job once the Engine has acted (a description of a past event), not this
metric's job to *recommend* it prospectively. Recovery Plan is about
future behavior, not money movement — this line is what keeps "Savings
is the last resort" from being quietly undermined by a well-meaning
recovery feature.

**Decision, frozen: optimize for followable, not for mathematically
exact.** Rs 183.42/day is correct arithmetic and useless advice; nobody
plans a day around 42 paisa. The daily target is rounded to a number a
person can actually hold in their head — never the raw division result.

**Decision, frozen: don't overfit to one category.** If Food is
exhausted and Transport has plenty of buffer, this metric never says
"spend exactly Rs 30 less on Food" (Food already has nothing left to cut
from — that instruction is impossible to follow). It only names Food as
the affected category; wording something like "keep Food spending low
for the next few days" is the Explainer's job downstream, working from
`affectedCategories`, not something this metric fabricates as text
itself.

**The Recovery Window — is recovery even mathematically possible?** Not
every "you're behind" situation can be recovered from with a graceful,
even daily target. If every budgeted category is already fully
exhausted, the honest daily target *is* 0 — the plan should still exist
(it's not "no problem," it's "the worst case"), but it must carry enough
structure for a downstream Explainer to say "this month's budget can no
longer be fully recovered, but reducing spending now will minimize the
impact" instead of pretending optimism. This is why the output includes
a `recoveryPossible` boolean (below) — derived directly from whether any
budgeted-category remaining is still above zero, not a separate
assumption.

**When does a plan even get generated? Trigger conditions — at least one
must be true, otherwise return `null`:**

1. **Spending Pace status is `too_fast`.**
2. **Recommended Daily Spend has dropped significantly below the
   month's even-split baseline** — defined as more than 25% below
   `totalBudget / totalDaysInMonth` (the rate a perfectly even spend from
   Day 1 would have implied). This is the concrete, computable version of
   "dropped significantly" — there is no stored history of previous
   daily recommendations to compare against (nothing in Phase 2 persists
   between calls), so the comparison is against the month's own built-in
   baseline rate instead of a remembered past value. Documented here as
   a deliberate, honest substitution, not silently assumed equivalent.
3. **One or more budgeted categories are already exhausted**
   (`remaining <= 0` for a category with `limit > 0`).

If none of these hold, spending is fine — returning a plan anyway would
be inventing advice nobody needs, exactly what Phase 2.0's "can this
metric ever lie" test exists to catch from the opposite direction (lying
by manufacturing false urgency, not just false calm).

**Additional case where no plan is generated regardless of triggers: no
runway left.** If `daysRemaining <= 1` (the last day of the month), there
is no room to spread an adjustment across multiple future days — the
month is effectively already decided. Also: if Recommended Daily Spend
itself is `null` (no budgets exist at all), there is nothing to recover
against, so no plan is generated either.

**Severity classification:**

| Condition | Severity |
|---|---|
| 2+ budgeted categories exhausted, or the daily target itself is 0 | `high` |
| Exactly 1 budgeted category exhausted | `medium` |
| Triggered only by pace/baseline drop, no category exhausted | `minor` |

**Output shape:**

```
"recoveryPlan": {
  "needed": true,
  "dailyTarget": 180,
  "durationDays": 7,
  "affectedCategories": ["Food"],
  "severity": "medium",
  "recoveryPossible": true,
  "confidence": "medium"
}
```

or `null` when no plan is needed. No English sentences anywhere in this
object — a future Explainer (Phase 6, Chatbot Integration) turns this
structured data into a sentence; this metric only ever returns facts
about what adjustment is needed, never the words describing it.

### Metric Acceptance Criteria

| Criteria | Answer |
|---|---|
| Correct? | Trigger logic and severity classification match the rules above exactly |
| Deterministic? | Same `categoryRemaining`/Days Remaining/Recommended Daily Spend/Spending Pace always produce the same plan (or `null`) |
| Explainable? | "Your Food budget is exhausted, with 7 days left — try keeping the rest of your spending around Rs 180/day." |
| Independent? | UI/Chat read the structured fields directly; wording is composed downstream, never a re-derivation of the trigger logic |
| Tested? | Unit tests below + real-account verification |
| API Ready? | Added to `GET /financial-metrics` as a sibling field |
| UI Ready? | A simple card on Reports (not a popup, not Home) |
| Consistent with Product Philosophy? | Never reads or recommends `savingsPool`; frames adjustment as recovery, never punishment |

### Test plan (written before implementation, run after)

- Normal month (on pace, no exhausted categories, no significant drop) → `null`
- Spending Pace `too_fast` → plan exists
- One budgeted category exhausted → plan exists, `medium` severity
- No budgets at all → `null`
- Last day of the month (`daysRemaining <= 1`) → `null`
- Two or more budgeted categories exhausted → `high` severity

### UI

Not a popup — never interrupts. A simple card on **Reports**, in the
slot already reserved there for exactly this ("Reserved spot for future
'suggestions/alerts' teaser," `reports_screen.dart`): "Try staying
around Rs 180/day for the next 6 days." Home is left alone; this is
Reports' feature, not Home's.

### Chat (future, not built this phase)

Per explicit product direction: **chat wording must always use simple
language** — short, plain sentences, never financial jargon, never a
scolding tone. Recorded here so whenever Phase 6 (Chatbot Integration)
builds the actual Explainer that turns `recoveryPlan` into a reply, it
starts from this standard rather than rediscovering it. Example of the
target tone: "Food went over budget today. If you keep Transport under
Rs 100/day for the next week, you'll still finish the month
comfortably." — generated from `recoveryPlan`'s fields, never invented
independently by the chatbot.

**Not started yet.** This design — the one-question framing, the
never-recommend-Savings decision, practical rounding, the Recovery
Window / `recoveryPossible` concept, trigger conditions (including the
honest substitution for "dropped significantly"), severity
classification, edge cases, acceptance criteria, and test plan — is the
freeze before any Phase 2.5 code. Implementation follows on the user's
go-ahead, same as Phases 2.1-2.4.

### Phase 2.5 — Done (2026-07-18)

Implementation:

- `services/metrics_engine.py` — added `_practical_round()` (rounds to
  the nearest 5 under Rs 50, nearest 10 above — a small amount never
  rounds away to 0 just because it's under 10) and
  `compute_recovery_plan(category_remaining, days_remaining,
  total_budget, total_days_in_month, recommended_daily_spend,
  spending_pace)` — a pure function taking already-computed metrics as
  input, never querying transactions or `savingsPool` itself.
  `get_metrics()` now computes `recommended_daily_spend` and
  `spending_pace` as local variables first, then threads both into
  `compute_recovery_plan()` alongside `total_budget`/
  `total_days_in_month` (already computed for Spending Pace, reused
  rather than recomputed).
- `frontend/lib/screens/reports_screen.dart` — `_loadReport()` now also
  fetches `/financial-metrics` (three parallel calls via `Future.wait`),
  storing `_recoveryPlan` (nullable). New `_buildRecoveryPlanCard()`
  composes a plain-language sentence from the structured fields
  (`dailyTarget`, `durationDays`, `recoveryPossible`,
  `affectedCategories`) — sentence composition only, no financial math —
  placed in the slot the screen had already reserved for exactly this
  ("suggestions/alerts teaser"). Never a popup; never shown on Home.

**Metric Acceptance Criteria — all eight checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — trigger logic and severity classification verified against live data |
| Deterministic? | Yes — 8 unit tests pin exact input/output pairs |
| Explainable? | Yes — "Your Food budget is exhausted, with 14 days left — try keeping the rest of your spending around Rs 5/day." |
| Independent? | Yes — the Reports card only templates text from already-computed fields, no re-derivation |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (8 new scenarios, all passing) + real-account verification |
| API Ready? | Yes — `recoveryPlan` added to `GET /financial-metrics` |
| UI Ready? | Yes — a simple card on Reports, in the already-reserved slot |
| Consistent with Product Philosophy? | Yes — the implementation never reads `savingsPool`; verified by inspection, not just by absence of a bug |

**Unit tests** (all passing, 39 total across five phases now): normal
month → `null`; `too_fast` pace with no exhausted category → plan
exists, `minor` severity; one exhausted category → plan exists, `medium`
severity; no budgets → `null`; last day (`daysRemaining<=1`) → `null`
regardless of triggers; two+ exhausted categories → `high` severity;
every budgeted category exhausted → `high` severity with
`recoveryPossible: false` and `dailyTarget: 0`; Recommended Daily Spend
significantly below the month's even-split baseline (no exhausted
category, pace not `too_fast`) → plan still exists via the third trigger.

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`, Day 18 of 31, the same account already sitting in a
`too_fast`/Food-exhausted state from prior phases' verification): a plan
was correctly generated — `dailyTarget: 5` (`_practical_round(60/14 ≈
4.29) = 5`), `durationDays: 14`, `affectedCategories: ["Food"]`,
`severity: "medium"`, `recoveryPossible: true` — matching a manual
calculation from the same `categoryRemaining` data exactly. This is a
genuinely useful confirmation: the account's real state independently
satisfied the trigger conditions without any synthetic setup, so this
verification exercised the actual trigger logic, not just a
hand-constructed scenario.

**Frontend verification**: `dart analyze` clean on `reports_screen.dart`
(zero issues); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification depth
as every prior UI phase.

**Recovery Plan is Done, per every row of the Metric Acceptance Criteria
table, including the Product Philosophy check.** Per the user's own
suggestion, Phase 2 now pauses for a design review across all five
metrics together — Days Remaining, Budget Utilization, Recommended
Daily Spend, Spending Pace, Recovery Plan — before Phase 2.6 (Category
Pressure) begins, to catch overlapping responsibilities while they're
still cheap to simplify, before Health (Phase 3), Recommendations
(Phase 4), and Notifications (Phase 5) start depending on them.

---

## Phase 2 Review & Freeze (2026-07-18)

Before Phase 2.6, all five shipped metrics were reviewed together for
overlap, since changing a formula gets much harder once Health,
Recommendations, Notifications, and Chat all depend on it.

### Redundancy check — result: none found

| Phase | Metric | Question it answers |
|---|---|---|
| 2.1 | Days Remaining | How much time is left? |
| 2.2 | Budget Utilization | How much of each budget have I used? |
| 2.3 | Recommended Daily Spend | How much should I aim to spend each day? |
| 2.4 | Spending Pace | Am I spending faster or slower than the month is progressing? |
| 2.5 | Recovery Plan | If I'm off track, what adjustment should I make? |

Every metric answers a genuinely different question; none is a renamed
recomputation of another. All five: ✅ Keep.

### The four layers — a cleaner mental model than a flat metric list

```
Layer 1 — Facts             Days Remaining, Budget Utilization
Layer 2 — Interpretation     Spending Pace
Layer 3 — Guidance           Recommended Daily Spend, Recovery Plan
Layer 4 — Prediction         Projected Savings (Phase 2.7, not yet built)
```

This is the same classification as "Metric type — Descriptive,
Analytical, Advisory, Predictive" above, renamed to the layer framing
because it reads more naturally as a pipeline (facts flow up into
interpretation, interpretation into guidance, guidance into prediction)
than as a flat per-metric label table. Both names refer to the same four
categories — Facts=Descriptive, Interpretation=Analytical,
Guidance=Advisory, Prediction=Predictive.

### Corrected, code-verified dependency tree

The Phase 2.0-era dependency graph (above) was written before
Phases 2.4-2.5 were actually implemented, and got two things wrong once
real code existed to check it against. Corrected here against the actual
`services/metrics_engine.py`, not the original plan:

```
Financial Engine (financialSummary)
        │
        ▼
──────────────────────────────
 Layer 1 — Facts
──────────────────────────────
Days Remaining              (date + monthKey only)
Budget Utilization          (categoryRemaining only)
        │
        ▼
──────────────────────────────
 Layer 2 — Interpretation
──────────────────────────────
Spending Pace                (totalSpent + categoryRemaining limits +
                               elapsed/total days-in-month — all Facts;
                               does NOT consume the Days Remaining or
                               Budget Utilization metric outputs)
        │
        ▼
──────────────────────────────
 Layer 3 — Guidance
──────────────────────────────
Recommended Daily Spend       (categoryRemaining + Days Remaining)
Recovery Plan                 (categoryRemaining + Days Remaining +
                               Recommended Daily Spend + Spending Pace —
                               does NOT consume Budget Utilization)
        │
        ▼
──────────────────────────────
 Layer 4 — Prediction
──────────────────────────────
Projected Savings (Phase 2.7, not yet built)
        │
        ▼
──────────────────────────────
 Phase 3 — Health Engine
──────────────────────────────
        │
        ▼
Phase 4 — Recommendation Engine
        │
        ▼
Phase 5 — Notification Engine
        │
        ▼
Phase 6 — Chatbot
```

**Two corrections from the original plan, worth naming explicitly:**

- **Spending Pace does not depend on Days Remaining or Budget
  Utilization.** It independently computes `elapsed_days`/
  `total_days_in_month` (via `utils.get_days_passed_in_month`/
  `get_total_days_in_month`) and `total_budget` (its own aggregation of
  `categoryRemaining` limits) — the same underlying Facts Days Remaining
  and Budget Utilization also read, but not their computed *outputs*.
  This matters for tracing: editing Days Remaining's formula cannot
  silently change Spending Pace's result, because Spending Pace never
  reads it.
- **Recovery Plan does not depend on Budget Utilization.** It reads
  `categoryRemaining` directly to find exhausted categories (`remaining
  <= 0`), not `budgetUtilization`'s percentage output. The two metrics
  happen to be derived from the same underlying Fact but are separate
  reads, not a chain.

### Metric Dependency Ledger (`dependsOn`, documented now — not yet a runtime field)

Per the suggestion to introduce traceability metadata: each metric's
real inputs, listed precisely enough to answer "if I change X, what
could this metric's output change?" This is documentation only for
now — matching the same "document first, promote to a runtime field
later if needed" treatment Section 5 already gave `financialSummary`'s
aspirational future fields. **Not yet added to the actual API
response** — `GET /financial-metrics`'s per-metric objects still only
carry `value`/`confidence` (Advisory/Predictive) or a bare value
(Facts/Analytical); this ledger is the source of truth to promote from
if/when a runtime `dependsOn` field is actually built.

| Metric | Depends on (code-verified) |
|---|---|
| Days Remaining | Current date, requested `monthKey` |
| Budget Utilization | `categoryRemaining` (per-category `limit`/`spent`) |
| Recommended Daily Spend | `categoryRemaining` (per-category `limit`/`remaining`), Days Remaining |
| Spending Pace | `totalSpent`, `categoryRemaining` limits (aggregated into `totalBudget`), elapsed days / total days in month |
| Recovery Plan | `categoryRemaining`, Days Remaining, `totalBudget`, total days in month, Recommended Daily Spend, Spending Pace |

### Phase 2 Freeze

**Formulas for these five metrics are frozen as of this review.** Phase
3 (Health Engine) is built to trust them completely — it consumes their
outputs, it does not recompute its own version of any of them (the
architectural note in Phase 2.4's design already committed to this: Health
consumes Budget Utilization + Spending Pace + Recommended Daily Spend
rather than re-deriving thresholds from raw `spent`/`limit`). Changing a
formula after Phase 3 depends on it becomes a breaking change to
whatever consumed it, not a free edit — that's the whole reason this
review happens now, while the cost of a change is still just "edit one
function and its tests," not "audit every downstream consumer."

### What's still missing — Phase 2.6 and 2.7, unchanged from the existing Build Roadmap

- **Phase 2.6 — Category Pressure.** Answers "which category is most
  likely to become a problem," not "how much have I spent" (that's
  already Budget Utilization) — the same 95%-used-with-14-days-left vs.
  95%-used-with-1-day-left distinction Spending Pace already established
  at the whole-budget level, applied per category.
- **Phase 2.7 — Projected Savings.** The only Predictive metric — "if
  everything continues like today, how much savings will likely
  remain," explicitly a forecast, never presented as the actual current
  `savingsPool` fact.

Both remain designed-but-not-built, in the same order the Build Roadmap
already listed them (Section "Build Roadmap," and "Phase 2 build order
(revised)" above) — this review didn't reorder them, only confirmed the
five already-shipped metrics don't need rework before they're built.

---

## Phase 2.6 — Category Pressure

Shifts the question from "how much have I spent" (Budget Utilization) to
**"where am I most likely to get into trouble?"** — the first per-category
metric that reasons about risk rather than just usage.

### Design

**Scope**: Per Category. **Type**: Analytical. **Confidence: High,
always** — same reasoning as Spending Pace: this describes only
already-trusted current data (spent, limit, elapsed/total days), no
assumption about future behavior.

**What this is *not*** (decided before anything else, to keep it from
drifting into another metric's job):

- Not Budget Utilization with a different name — utilization alone can't
  distinguish "95% used, 2 days left" (fine) from "95% used, 15 days
  left" (a real problem); pressure requires *both* utilization and time.
- Not a health color — that's Phase 3's job, consuming this metric.
- Not a recommendation — that's Recovery Plan's job.
- Not a prediction — it only describes the current combination of
  utilization and time, nothing about the future.

**The one question this metric answers:**

> "Which category needs my attention first?"

**Formula — the same shape as Spending Pace, applied per category
instead of globally:**

```
categoryBudgetProgress = categoryRemaining[cat].spent / categoryRemaining[cat].limit
monthTimeProgress      = elapsedDays / totalDaysInMonth
pressure               = categoryBudgetProgress - monthTimeProgress
```

**Decision, frozen: independently recomputed time progress, never
consumes Spending Pace's or Days Remaining's output.** This follows
directly from the correction the Phase 2 Review just made explicit —
Category Pressure reads the same underlying date Facts
(`elapsedDays`/`totalDaysInMonth`) Spending Pace also reads, rather than
depending on Spending Pace's computed `difference`. Each metric depends
on the minimum it actually needs.

**No clamping.** An already-over-budget category (`categoryBudgetProgress`
> 100%) produces a pressure above what any threshold needs, correctly
landing in `high` — the same "don't hide the real magnitude" decision
already made for Budget Utilization and Spending Pace.

**Classification:**

| Difference | Status |
|---|---|
| ≤ −0.20 | `low` |
| −0.20 to +0.10 | `normal` |
| +0.10 to +0.30 | `medium` |
| \> +0.30 | `high` |

(Different thresholds from Spending Pace's global classification —
per-category volatility is naturally noisier than the whole-budget
aggregate, so a wider "normal" band and a stricter "low" cutoff avoid
flagging every small category swing as pressure. Both threshold tables
are first cuts, expected to be tuned later, same caveat as Spending
Pace's.)

**Edge cases, decided in advance:**

- **A category with no budget set** (`limit <= 0`) — simply omitted from
  the per-category map entirely; there's no usable budget to compare
  progress against, so there's nothing to compute (same reasoning Budget
  Utilization used, applied here as "don't include" rather than "include
  as 0%," since this metric already returns a sparse map — see Output
  shape).
- **No category has a budget at all** → the whole metric returns `null`
  — nothing to rank, nothing to compute.
- **A new category** (`spent = 0`, `limit > 0`) — `categoryBudgetProgress
  = 0`, so `pressure` is negative (as negative as `monthTimeProgress`) —
  correctly reads as low pressure, not an error case.

**Output shape** — two parts, deliberately not merged into one flat
object: a per-category map (`byCategory`), and a ranked
`priorityOrder` array. They're kept as siblings under one
`categoryPressure` object rather than mixing category names and the
literal key `"priorityOrder"` into the same dict, which would collide if
a category were ever named "priorityOrder" and, more importantly, would
make "is this key a category or a control field" ambiguous to any
consumer:

```
"categoryPressure": {
  "byCategory": {
    "Food":      { "pressure": 0.35,  "status": "high", "confidence": "high" },
    "Transport": { "pressure": -0.20, "status": "low",  "confidence": "high" }
  },
  "priorityOrder": ["Food", "Transport"]
}
```

or `"categoryPressure": null` if no category has a budget.

**`priorityOrder` — the single shared ranking every later phase reads
instead of independently sorting.** Categories sorted by `pressure`
descending (highest pressure first). This is the concrete mechanism
behind "Health looks at Food first, Recovery Plan mentions Food first,
Notifications warn about Food first, Chat starts by discussing Food" —
one ranking computed once, in one place, rather than four different
subsystems each re-deriving their own "which category matters most" and
risking disagreement the way the three duplicate health-status
implementations already did before Phase 1.9.

### Metric Acceptance Criteria

| Criteria | Answer |
|---|---|
| Correct? | `(spent/limit) − (elapsedDays/totalDaysInMonth)` per category, exactly |
| Deterministic? | Same `categoryRemaining` + date always produce the same pressure/status/order |
| Explainable? | "Food is 95% spent while the month is 60% through — that's well ahead of pace, the highest pressure of any category." |
| Independent? | UI reads `.status`/`priorityOrder` directly, computes nothing |
| Tested? | Unit tests below + real-account verification |
| API Ready? | Added to `GET /financial-metrics` as `categoryPressure` |
| UI Ready? | Small pressure chips on Categories; categories sorted by `priorityOrder`, not alphabetically or by budget size |
| Consistent with Product Philosophy? *(N/A — Analytical, not Advisory)* | Makes no recommendation, so nothing to check against the savings-last rule |

### Test plan (written before implementation, run after)

- Perfect pace (category progress == month progress) → `normal`
- Ahead (category progress well below month progress) → `low`
- Behind (category progress well above month progress) → `high`
- Over budget (`categoryBudgetProgress` > 100%) → `high`, not clamped
- No budget set at all → `null`
- Multiple categories → each computed independently, `priorityOrder`
  correctly ranks highest-pressure first

### API

```
GET /financial-metrics?monthKey=2026-07

{
  "success": true,
  "data": {
    ...,
    "categoryPressure": {
      "byCategory": {
        "Food": { "pressure": 0.35, "status": "high", "confidence": "high" },
        "Transport": { "pressure": -0.20, "status": "low", "confidence": "high" }
      },
      "priorityOrder": ["Food", "Transport"]
    },
    "metadata": { ... }
  }
}
```

### UI

No new screen. On Categories: a small chip per card ("High Pressure" /
"Medium Pressure" / "Low Pressure" — `normal` status shows no chip, to
avoid labeling every unremarkable category), and **categories sorted by
`priorityOrder`, not alphabetically or by budget size** — the most
actionable ordering, per the explicit recommendation. Phase 3 replaces
these text chips with colors; the ranking itself doesn't change.

**Not started yet.** This design — what it is not, the one-question
framing, the per-category pace formula, independently-recomputed time
progress, classification thresholds, no-clamping, edge cases, the
`byCategory`/`priorityOrder` output shape and its collision-avoidance
reasoning, acceptance criteria, and test plan — is the freeze before any
Phase 2.6 code. Implementation follows on the user's go-ahead, same as
every prior Phase 2 metric.

### Phase 2.6 — Done (2026-07-18)

Implementation:

- `services/metrics_engine.py` — added `_classify_pressure()` (its own
  threshold table, deliberately different from `_classify_pace`'s — a
  wider "normal" band since per-category swings are noisier than the
  whole-budget aggregate) and `compute_category_pressure(category_remaining,
  elapsed_days, total_days)`. `get_metrics()` now stores `elapsed_days` as
  a local variable (previously computed inline only for Spending Pace)
  and reuses it here — the same underlying date Facts, never Spending
  Pace's or Days Remaining's computed output, per the Phase 2 Review's
  dependency correction.
- `frontend/lib/screens/categories_screen.dart` — `_fetchFinancialSummary()`
  now also reads `categoryPressure` from the same `/financial-metrics`
  response already fetched for Budget Utilization; attaches
  `pressureStatus` onto each `_budgets` entry and stores `_priorityOrder`.
  `_buildDisplayList()` now sorts by `_priorityOrder` first, falling back
  to the curated `_catMeta` order only for a budgeted category
  `priorityOrder` doesn't cover (so nothing silently disappears if
  `categoryPressure` is null). `_buildBucketCard` gained a small pressure
  chip ("High Pressure" / "Medium Pressure" / "Low Pressure" — `normal`
  shows none) below the progress bar.

**Metric Acceptance Criteria — all eight checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — `(spent/limit) − (elapsedDays/totalDaysInMonth)` per category, verified against live data |
| Deterministic? | Yes — 6 unit tests pin exact input/output pairs |
| Explainable? | Yes — "Food is 90% spent while the month is 58% through — the highest pressure of any category." |
| Independent? | Yes — Categories reads `.status`/`priorityOrder` directly, computes nothing |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (6 new scenarios, all passing) + real-account verification |
| API Ready? | Yes — `categoryPressure` added to `GET /financial-metrics` |
| UI Ready? | Yes — pressure chips + `priorityOrder`-based sort on Categories |
| Consistent with Product Philosophy? | N/A (Analytical, not Advisory) — makes no recommendation |

**Unit tests** (all passing, 45 total across six phases now): perfect
pace → `normal`; ahead → `low`; behind → `high`; over budget → `high`,
not clamped (verified exact value `1.0`, not flattened); no budget at
all → `null`; two categories independently classified with
`priorityOrder` correctly ranking the higher-pressure category first.

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`, Day 18 of 31, `elapsedDays=18`/`totalDays=31` →
`timeProgress≈58.06%`): `Food` (spent 520/limit 520, 100% used) →
`pressure: +0.4194 → high`; `Transport` (spent 20/limit 80, 25% used) →
`pressure: -0.3306 → low`; `priorityOrder: ["Food", "Transport"]`. Every
value cross-checked against an independent manual calculation from the
same `categoryRemaining` data — exact match.

**Frontend verification**: `dart analyze` clean on
`categories_screen.dart` (only the same pre-existing `const`-constructor
info hints noted since Phase 1.9); app rebuilt and booted successfully in
Chrome (Dart VM Service came up, no compile or runtime errors) — same
verification depth as every prior UI phase.

**Category Pressure is Done, per every row of the Metric Acceptance
Criteria table.** With this, `priorityOrder` exists as the one shared
ranking Phase 3 (Health), Phase 4 (Recommendations), Phase 5
(Notifications), and Phase 6 (Chat) can all read instead of each
independently deciding which category matters most. Phase 2.7
(Projected Savings) is next — the last metric in Phase 2, and the only
Predictive one — on separate confirmation.

---

## Phase 2.7 — Projected Savings

The last Phase 2 metric, and the first true prediction in the app.
Everything built so far answers "what happened," "what's happening," or
"what should I do today." This one answers a fundamentally different
kind of question — and is treated with the least confidence of anything
in Phase 2 as a direct result.

### Design

**Scope**: Global. **Type**: Predictive — the only Predictive metric in
Phase 2. **Confidence: Low or Medium, never High** — unlike Spending
Pace or Category Pressure, this assumes future behavior continues, so it
can never claim the same trust already-observed data gets.

**The one question this metric answers:**

> "How much money will I probably have left at the end of this month?"

Not "can you save more" (that's coaching, out of scope), not "are you
healthy" (Phase 3). Just a forecast — and the word "probably" is load
bearing, not decoration.

**Decision, frozen: built from Spending Pace, never from raw
transactions.** The chain is:

```
Facts → Budget Utilization → Spending Pace → Projected Savings
```

not a second, parallel path straight from transactions to a prediction.
Spending Pace already computes `budgetProgress` (spent/limit ratio) and
`timeProgress` (elapsed/total days) internally to produce its
`difference` — Projected Savings reuses those same two numbers rather
than re-deriving them, so there is exactly one place spend-rate-vs-time
math happens, not two. **Implementation consequence**: `compute_spending_pace`'s
returned object gains two additional fields, `budgetProgress` and
`timeProgress`, alongside its existing `difference`/`status`/`confidence`
— purely additive, no existing consumer of `difference` is affected.

**Formula — linear extrapolation of the current daily rate to the end of
the month:**

```
rate                     = budgetProgress / timeProgress
projectedTotalSpent      = rate × totalBudget
projectedRemainingBudget = totalBudget − projectedTotalSpent
projectedSavings.value   = savingsPool + projectedRemainingBudget
```

Reading it: `rate` is "how many times faster or slower than an even
pace" the user is spending; multiplying it by `totalBudget` extrapolates
today's average daily spend across the whole month, the same way a
`spent/elapsedDays` daily average, projected across `totalDays`, would —
except expressed in terms Spending Pace already computed, per the
frozen chain above.

**Decision, frozen: no clamping, in either direction.** An already
overspending user can get a negative `projectedSavings.value` — a
projected deficit is a real, meaningful forecast (see Recovery Plan's
own "recovery may not be fully possible" honesty, Phase 2.5), and
flooring it at 0, or worse, silently floor-clamping toward
`savingsPool` to look less alarming, would be exactly the kind of
false optimism Phase 2.0's design pass exists to prevent. Equally: a
user who stops spending shouldn't have their improved projection capped
at some arbitrary ceiling either.

**Decision, frozen: confidence tracks how much of the month remains, not
the spending pace itself.** The more time still ahead, the more
opportunity there is for behavior to change before this projection is
ever tested — so confidence is **Low** when more than half the month
remains, **Medium** once less than half remains. This is also an honest
acknowledgment of the metric's own instability: on Day 1 of the month, a
single day's spending extrapolated across 30 days can swing wildly
(`timeProgress` is tiny, so `rate` is highly sensitive to small
`budgetProgress` changes) — Low confidence names that instability
instead of hiding it. Near month-end, `timeProgress` approaches 1.0 and
the projection naturally converges toward the *actual* current
`remainingBudget` (see the Last Day edge case below) — Medium reflects
that convergence.

**Wording principle, carried into any future UI/Chat surface**: never
"You will save Rs 2,000" (a guarantee). Always "If your current spending
continues, you may finish with about Rs 2,000" (an explicit forecast,
naming its own assumption). The `≈` symbol in any numeric display
communicates the same uncertainty visually.

**Edge cases, decided in advance:**

- **No budgets at all** — Spending Pace itself already returns `null`
  when `totalBudget <= 0` (Phase 2.4's own edge case); Projected Savings
  inherits this directly — if there's no pace to build on, there's
  nothing to project. Returns `null`, not a fabricated forecast.
- **User stops spending** — `budgetProgress` growth halts while
  `timeProgress` keeps advancing, so `rate` falls and the projection
  rises call over call. No special case needed — falls out of the
  formula naturally.
- **User keeps overspending** — `rate` stays high or climbs, the
  projection falls call over call, potentially negative. Also falls out
  naturally.
- **Already overspent this month** — `projectedRemainingBudget` can be
  negative; the value can legitimately be `0` or negative. Never
  artificially forced positive.
- **First day of the month** (`elapsedDays` small) — `timeProgress` is
  small, so `rate` (and therefore the projection) can swing hard on a
  single transaction. Not special-cased in the formula — it's exactly
  why confidence is `low` this early, rather than the formula pretending
  stability it doesn't have.
- **Last day of the month** (`timeProgress ≈ 1.0`) — `rate ≈
  budgetProgress`, so `projectedTotalSpent ≈` the actual current
  `totalSpent`, and `projectedSavings.value` converges to
  `savingsPool + remainingBudget` — the same already-established
  identity (Phase 1.9's Categories screen) for *actual* current net
  savings. The prediction and reality collapse into the same number
  exactly when there's no more time left to predict over — no special
  case needed, and confidence correctly shifts to `medium` per the rule
  above.

**Output shape** — `value`/`confidence`, the same shape every other
Advisory/Predictive metric already uses, plus one new field,
`assumption`, naming the forecast's own premise so a consumer (UI, Chat)
never has to guess why the number might be wrong:

```
"projectedSavings": {
  "value": 1800.0,
  "confidence": "low",
  "assumption": "current_spending_continues"
}
```

or `null` if there's no budget to project from.

### Metric Acceptance Criteria

| Criteria | Answer |
|---|---|
| Correct? | `savingsPool + totalBudget×(1 − budgetProgress/timeProgress)`, exactly |
| Deterministic? | Same Spending Pace inputs + `totalBudget`/`savingsPool` always produce the same projection |
| Explainable? | "If your current spending pace continues, you may finish the month with about Rs 1,800." |
| Independent? | UI reads `.value`/`.confidence`/`.assumption` directly, computes nothing |
| Tested? | Unit tests below + real-account verification |
| API Ready? | Added to `GET /financial-metrics` as `projectedSavings` |
| UI Ready? | One simple card, not flashy — "≈ Rs 2,150, based on your current spending pace" |
| Consistent with Product Philosophy? *(N/A — Predictive, not Advisory)* | Makes no recommendation; the philosophy check that matters here is honesty about uncertainty, covered by the wording principle above |

### Test plan (written before implementation, run after)

- Spending exactly on pace (`budgetProgress == timeProgress`) →
  `projectedRemainingBudget == 0` → value equals `savingsPool` exactly
- Spending faster than pace → value decreases below `savingsPool`
- Spending slower than pace → value increases above `savingsPool`
- No budgets at all → `null`
- Overspent month (`rate` well above 1) → value can go negative, not
  clamped
- First day of the month → confidence `low`
- Last day of the month → confidence `medium`, value converges to
  `savingsPool + remainingBudget`
- Confidence is never `high`

### API

```
GET /financial-metrics?monthKey=2026-07

{
  "success": true,
  "data": {
    ...,
    "spendingPace": {
      "difference": 0.12, "status": "slightly_fast", "confidence": "high",
      "budgetProgress": 0.62, "timeProgress": 0.50
    },
    "projectedSavings": {
      "value": 1800.0, "confidence": "low", "assumption": "current_spending_continues"
    },
    "metadata": { ... }
  }
}
```

### UI

Not flashy — one simple card: "Projected End-of-Month Savings — ≈ Rs
2,150 — Based on your current spending pace." Placed on Reports,
alongside the existing Recovery Plan card. The `≈` is not decoration —
it's the single visual cue that this number is a forecast, not a fact.

**Not started yet.** This design — the "build from Spending Pace, not
transactions" chain (and the additive `budgetProgress`/`timeProgress`
fields that requires), the extrapolation formula, no-clamping in either
direction, the confidence-tracks-time-remaining rule, the wording
principle, edge cases (including how Last Day naturally converges to the
already-established `savingsPool + remainingBudget` identity), output
shape, acceptance criteria, and test plan — is the freeze before any
Phase 2.7 code. Implementation follows on the user's go-ahead.

### Phase 2.7 — Done (2026-07-18)

Implementation:

- `services/metrics_engine.py` — `compute_spending_pace()` gained two
  additive fields, `budgetProgress` and `timeProgress`, alongside its
  existing `difference`/`status`/`confidence` (purely additive — no
  existing test or consumer of `difference` needed to change, confirmed
  by the full suite still passing unmodified). New
  `compute_projected_savings(spending_pace, total_budget, savings_pool)`
  reads only those two fields plus `totalBudget`/`savingsPool` — never
  re-sums transactions, never independently recomputes what Spending
  Pace already computed. `get_metrics()` now also extracts `savingsPool`
  from the summary and threads it through.
- `frontend/lib/screens/reports_screen.dart` — `_projectedSavings`
  (nullable), read from the same `/financial-metrics` call already
  fetched for Recovery Plan. New `_buildProjectedSavingsCard()` — one
  simple card, "≈ Rs {value}" with "Based on your current spending
  pace," placed directly below the Recovery Plan card.

**Metric Acceptance Criteria — all eight checked:**

| Criteria | Result |
|---|---|
| Correct? | Yes — `savingsPool + totalBudget×(1 − budgetProgress/timeProgress)`, verified against live data |
| Deterministic? | Yes — 8 unit tests pin exact input/output pairs |
| Explainable? | Yes — "If your current spending pace continues, you may finish the month with about Rs 10,065." |
| Independent? | Yes — Reports reads `.value`/`.confidence` directly, computes nothing |
| Tested? | Yes — `backend/tests/test_metrics_engine.py` (8 new scenarios, all passing) + real-account verification |
| API Ready? | Yes — `projectedSavings` added to `GET /financial-metrics` |
| UI Ready? | Yes — one simple card on Reports, not flashy |
| Consistent with Product Philosophy? | N/A (Predictive, not Advisory) — the relevant check here is honesty about uncertainty (the `≈` symbol, the "may finish with" wording), not the savings-last rule |

**Unit tests** (all passing, 53 total across seven phases now): exactly
on pace → value equals `savingsPool` exactly; faster than pace → value
decreases; slower than pace → value increases; no budgets → `null`;
overspent month → value negative, not clamped; first day → confidence
`low`; last day → confidence `medium`, value converges to the
`savingsPool + remainingBudget` identity exactly; confidence never
`high`.

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`, Day 18 of 31): `budgetProgress=0.90`, `timeProgress=0.5806`
(from the already-verified Spending Pace) → `rate=1.55` →
`projectedSavings.value = 10065.0` (`savingsPool 10395 +
totalBudget(600)×(1−1.55) = 10395 − 330 = 10065`), `confidence: medium`.
Cross-checked against an independent manual calculation from the same
numbers — exact match.

**Frontend verification**: `dart analyze` clean on `reports_screen.dart`
(only pre-existing `const`-constructor info hints); app rebuilt and
booted successfully in Chrome (Dart VM Service came up, no compile or
runtime errors) — same verification depth as every prior UI phase.

**Projected Savings is Done, per every row of the Metric Acceptance
Criteria table.**

---

## Phase 2 Complete — Metrics Engine Frozen (2026-07-18)

All seven metrics are built, tested, and verified live:

| Phase | Metric | Type | Status |
|---|---|---|---|
| 2.1 | Days Remaining | Descriptive/Facts | ✅ Done |
| 2.2 | Budget Utilization | Descriptive/Facts | ✅ Done |
| 2.3 | Recommended Daily Spend | Advisory/Guidance | ✅ Done |
| 2.4 | Spending Pace | Analytical/Interpretation | ✅ Done |
| 2.5 | Recovery Plan | Advisory/Guidance | ✅ Done |
| 2.6 | Category Pressure | Analytical/Interpretation | ✅ Done |
| 2.7 | Projected Savings | Predictive/Prediction | ✅ Done |

53 unit tests, all passing. Every metric independently verified against
`botbachat@gmail.com` and cross-checked by hand. Every metric has its own
UI surface (Home: Days Remaining, Recommended Daily Spend, Spending
Pace; Categories: Budget Utilization, Category Pressure; Reports:
Recovery Plan, Projected Savings). `GET /financial-metrics` is the one
endpoint all seven live behind, growing one field per phase, exactly as
planned in Phase 2.0.

**Phase 2 is now frozen, the same declaration Phase 1 got at its own
completion milestone.** Phase 3 (Health & Risk Engine) is built to
consume these seven metrics completely — it does not recompute any of
them, per the architectural decision already made explicit in Phase
2.4's design and reaffirmed in the Phase 2 Review. The two biggest
architectural foundations of BachatBot are both complete:

```
Phase 1    Financial Engine     — a trusted source of financial truth
Phase 1.5  Migration            — every route writes raw data + recomputes
Phase 1.9  UI reads Engine      — every screen reads financialSummary
Phase 2    Metrics Engine       — a trusted source of financial interpretation
                                  (Days Remaining, Budget Utilization,
                                   Recommended Daily Spend, Spending Pace,
                                   Recovery Plan, Category Pressure,
                                   Projected Savings)
    │
    ▼
Phase 3    Health & Risk Engine       — consumes Phase 2's outputs, decides healthy/at-risk
Phase 4    Recommendation Engine      — consumes Advisory + Predictive metrics
Phase 5    Notification Engine        — consumes Health + Recovery Plan, decides when to interrupt
Phase 6    Chatbot Intelligence       — consumes everything, explains it in plain language
Phase 7    Reports & Insights         — display-only, no new calculations
```

Everything from Phase 3 onward is product-focused, not architectural —
each new engine consumes what Phase 1 and Phase 2 already built rather
than inventing its own financial or interpretive logic. That separation
is the entire point of the discipline behind this spec.

---

## Phase 2 Retrospective (2026-07-18)

One page, written before Phase 3 starts, so the reasoning behind Phase
2's decisions doesn't have to be re-derived from scratch six months from
now. Not a metric, not a design freeze — a record of what actually
happened during Phase 2, kept for the same reason Section 9 (Bugs Found
During Migration) was kept for Phase 1.

### What worked well

- **One metric, one full cycle, every time** (Design → Implement → Unit
  Test → Real-account Test → API → UI → Done) caught every issue at the
  cheapest possible point — before the next metric could build on a
  wrong assumption. No metric was ever built, then reworked after the
  next one exposed a problem in it.
- **Real-account verification against `botbachat@gmail.com` on every
  single phase**, not just unit tests — this is what actually caught the
  dependency-graph inaccuracies (below), not code review alone.
- **The Metric Acceptance Criteria table**, borrowed directly from Phase
  1.9's Financial Formula Elimination discipline, forced an honest
  "not done yet" rather than rounding a partial implementation up to
  "complete."
- **Additive-only schema evolution** — `metricsEngineVersion` versioning,
  `budgetProgress`/`timeProgress` added to Spending Pace's existing
  return shape — meant seven metrics shipped with zero breaking changes
  to any earlier one.

### What changed during implementation

- The Metrics Engine's `metadata` shape changed from Phase 2.1's ad hoc
  `version` field to Phase 2.2's proper `metricsEngineVersion`/
  `generatedAt`/`generationMs` versioning scheme, once the idea of
  giving the Metrics Engine its own independent version (mirroring
  `financial_engine.py`'s `ENGINE_VERSION`) was raised.
- Categories' sort order changed from the curated/fixed `_catMeta`
  order to Category Pressure's `priorityOrder` — a genuine behavior
  change driven by a new metric's output, not just a data-source swap
  like every earlier Phase 1.9 migration.
- `compute_spending_pace`'s return shape grew two fields
  (`budgetProgress`/`timeProgress`) mid-Phase-2 specifically so
  Projected Savings could be built on top of it instead of duplicating
  its math — an example of a metric's shape being revised *because* of
  something built two phases later, not planned from day one.

### Assumptions that proved wrong

- **The Phase 2.0 dependency graph assumed metrics would chain off each
  other's computed outputs** (Spending Pace consuming Days Remaining;
  Category Pressure and Recovery Plan consuming Budget Utilization).
  Once Phases 2.4-2.6 were actually implemented, this turned out false —
  each metric independently reads the same underlying Facts instead.
  Caught and corrected at the Phase 2 Review, before Phase 3 could
  inherit a wrong mental model of what depends on what.
- **"Savings Stability" (the original name for what became Projected
  Savings) implied a qualitative judgment** ("is it stable?") rather
  than the numeric forecast the metric actually needed to be. Renamed
  before any code existed once this mismatch was noticed.

### Assumptions that proved correct

- **"Every metric answers exactly one question"** held for all seven
  metrics with zero overlap found at the Phase 2 Review's redundancy
  check — none turned out to be a renamed recomputation of another.
- **The Ladder (Facts→Calculations→Guidance→Predictions→Coaching) and
  the Metric Type/Scope classification**, both fixed in Phase 2.0 before
  a single metric was built, correctly predicted every later acceptance
  rule (the Product Philosophy check applying only to Advisory metrics,
  confidence rules tracking assumption-dependence) without needing
  revision once real metrics existed to test them against.
- **"Reuse the exact same date source, don't invent another one"**
  (Days Remaining's founding design rule) held for every later
  date-dependent metric — Spending Pace, Category Pressure, and
  Projected Savings all read `elapsedDays`/`totalDaysInMonth` from the
  same `utils` functions, never a second parallel time calculation.

### Which metrics needed redesign before implementation

- **Safe Spending → Recommended Daily Spend** — renamed before any code
  existed, because "safe" implied a guarantee the data couldn't back;
  also explicitly redefined to exclude Savings Pool from the formula,
  closing off a framing that would have implicitly treated Savings as
  available to spend.
- **Spending Pace** — two interpretations (restating Budget Utilization;
  today's spending alone) were considered and rejected before landing on
  budget-progress-vs-time-progress. This entire redesign happened at the
  design stage; no code was ever thrown away.
- **Category Pressure** — needed an explicit "this is not Budget
  Utilization renamed" framing before design could proceed, and needed
  its own classification thresholds (a wider "normal" band) rather than
  reusing Spending Pace's, once per-category volatility was considered.
- **Recovery Plan** — the "Recommended Daily Spend dropped significantly"
  trigger condition needed a substitute definition (comparison against
  the month's even-split baseline rate) once it became clear nothing in
  Phase 2 persists a history of prior daily recommendations to compare
  against.

### Why the final formulas were chosen (so this never has to be re-derived)

- **Recommended Daily Spend** divides remaining *category* budgets — not
  `remainingBudget + savingsPool` — by days remaining, specifically to
  keep Savings as the last resort, never implicitly available.
- **Spending Pace** compares budget progress to time progress rather
  than a raw daily-transaction average, because time is what makes a
  spend number meaningful: Rs 5,000 spent by Day 5 and Rs 5,000 spent by
  Day 28 are very different situations, and only a time-aware comparison
  distinguishes them.
- **Category Pressure** reuses Spending Pace's exact progress-vs-time
  shape, applied per category, rather than inventing a separate "risk
  score" formula — keeping the two metrics conceptually parallel instead
  of introducing a second kind of math into the Metrics Engine.
- **Recovery Plan**'s daily target is rounded to the nearest 5 or 10 —
  never a raw decimal — because a number the user can actually follow
  was explicitly prioritized over mathematical precision.
- **Projected Savings** extrapolates Spending Pace's own
  `budgetProgress`/`timeProgress` rather than re-deriving totals from
  scratch, so there is exactly one place in the entire Metrics Engine
  where spend-rate-vs-time math happens, not two competing
  implementations of the same idea.

**Phase 3 (Health & Risk Engine) starts on separate confirmation.** Per
the frozen architectural rule for it: Health consumes Budget Utilization,
Spending Pace, Recovery Plan, Category Pressure, and Projected Savings —
it never computes money, never sums transactions, never divides a budget
itself. If Health ever starts doing arithmetic Phase 2 already does, that
is the duplication this entire phase existed to remove, reappearing one
layer up.

---

## Phase 3.0 — Health Philosophy (Design Only)

Phase 1 and Phase 2 had objectively correct answers — a formula either
matches the definition or it doesn't. Health is the first phase that is
**judgment, not calculation**, and judgment demands stronger product
decisions frozen before code, not just a correct formula.

### The four rules, frozen before any Phase 3 code

**Rule 1 — Health never computes financial values.** It consumes the
Financial Engine (raw Facts like `categoryRemaining[cat].limit`,
strictly for context, never for deriving a new financial number) and the
Metrics Engine (Budget Utilization, Spending Pace, Recovery Plan,
Category Pressure, Projected Savings). It never sums, divides, or
re-derives anything Phase 1 or Phase 2 already computed. If Health ever
starts dividing a budget or summing transactions, that is the exact
duplication Phase 1.9 and the Phase 2 Review both fought to remove,
reappearing one layer up.

**Rule 2 — Health is an interpretation, not a recommendation.** Three
distinct layers, never collapsed into each other:

```
Metric        Spending Pace = too_fast
Health        Overall Health = Amber
Recommendation Reduce Food spending   (Phase 4 — not Health's job)
```

Health answers "how healthy is the situation," never "what should the
user do" — that boundary is what keeps Phase 4 (Recommendation Engine)
from being reimplemented inside Phase 3 by accident.

**Rule 3 — Health must always be able to explain itself.** If the app
says Amber, the user can always ask "why?" and get something concrete:

```
• Spending faster than planned
• Food category under high pressure
• Recovery is still possible
```

Never a bare "Health Score = 63" with no path back to what caused it.
This is why the output is reason codes (below), not a sentence and not a
number — the Explainer (Phase 6) turns reason codes into the sentence
above; Health only ever produces the codes.

**Rule 4 — No hidden weights.** Never `budgetScore×0.4 + recoveryScore×0.3
+ pressureScore×0.2 + ...` — a weighted sum is impossible to explain to a
user ("why 63 and not 65?") and impossible to reason about when tuning
it. Health is **rule-based**: a waterfall of `IF condition THEN status`
checks, each condition built directly from a Phase 2 metric's already-
classified output (a status string, a boolean, a severity level) — never
a raw number multiplied by a coefficient.

### Five product questions, answered before any Phase 3.1 design

**Q1 — Can Health ever improve without the user spending less?** For
example, if income increases, should Health improve? In principle,
yes — a healthier financial position shouldn't require belt-tightening
as the only path. But this needs an honest, code-level check, not just a
"yes" in the abstract: **as Phase 2 is actually built today, an income
increase alone (with no change to category budgets) does not move any
metric Health is allowed to read.** `total_budget` is a sum of category
*limits*, never touched by `income`; Spending Pace, Recovery Plan, and
Category Pressure all key off `total_budget`/`categoryRemaining`, not
`income`. Only Projected Savings' raw `value` shifts (via `savingsPool`),
but Health doesn't read continuous values, only classified statuses.
**Decided**: this is a real, current limitation, not silently glossed
over. The actual lever for "Health improves without spending less" is
**raising a category's budget limit** (which lowers that category's
Budget Utilization and Pressure, which Health does read) — not income by
itself. If "income alone should improve Health" becomes a real product
requirement later, that's a Phase 2 change (a metric that reads income
directly), not something Health should route around by reaching past
Phase 2 into raw data itself.

**Q2 — Can one category make everything Red?** **Decided: no, not by
itself.** One category at `high` pressure is Amber, not Red — Recovery
Plan's own `recoveryPossible` flag already exists specifically to
distinguish "this is bad but fixable" from "this can no longer be fully
recovered." Red is reserved for the cases where recovery is no longer
mathematically possible or a deficit is already projected (see 3.1's
condition table) — not for a single category being under pressure while
the rest of the budget still has room to absorb it.

**Q3 — If Recovery's `dailyTarget == 0`, is Health automatically Red?**
Checked against the actual Phase 2.5 implementation: `dailyTarget <= 0`
and `recoveryPossible == False` are **the same underlying condition** in
`compute_recovery_plan` — `dailyTarget` only reaches 0 when
`total_remaining <= 0`, which is exactly `recoveryPossible`'s own
definition. They were never two independent signals to reconcile.
**Decided**: yes, `dailyTarget == 0` (equivalently, `recoveryPossible ==
False`) maps directly to Red — it's the concrete, already-computed
meaning of "recovery is no longer possible," not a separate judgment
Health has to invent. A `high`-severity plan that's still
`recoveryPossible: true` (e.g. two exhausted categories but real buffer
remains elsewhere) stays Amber, not Red — severity alone doesn't
escalate to Red, only impossibility does.

**Q4 — Should Health ignore tiny budgets?** For example, a Rs 100
Entertainment budget overspent by Rs 5 shouldn't necessarily move
overall Health. **Decided: yes** — but the *mechanism* matters, because
Rule 4 forbids a hidden numeric weight, and "multiply pressure by budget
size" would be exactly that. Instead: **materiality is a rule, not a
weight** — a category only counts toward Overall Health's "one category
under high pressure" condition if it clears a minimum share of the
user's total budgeted amount (a proposed starting rule: at least 5% of
`totalBudget`, tunable like every other Phase 2 threshold). A category
below that line can still show its own honest status in **Category
Health** (Phase 3.2 — nothing is hidden from the user drilling into that
one category), it just can't single-handedly drag the *overall* verdict
down. **Implementation note for whenever 3.1 is actually coded**: to
keep Rule 1 completely literal (Health computes nothing, not even a
ratio), this threshold check should be computed inside **Category
Pressure** (Phase 2.6) as an additive `"material": true/false` field per
category, the same way Spending Pace grew `budgetProgress`/
`timeProgress` for Projected Savings — Health then only ever reads a
boolean, never divides anything itself.

**Q5 — If every category is Amber (or under some pressure), does that
become Red?** **Decided: no, it stays Amber** — but it gets its own
named reason (`MULTIPLE_CATEGORIES_PRESSURED`, see 3.1), distinguishing
"the whole budget is tight everywhere" from "one category is a problem."
Red stays reserved strictly for the two conditions in Q2/Q3 (recovery
impossible, or a projected deficit) — widespread-but-not-impossible
pressure is a materially different, less severe situation and Health's
output should say so explicitly, not conflate the two by both landing on
Red.

## Phase 3.1 — Overall Health (Design Only)

### Design

**The one question this answers**: "How healthy is the user's overall
financial situation today?" Not how much they spent, not what's left,
not what to do — those are already answered by Phase 1/Phase 2 and
Phase 4, respectively.

**Inputs — Metrics Engine only, per Rule 1:**

```
Spending Pace           .status
Recovery Plan           .severity, .recoveryPossible (null = not needed)
Category Pressure       .byCategory[cat].status, .material (see Q4), .priorityOrder
Projected Savings       .value (only the sign — value < 0 — is read, never the number itself), .confidence
```

`Budget Utilization` is read only transitively — Category Pressure
already incorporates it (Phase 2.6 reads `categoryRemaining` to build
`byCategory`), so Health doesn't need to separately consult it.

**Materiality is a named constant, not a hardcoded number.** Per the
same discipline as `ENGINE_VERSION`, `METRICS_ENGINE_VERSION`, and
`REBALANCE_PRIORITY` elsewhere in this codebase:

```python
HEALTH_MATERIALITY_THRESHOLD = 0.05  # 5% of totalBudget, tunable later
```

Six months from now, revising this to 3% or 10% is a one-line change in
`health_engine.py`, not a hunt through every place "5%" was typed as a
literal.

**No numeric score. Green / Amber / Red only, decided by a waterfall of
conditions, checked in this order — first match wins for `status`:**

```
RED if:
    Projected Savings exists AND value < 0                    → PROJECTED_DEFICIT
 OR Recovery Plan exists AND recoveryPossible == False        → RECOVERY_IMPOSSIBLE

AMBER if (and not already Red):
    Recovery Plan exists (needed == true)                      → RECOVERY_NEEDED
 OR every material category's pressure status is "medium"+     → MULTIPLE_CATEGORIES_PRESSURED
 OR any material category's pressure status == "high"          → "<CATEGORY>_HIGH_PRESSURE"
 OR Spending Pace status == "too_fast"                         → SPENDING_TOO_FAST

GREEN otherwise:
    No recovery needed, pace not too_fast, no material category
    under high pressure, no widespread pressure.
```

Every condition is a direct read of an already-classified Phase 2
output — no arithmetic, matching Rule 1 and Rule 4 literally.

**Status vs. reasons — first-match-wins decides the color, but every
true condition is reported.** The waterfall above picks `status` by the
highest-severity tier that has *any* true condition — but `reasons`
lists **every condition that's actually true**, not just the one that
happened to decide the color. If a user is Red because of a projected
deficit *and* also spending too fast, both `PROJECTED_DEFICIT` and
`SPENDING_TOO_FAST` appear in `reasons` — hiding the second, true reason
just because the first one already decided the color would violate Rule
3 (Health must always be able to explain itself completely, not just
partially).

**`reasons` is always ordered by one frozen priority — never by
evaluation order, never by dict/set iteration order.** Two different
code paths producing the same underlying facts must always produce the
same `reasons` array, or every downstream consumer (Chat, Notifications,
Reports) risks disagreeing on wording for what is actually the same
situation:

```
1. PROJECTED_DEFICIT
2. RECOVERY_IMPOSSIBLE
3. RECOVERY_NEEDED
4. MULTIPLE_CATEGORIES_PRESSURED
5. "<CATEGORY>_HIGH_PRESSURE"   (multiple categories: ordered by
                                  Category Pressure's own priorityOrder,
                                  never alphabetically)
6. SPENDING_TOO_FAST
```

**`primaryReason` — the single highest-priority true reason, per the
same frozen order above.** Added specifically so a future consumer that
only wants one headline reason (Notifications, for a push message) never
has to re-implement "which of these reasons matters most" — it's already
decided, by construction, as `reasons[0]` after priority-sorting:

```
"overallHealth": {
  "status": "amber",
  "primaryReason": "SPENDING_TOO_FAST",
  "reasons": ["SPENDING_TOO_FAST", "FOOD_HIGH_PRESSURE"],
  "confidence": "high",
  "decisionTrace": [
    "Projected Savings checked — no deficit",
    "Recovery Plan checked — not needed",
    "Category Pressure checked — Food material and high",
    "Spending Pace checked — too_fast"
  ]
}
```

**`decisionTrace` — Phase 1's `decisionLog`, for interpretation instead
of money.** An ordered list of what Health actually checked and what it
found, in the same order as the frozen priority list above (so the
trace and the reasons ordering are never two different sequences to
reconcile). Purely a debugging aid, never shown to the user — exactly
the same treatment `financial_engine.py`'s `decisionLog` already gets.
When someone asks "why is this user Amber," the answer is "read the
trace," not "step through the code."

**Confidence — "weakest link," not a new judgment.** Health's confidence
is the **lowest confidence among the Phase 2 metrics that actually
triggered a reason** — not computed, just selected. If only Spending
Pace (`high` confidence) and Category Pressure (`high` confidence)
contributed reasons, Health's confidence is `high`. If Projected
Savings (`low`/`medium` confidence) contributed `PROJECTED_DEFICIT`,
Health's confidence drops to whatever Projected Savings' own confidence
was for that call. This is itself a rule ("take the minimum"), not a
weight — consistent with Rule 4.

The Explainer (Phase 6) is the only place `SPENDING_TOO_FAST` becomes
"Spending faster than planned" — Health never produces that sentence
itself, per Rule 3.

**Reason code vocabulary (frozen set, extended only alongside a new
condition, never invented ad hoc by a caller):**

```
PROJECTED_DEFICIT             RECOVERY_IMPOSSIBLE
RECOVERY_NEEDED                MULTIPLE_CATEGORIES_PRESSURED
"<CATEGORY>_HIGH_PRESSURE"    SPENDING_TOO_FAST
```

### Who consumes each output (documented now, per the same discipline the Financial Engine and Metrics Engine already got)

| Output | Consumed by |
|---|---|
| `overallHealth.status` | Home UI, Reports, Notification Engine (Phase 5) |
| `overallHealth.primaryReason` | Notification Engine (a single headline reason for a push message), Chatbot |
| `overallHealth.reasons` | Chatbot (full explanation), Reports |
| `overallHealth.confidence` | Reports, internal — not necessarily shown to the user |
| `overallHealth.decisionTrace` | Debug tools only, never a real consumer-facing surface |

These are intended consumers — Phases 4-6 don't exist yet, so this table
is a forward commitment (the same shape those phases must read), not a
description of code that runs today.

### Acceptance criteria (draft — finalized once 3.1 is actually implemented)

- **Correct** — the waterfall matches the frozen condition table exactly,
  first-match-wins for `status`, every true condition present in
  `reasons`, for every real and synthetic scenario tested.
- **Explainable** — every `status` is always accompanied by at least one
  reason code when not `green`; `green` may have zero reasons.
  `primaryReason` always equals `reasons[0]` after priority-ordering.
- **Deterministic ordering** — `reasons` always follows the frozen
  priority list, never evaluation order or iteration order; two calls
  with identical inputs always produce an identical `reasons` array.
- **No hidden weights** — verified by inspection: no coefficient, no
  weighted sum, anywhere in the implementation.
- **Rule 1 compliance** — verified by inspection: the function reads
  only Metrics Engine outputs (plus the one Fact-derived `material` flag
  Category Pressure will expose), never `categoryRemaining.spent`,
  never a transaction, never a division beyond the named
  `HEALTH_MATERIALITY_THRESHOLD` comparison, which itself lives in
  Category Pressure, not Health.
- **Deterministic, tested, real-account verified, API/UI ready** — same
  five criteria every Phase 2 metric was held to.

### Not yet decided (deferred to Phase 3.1's actual implementation, once this design is confirmed)

- The exact value of `HEALTH_MATERIALITY_THRESHOLD` (proposed: `0.05`) —
  a first cut, same caveat every Phase 2 classification threshold
  carried.
- Whether `MULTIPLE_CATEGORIES_PRESSURED` requires *all* material
  categories at `medium`+ or some smaller majority — proposed "all" for
  now, the stricter and more explainable starting rule.

### Revised Phase 3 roadmap

```
Phase 3.0   Health Philosophy                    ✅ Done (design)
Phase 3.1   Overall Health                        (next)
Phase 3.1 Review   Real-account verification pass — check the rules
                    feel right in practice before anything is built on
                    top of them
Phase 3 (interim) Freeze   Overall Health's rules locked
Phase 3.2   Category Health                        (reuses most of 3.1)
Phase 3.3   Risk Flags
Phase 3 Final Freeze
```

The extra review step after 3.1 (before 3.2/3.3) exists because Health
is judgment, not calculation — this is the first point where the rules
themselves, not just their correctness, need to be checked against how
a real account actually feels day to day. Tweaking the waterfall is far
cheaper before Category Health and Risk Flags are built on top of it
than after.

**Not started yet.** Phase 3.0's four rules and five answered questions,
plus Phase 3.1's condition table, status-vs-reasons distinction, frozen
reason-code priority order, `primaryReason`, `decisionTrace`, the named
`HEALTH_MATERIALITY_THRESHOLD` constant, weakest-link confidence rule,
and the consumer table, are the design freeze. Implementation of Phase
3.1 — and Category Pressure's small additive `material` field it depends
on — begins on separate confirmation. Phase 3.2 (Category Health) and
3.3 (Risk Flags) are not designed yet; per the user's own ordering, 3.1
ships, is verified in its own review pass, and only then does 3.2 begin.

### Phase 3.1 — Done (2026-07-18)

Implementation, built as a pipeline exactly like the Financial Engine
and Metrics Engine (per the user's explicit direction — not "implement
Health" but a sequence of private stages):

- `services/metrics_engine.py` — `compute_category_pressure()` gained a
  `total_budget` parameter and now emits `HEALTH_MATERIALITY_THRESHOLD`
  (named constant, `0.05`) plus a per-category `material` boolean.
  The threshold and the arithmetic behind it live here, in Metrics
  Engine, specifically so Health itself never computes even a ratio —
  Rule 1 stays literal.
- `services/health_engine.py` (new) — `compute_overall_health(db, uid,
  month_key)`, the only public function. Pipeline:
  `_load_metrics → _validate_metrics → _evaluate_rules →
  _collect_reasons → _determine_status → _determine_confidence →
  _build_decision_trace → _build_health`. `_evaluate_rules` returns
  every true `(code, source, confidence)` triple, not just the one that
  decides `status` — `_collect_reasons` then sorts all of them by the
  frozen `_REASON_PRIORITY` order, and `_determine_status` separately
  picks the color from the highest-severity tier with any true
  condition. `HEALTH_ENGINE_VERSION = "1.0.0"`.
- `routes/financial_health.py` (new) — `GET /financial-health`, the
  same thin-read shape as `financial_summary.py`/`financial_metrics.py`.
  Registered in `main.py`.
- `frontend/lib/screens/home_screen.dart` — `_fetchOverallHealth()`
  (same pattern as the other Metrics Engine fetches), `_overallHealthStatus`
  getter reads `.status` only. New `_buildHealthBadge()` — one simple
  card: emoji + a short generic label per status (🟢 Looking good / 🟡
  Stable but needs attention / 🔴 Needs attention now). No reasons shown
  yet — that's Phase 6's Explainer's job, once it exists.

**Acceptance criteria — all six checked (per the draft criteria written
during design):**

| Criteria | Result |
|---|---|
| Correct | Yes — waterfall matches the frozen condition table exactly; verified against 11 synthetic scenarios and live data |
| Explainable | Yes — every non-green status carries at least one reason code; `primaryReason` always equals `reasons[0]` |
| Deterministic ordering | Yes — `reasons` always follows the frozen priority list, verified with a 4-simultaneous-reason test |
| No hidden weights | Yes — verified by inspection: `_determine_status`/`_determine_confidence` are pure rule/min selection, no coefficient anywhere |
| Rule 1 compliance | Yes — verified by inspection: `health_engine.py` reads only Metrics Engine outputs; the one ratio check (`material`) lives in `metrics_engine.py`, not here |
| Tested, real-account verified, API/UI ready | Yes — see below |

**Unit tests** (`backend/tests/test_health_engine.py`, all 11 checks
passing, matching the user's requested test matrix exactly): everything
healthy → green; spending too fast only → amber; one pressured material
category → amber; multiple pressured categories → amber with
`MULTIPLE_CATEGORIES_PRESSURED` before the per-category code; recovery
needed (possible) → amber; recovery impossible → red; projected deficit
→ red; four simultaneous reasons → red, exact frozen priority order,
`primaryReason == reasons[0]`; mixed confidence (high, high, medium) →
overall `medium`; a non-material high-pressure category → green (fully
ignored, not just down-weighted). Plus 2 new Category Pressure tests for
the materiality threshold itself (`backend/tests/test_metrics_engine.py`,
55 total now across Phase 2+3.1).

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`) — and this one is a genuinely strong result: the account's
**actual live state** simultaneously satisfied three different trigger
conditions (Spending Pace `too_fast`, Food at `high` material pressure,
Recovery Plan needed-but-possible), with no synthetic setup required.
Result: `status: "amber"`, `confidence: "medium"` (correctly the weakest
of the three contributing confidences — `recoveryPlan`'s `medium` beat
both `high`s), `reasons` in the exact frozen order
(`RECOVERY_NEEDED, FOOD_HIGH_PRESSURE, SPENDING_TOO_FAST`),
`primaryReason` correctly `RECOVERY_NEEDED`. Every field cross-checked
against the underlying Metrics Engine call — exact match. Per the "test
logic, not colors" guidance: this verified the *decision logic itself*
(three real signals correctly detected, correctly prioritized, correctly
weakest-link-confidenced) — not merely that some color came out.

**Frontend verification**: `dart analyze` clean on `home_screen.dart`
(zero issues); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification depth
as every prior UI phase.

**Overall Health is Done, per every acceptance criterion.** Per the
revised roadmap, this is where **Phase 3.1 Review** happens next — a
pause to check the rules feel right in practice against real accounts
before Category Health (3.2) or Risk Flags (3.3) are built on top of
them, exactly the discipline Phase 2 followed between metrics.

**One addition made during this review, before the checks below**:
`compute_overall_health()`'s `metadata` gained `metricsEngineVersion`
(imported directly from `metrics_engine.METRICS_ENGINE_VERSION`,
alongside the existing `healthEngineVersion`) — so a report like
"yesterday I was Green, today I'm Amber" can always be traced to exactly
which version of each engine produced each result, the same discipline
`financialSummary` and `financialMetrics` already follow. Named
`metricsEngineVersion` rather than the originally suggested
`metricsVersion`, for naming consistency with the sibling field already
used inside `financialMetrics.metadata` itself.

---

## Phase 3.1 Review (2026-07-18)

The right question for this review, per the user's framing: not "does
the code work" (the 55+11 unit tests already answer that) but **"would
a user agree with this health assessment?"** Six checks, each run
against real evidence — synthetic scenarios where a live account
couldn't exercise the case, real-account transitions where it could.

### 1. Transitions feel logical

Tested live against `botbachat@gmail.com`, a genuine before/after/undo
round trip — not synthetic:

| Action | Health before | Health after | Match expected? |
|---|---|---|---|
| Baseline (already `too_fast` pace, Food exhausted, recovery still possible) | — | 🟡 Amber (`RECOVERY_NEEDED`, `FOOD_HIGH_PRESSURE`, `SPENDING_TOO_FAST`) | — |
| Spend Rs 65 more on Transport (its only remaining buffer) | 🟡 Amber | 🔴 Red (`RECOVERY_IMPOSSIBLE`, `MULTIPLE_CATEGORIES_PRESSURED`, `TRANSPORT_HIGH_PRESSURE`, `FOOD_HIGH_PRESSURE`, `SPENDING_TOO_FAST`) | ✅ Amber → Red exactly when recovery genuinely became impossible |
| Undo that transaction | 🔴 Red | 🟡 Amber — **byte-for-byte identical to the original baseline** | ✅ Fully reversible |

The remaining transitions from the user's table (healthy baseline →
Green, spend a little → stays Green, increase budget/income → recovers)
are covered by the 11-scenario synthetic test matrix rather than live
data, since the real account's actual state doesn't currently pass
through those particular states — synthetic coverage is the honest
substitute there, not a gap silently left untested.

**A genuinely interesting, unplanned finding**: after the Transport
spend, `TRANSPORT_HIGH_PRESSURE` sorted *before* `FOOD_HIGH_PRESSURE` in
`reasons` — because Transport's pressure (`+0.48`) had become higher
than Food's (`+0.42`) at that moment. This is Category Pressure's own
`priorityOrder` correctly driving the per-category tiebreak exactly as
designed (spec: Phase 3.1, the "<CATEGORY>_HIGH_PRESSURE ... ordered by
Category Pressure's own priorityOrder" rule) — not a bug, a confirmation
that the ordering rule responds correctly to which category is *actually*
more urgent right now, not a fixed category order.

### 2. "Why?" test

Baseline Amber, asked cold: "why is this Amber?" → the three reasons
(`RECOVERY_NEEDED`, `FOOD_HIGH_PRESSURE`, `SPENDING_TOO_FAST`) each
independently make sense without opening any code — recovery is needed
but not yet impossible, Food is genuinely the tightest category, and
spending is genuinely ahead of the month's pace. **Passed.**

### 3. Contradiction scan

Verified two ways: by construction (status is derived from the same
`triggered` list `reasons` is built from — there is no code path where
they could diverge) and empirically, with 5 new invariant checks run
against all 10 test-matrix scenarios (50 checks total, all passing):
`green` never carries reasons, non-`green` always carries at least one,
`PROJECTED_DEFICIT`/`RECOVERY_IMPOSSIBLE` always implies `red`, `red`
always has one of those two codes present, and `primaryReason` always
equals `reasons[0]`. None of the three specific impossible combinations
named in the review request (`green` + deficit, `red` + no reasons,
`amber` + nothing wrong) can occur. **Passed.**

### 4. Primary reason check

Live evidence from the Transport test above: with `RECOVERY_IMPOSSIBLE`,
`MULTIPLE_CATEGORIES_PRESSURED`, and two category-pressure codes all
simultaneously true, `primaryReason` correctly picked
`RECOVERY_IMPOSSIBLE` — "recovery is no longer possible" is what a
person would mention first, and it's what the frozen priority order
produces. **Passed.**

### 5. Confidence sanity check

Both live and synthetic evidence agree: the baseline Amber's confidence
was `medium`, correctly pulled down by Recovery Plan's own `medium`
confidence even though Spending Pace and Category Pressure were both
`high` — matches "one Low/Medium-confidence input should pull the whole
verdict down." The synthetic "Spending too fast only" scenario (only
`high`-confidence inputs contribute) correctly produced overall `high`.
**Passed.**

### 6. Trace readability

The live trace for the baseline Amber case:

```
Projected Savings checked — no deficit
Recovery Plan checked — recovery needed but possible
Category Pressure checked — FOOD_HIGH_PRESSURE
Spending Pace checked — too fast
```

Readable without opening any code, in the same order as `reasons` —
a developer six months from now debugging "why did this change" reads
the trace, not the source. **Passed.**

### Review verdict

All six checks passed, using a mix of live-account transitions (the
Amber → Red → Amber round trip, a real, unplanned demonstration of
correct dynamic reordering) and the synthetic test matrix for states the
real account doesn't currently occupy. No redesign needed.

## Phase 3.1 — Frozen (2026-07-18)

**Overall Health's rules are frozen**, the same declaration Phase 2's
metrics each received individually and Phase 2 as a whole received at
its own completion. Phase 3.2 (Category Health) is built to reuse this
pipeline's shape and rule style, not reinvent it — per the user's own
prediction, most of 3.1 is expected to carry over directly. Phase 3.3
(Risk Flags) and the eventual Phase 3 Final Freeze remain undesigned
until 3.2 ships and is verified, following the exact same one-piece-at-
a-time discipline that has held since Phase 2.1.

---

## Phase 3.2 — Category Health (Design Only)

### Design

**The one question this answers**: "What is the health of THIS
category?" — never "how is the user overall" (Overall Health, 3.1) and
never "what should they do" (Phase 4).

**Scope**: Per Category. **Never**: computes money, recommends actions,
predicts the future, or decides notifications — the same four
exclusions Overall Health already committed to, applied per category.

**Inputs — reused, not recomputed:**

```
Category Pressure    .byCategory[cat].status/.material/.confidence, .priorityOrder
Recovery Plan        .affectedCategories (which categories are exhausted)
```

Budget Utilization is **not** read directly — Category Pressure already
incorporates it (same reasoning Overall Health's design already gave).
Recommended Daily Spend and Spending Pace are **not** read — neither
carries category-specific information Category Pressure doesn't already
have. This confirms the user's own suspicion: **Category Pressure
already contains almost everything Category Health needs.**

**Waterfall — materiality gates first, then a direct mapping from
Category Pressure's own four statuses, with one override:**

```
FOR EACH category in categoryPressure.byCategory:

  IF NOT material:
      GREEN  — LOW_MATERIALITY

  ELSE IF category in recoveryPlan.affectedCategories (exhausted):
      RED    — CATEGORY_EXHAUSTED

  ELSE IF categoryPressure status == "high":
      AMBER  — CATEGORY_HIGH_PRESSURE

  ELSE IF categoryPressure status == "medium":
      AMBER  — CATEGORY_RECOVERABLE

  ELSE IF categoryPressure status == "low":
      GREEN  — LOW_ACTIVITY

  ELSE ("normal"):
      GREEN  — CATEGORY_NORMAL
```

**Decision, frozen: exactly one reason per category, always present
(including Green) — a deliberate divergence from Overall Health.**
Overall Health collects *every* true condition because it aggregates
genuinely independent dimensions (pace, projected savings, recovery,
pressure) that don't imply each other. Within a single category,
exhaustion and high pressure are almost always the same underlying
fact wearing two names — collecting both would be near-redundant, not
informative. And unlike Overall Health's "Green means nothing to
explain, zero reasons," Category Health's Green still names *why*
(`CATEGORY_NORMAL` vs. `LOW_ACTIVITY` vs. `LOW_MATERIALITY`) because a
user scanning every category on the Categories screen benefits from a
complete, non-silent picture — not just the problem ones.

**Confidence — the same "weakest link" rule, reused unchanged, `
_determine_confidence()` from Overall Health.** Because the waterfall
is mutually exclusive (exactly one branch fires), there is exactly one
contributing source per category — so "weakest link" trivially reduces
to "that source's own confidence": `categoryPressure`'s branches are
always `high` confidence (Phase 2.6 never produces anything else);
`CATEGORY_EXHAUSTED` (sourced from Recovery Plan) carries whatever
confidence that Recovery Plan call had (`medium`, per Phase 2.5).

**Reason code vocabulary (frozen, extends but does not modify Overall
Health's):**

```
CATEGORY_EXHAUSTED       CATEGORY_HIGH_PRESSURE
CATEGORY_RECOVERABLE     CATEGORY_NORMAL
LOW_ACTIVITY             LOW_MATERIALITY
```

**Output shape — reuses Overall Health's exact `{status, confidence,
primaryReason, reasons}` object shape and `{code, source}` reason
objects**, keyed by category, plus its own `decisionTrace` per category
(mirroring Overall Health's, not merged into one trace):

```
"categoryHealth": {
  "Food": {
    "status": "amber",
    "confidence": "high",
    "primaryReason": {"code": "CATEGORY_HIGH_PRESSURE", "source": "categoryPressure"},
    "reasons": [{"code": "CATEGORY_HIGH_PRESSURE", "source": "categoryPressure"}],
    "decisionTrace": ["Materiality checked — material", "Exhaustion checked — not exhausted", "Category Pressure checked — high"]
  },
  "Transport": { "status": "green", "confidence": "high", "primaryReason": {"code": "CATEGORY_NORMAL", "source": "categoryPressure"}, "reasons": [...], "decisionTrace": [...] }
}
```

or `null` if `categoryPressure` itself is `null` (no budgets at all —
nothing to report per category either).

**Decision, note on the user's proposed shape**: the design request
showed a flat `"source"` field alongside `reasons`. Implemented instead
as `reasons: [{code, source}]` — reusing Overall Health's exact reason-
object shape rather than introducing a third, slightly different one.
Since Category Health always produces exactly one reason, `reasons[0]`
and a hypothetical flat `source` field would carry identical
information; the reused shape avoids a second reason format existing in
the codebase for no added expressiveness.

**No separate `priorityOrder`.** Category Pressure's own `priorityOrder`
is already the canonical per-category ranking (Phase 2.6) — Category
Health doesn't duplicate it, callers needing an ordering read it from
`categoryPressure.priorityOrder` directly.

**Implementation plan — reuse Overall Health's pipeline pieces, not a
second engine from scratch**, directly answering the user's question
before coding:

- `_determine_confidence()` — reused **unchanged** (already generic:
  takes a list of `(code, source, confidence)` triples).
- `_build_health()` — reused **unchanged** (already generic: takes
  `status, confidence, reasons` and returns the shared shape).
- New, category-specific: `_evaluate_category_rules()` (the waterfall
  above, one category at a time), `_build_category_decision_trace()`,
  and the new public `compute_category_health()` that loops
  `categoryPressure.byCategory` and calls the shared pieces per category.
- **Not duplicated**: no second confidence-ranking table, no second
  response-shape builder — exactly the reuse the user predicted.

### Consumers (frozen before coding)

| Consumer | Uses Category Health? |
|---|---|
| Categories Screen | ✅ |
| Reports | ✅ |
| Notification Engine (Phase 5) | Later |
| Chatbot (Phase 6) | Later |
| Home | Probably not — Home already shows Overall Health |
| Recommendation Engine (Phase 4) | ✅ |

### Acceptance criteria

- **Design** — one question only; never computes money; never predicts;
  never recommends; never decides notifications.
- **Implementation** — reads only Category Pressure + Recovery Plan
  (previous engines' outputs); no duplicated calculation; reuses
  `_determine_confidence`/`_build_health` rather than reimplementing them.
- **Testing** — normal category → Green; high pressure → Amber;
  exhausted category → Red; non-material tiny category → never
  escalates; multiple categories → independent results; confidence
  propagation (weakest-link) verified; decision trace matches the
  triggered rule.
- **Real account** — verify a real account's actual categories against
  manual reasoning, the same "test logic, not colors" standard the 3.1
  Review used.
- **UI** — Categories screen shows a short label per category ("Needs
  Attention" / "Critical"), no calculation inside Flutter.

**Not started yet.** This design — the waterfall, the single-reason
divergence from Overall Health (and why), the reused-pipeline
implementation plan, the frozen reason vocabulary, the consumer table,
and acceptance criteria — is the freeze before any Phase 3.2 code.
Implementation follows on the user's go-ahead.

### Phase 3.2 — Done (2026-07-18)

Implementation, built exactly as designed — reusing Overall Health's
pipeline pieces, not a second engine:

- `services/health_engine.py` — added `_evaluate_category_rules()` (the
  per-category waterfall: materiality gate → exhaustion override → a
  direct mapping from Category Pressure's four statuses),
  `_determine_category_status()`, `_build_category_decision_trace()`,
  and the public `compute_category_health(db, uid, month_key)`.
  **Genuinely reused, not reimplemented**: `_determine_confidence()` and
  `_build_health()` are called unchanged, verbatim, from the exact same
  functions `compute_overall_health()` uses — no second confidence-rank
  table, no second response-shape builder exists anywhere in the file.
- `routes/financial_health.py` — `GET /financial-health` now returns
  both engines' output in one response: `{ overallHealth, decisionTrace,
  categoryHealth, metadata }`.
- `frontend/lib/screens/categories_screen.dart` — `_fetchFinancialSummary()`
  now also fetches `/financial-health` (three parallel calls),
  attaches `healthStatus` per category. The Phase 2.6 pressure chip
  (`_pressureChipLabel`/`_buildPressureChip`) was **replaced**, not
  supplemented, by `_healthChipLabel`/`_buildHealthChip` — "Needs
  Attention" (amber) / "Critical" (red), no chip for green — since
  Category Health is the more authoritative judgment layer built
  directly on top of Category Pressure + Recovery Plan; showing both
  chips side by side would have been redundant, not more informative.

**Acceptance criteria — all checked:**

| Criteria | Result |
|---|---|
| One question only | Yes — "what is the health of THIS category," never the user's overall situation or a recommendation |
| Never computes money / predicts / recommends / decides notifications | Yes — verified by inspection: the module reads only `categoryPressure`/`recoveryPlan`, no arithmetic beyond the reused confidence-selection |
| Reads previous engines only, no duplicated calculation | Yes — `_determine_confidence`/`_build_health` are literally the same functions, not reimplementations |
| Tested | Yes — `backend/tests/test_health_engine.py`, 10 new scenarios (all passing) |
| Real account verified | Yes — see below |
| UI | Yes — Categories screen shows a short label, no calculation in Flutter |

**Unit tests** (all passing): normal category → green/`CATEGORY_NORMAL`;
high pressure → amber/`CATEGORY_HIGH_PRESSURE`; medium pressure →
amber/`CATEGORY_RECOVERABLE`; low pressure → green/`LOW_ACTIVITY`;
exhausted category → red/`CATEGORY_EXHAUSTED` with confidence correctly
propagated from Recovery Plan (`medium`), not Category Pressure's own
`high`; a non-material category never escalates, **even when also
exhausted** (materiality gates before the exhaustion check, verified
explicitly); two categories evaluated independently; decision trace
verified to stop at exactly the check that terminated each waterfall
(1 line for non-material, 2 for exhausted, 3 for a fully-evaluated
normal category).

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`) — matched manual reasoning exactly: **Food → Red**
(`CATEGORY_EXHAUSTED`, confidence `medium`) — correctly overriding what
would otherwise have been `CATEGORY_HIGH_PRESSURE`/amber from Category
Pressure's own `high` status, because exhaustion (from Recovery Plan)
takes priority. **Transport → Green** (`LOW_ACTIVITY`, confidence
`high`). This is exactly the check the design asked for — "Food →
Red/Amber, Transport → Green, compare with manual reasoning" — and it
passed without any adjustment.

**Frontend verification**: `dart analyze` clean on `categories_screen.dart`
(only the same pre-existing `const`-constructor info hints noted since
Phase 1.9); app rebuilt and booted successfully in Chrome (Dart VM
Service came up, no compile or runtime errors) — same verification depth
as every prior UI phase.

**Category Health is Done, per every acceptance criterion**, and the
user's own prediction was correct: it was built almost entirely by
reusing Overall Health's pipeline, with only the per-category waterfall
and trace as new code.

## Phase 3.2 — Frozen (2026-07-18)

**Category Health's rules are frozen.** Phase 3.3 (Risk Flags) is next,
followed by the Phase 3 Final Freeze — both remain undesigned until 3.3
is explicitly taken up, following the same one-piece-at-a-time
discipline held since Phase 2.1.

### Documentation note

Per the request to keep other markdown files current: `backend/endpoints.md`
(the pre-Financial-Engine MVP endpoint reference) gained a new "Endpoints
20-22" entry for `/financial-summary`, `/financial-metrics`, and
`/financial-health`, explicitly pointing back to this spec as the
authoritative source for their formulas/invariants — `endpoints.md` lists
them for discoverability only, it does not duplicate their detailed
behavior. The rest of `endpoints.md` (and the other project markdown
files — `schema.md`, `system_architecture.md`, `CHANGES.md`, the
`README.md`s) predate this spec and describe the pre-Engine MVP design;
updating those historical documents in full is a separate, larger task
outside this phase's scope, not attempted here.

---

## Phase 3.3 — Risk Flags (Design Only)

The last piece of the Health Engine. Everything before this asked "what
is happening" or "is it healthy" — Risk Flags is the first phase that
asks **"is there something important enough that the user should
know?"** Deliberately not "should we notify them" (Phase 5) — Risk Flags
only identifies risks; deciding whether, when, and how often to
interrupt the user is a separate responsibility down the pipeline:

```
Health Engine       "I'm Amber."
Risk Flags          "You're at risk of running out of Food budget."
Notification Engine "Should I interrupt the user?"
Explainer           "Here's how to say it."
Chat                "Let me explain why."
```

### Design

**The one question this answers**: "Is there something worth noticing?"
Never "is it healthy" (already Overall/Category Health), never "what
should I do" (Recovery Plan/Phase 4), never "should this interrupt the
user" (Phase 5).

**Risk ≠ Health — these are genuinely different questions, not the same
question asked twice:**

- Overall Health `amber` + zero risk flags is possible — the user is
  slightly behind pace but nothing has crossed a threshold worth
  surfacing on its own.
- Overall Health `green` + a risk flag is possible in principle (e.g. "a
  specific goal is falling behind" while the month overall looks fine) —
  though see the Goal Risk note below: this specific example isn't
  buildable yet with today's signals.

**Inputs — previous engines only, zero new arithmetic:**

```
Overall Health's already-evaluated conditions   (_evaluate_rules — reused, not re-derived)
Category Health's already-evaluated conditions  (_evaluate_category_rules — reused, per category)
```

**Decision, frozen: Risk Flags reuses the exact same rule-evaluation
functions Overall Health and Category Health already call — not the
public `reasons` arrays, the underlying `(code, source, confidence)`
triples.** The public `overallHealth.reasons` array intentionally
compresses confidence down to one aggregate `overallHealth.confidence`
(the weakest link across everything that fired); Risk Flags needs
**per-flag** confidence (`PROJECTED_DEFICIT` might be `medium` while
`SPENDING_TOO_FAST` is `high`, in the same response), so it calls
`_evaluate_rules()`/`_evaluate_category_rules()` directly — the same
functions, not reimplemented, just consumed at an earlier, more granular
point in the pipeline than the public Health objects expose.

**Decision, frozen: per-category risks come from Category Health only,
never duplicated from Overall Health's own per-category codes.** Overall
Health's `_evaluate_rules()` already emits `"<CATEGORY>_HIGH_PRESSURE"`
codes for its own aggregate reasoning — Risk Flags explicitly **excludes**
these (any code ending `_HIGH_PRESSURE` from the overall evaluation) and
sources every per-category risk from `_evaluate_category_rules()`
instead, which already correctly prioritizes exhaustion over pressure
per category (Phase 3.2's waterfall). Without this exclusion, a single
exhausted category would produce two near-duplicate flags from two
different "sources" describing the same fact.

**Risk types and the frozen severity table** — a rule-based lookup,
never a weighted score, mapping an already-computed code straight to a
`(type, severity)` pair:

| Code | Risk Type | Severity |
|---|---|---|
| `PROJECTED_DEFICIT` | Projection Risk | Critical |
| `RECOVERY_IMPOSSIBLE` | Recovery Risk | Critical |
| `CATEGORY_EXHAUSTED` *(per category)* | Budget Risk | High |
| `RECOVERY_NEEDED` | Recovery Risk | Medium |
| `MULTIPLE_CATEGORIES_PRESSURED` | Budget Risk | Medium |
| `CATEGORY_HIGH_PRESSURE` *(per category)* | Budget Risk | Medium |
| `SPENDING_TOO_FAST` | Spending Risk | Low |
| `CATEGORY_RECOVERABLE` *(per category)* | Budget Risk | Info |

Codes that never become risk flags at all: `CATEGORY_NORMAL`,
`LOW_ACTIVITY`, `LOW_MATERIALITY` — these are Category Health's
*reassuring* codes, not risks; a table entry for them would misrepresent
"nothing wrong" as something worth flagging.

**Severity waterfall (frozen, five levels — a genuinely richer scale
than Health's three-color status, because ranking *many risk types
against each other* needs more resolution than red/amber/green does):**

```
Critical > High > Medium > Low > Info
```

**Goal Risk — explicitly deferred, not built.** No engine through
Phase 3.2 currently computes whether a specific savings goal is falling
behind (`financialSummary.goalProgress` has `percentComplete`/
`monthlyTarget`/`status`, but nothing evaluates whether the *current
pace* threatens the *timeframe* — that would be new Goal Metrics logic
that doesn't exist yet in Phase 2). Naming a `GOAL_AT_RISK` code without
a real signal behind it would be exactly the kind of fabricated risk
Phase 2.0's "can this metric ever lie" test exists to catch. Documented
here as a real, named gap — not silently dropped, and the reason the
"Health green + one risk" example above is described as "possible in
principle" rather than demonstrated.

**Output shape — an array already in priority order, deliberately with
no separate `priorityOrder` field:**

```
"riskFlags": [
  {"code": "PROJECTED_DEFICIT", "type": "projection_risk", "severity": "critical", "confidence": "medium", "source": "projectedSavings"},
  {"code": "CATEGORY_EXHAUSTED", "type": "budget_risk", "severity": "high", "confidence": "medium", "source": "categoryHealth", "category": "Food"},
  {"code": "SPENDING_TOO_FAST", "type": "spending_risk", "severity": "low", "confidence": "high", "source": "spendingPace"}
]
```

**Decision, note on the user's proposed shape**: Category Pressure needed
a separate `priorityOrder` because it has two genuinely different
things to expose — a per-category map *and* a ranking over category
*names*. Risk Flags has only one thing: a list of flags, and that list
*is* the ranking (sorted by severity, ties broken by evaluation order —
global risks first, then categories in Category Pressure's own
`priorityOrder`). A parallel `priorityOrder` array here would just
duplicate the list's own index order under a different name — omitted
as redundant rather than mimicked for consistency's own sake. Consumers
needing "just the top N" slice the array directly.

**Decision, frozen: computed on demand, never persisted** — same as
Overall Health and Category Health. Nothing new is stored; every layer
derives from the layer below it on every call, keeping the whole system
deterministic and immune to stale risk data.

### Consumers (frozen before coding)

| Consumer | Uses Risk Flags? |
|---|---|
| Home | Maybe — at most one banner (the single highest-severity flag) |
| Reports | Yes |
| Notification Engine (Phase 5) | Primary consumer — decides whether/when to interrupt, never computes a risk itself |
| Chatbot (Phase 6) | Yes |
| Recommendation Engine (Phase 4) | Yes |

### Acceptance criteria

- **Design** — one question only; never computes money; never decides
  notifications (that's explicitly Phase 5's job, not this phase's).
- **Implementation** — reads only Overall Health's and Category Health's
  already-evaluated conditions; zero duplicated calculation; reuses
  `_evaluate_rules`/`_evaluate_category_rules` verbatim, and the existing
  reason-code vocabulary, rather than inventing new codes where one
  already exists.
- **Testing** — healthy account → no risk flags; one exhausted category
  → one Budget Risk; projected deficit → Projection Risk; multiple risks
  → correct severity ordering; confidence propagation per flag; no
  duplicate per-category flags between Overall Health's and Category
  Health's evaluations.
- **UI** — expose only; no redesign; Phase 5 decides display timing and
  frequency, not this phase.

**Not started yet.** This design — the risk-vs-health distinction, the
reuse of the underlying rule-evaluation functions (not just the public
reason arrays), the exclusion of duplicate per-category signals, the
frozen severity table and five-level waterfall, the deferred (not
fabricated) Goal Risk, the no-separate-priorityOrder decision and its
reasoning, the on-demand computation decision, the consumer table, and
acceptance criteria — is the freeze before any Phase 3.3 code.
Implementation follows on the user's go-ahead.

### Phase 3.3 — Done (2026-07-18)

Implementation, reusing Overall Health's and Category Health's rule
functions directly rather than a third recompute:

- `services/health_engine.py` — added the frozen `_RISK_SEVERITY` lookup
  table and `_SEVERITY_RANK` ordering, plus `_build_risk_flags(metrics)`
  (pure — separated from the public function specifically so it could
  be unit-tested against synthetic metrics without Firestore, the same
  treatment `_evaluate_rules` already got) and the public
  `compute_risk_flags(db, uid, month_key)`. Global risks come from
  `_evaluate_rules()`, with any `_HIGH_PRESSURE`-suffixed code explicitly
  excluded; per-category risks come from `_evaluate_category_rules()`,
  iterated in Category Pressure's own `priorityOrder`. The result list
  is stably sorted by severity only — ties keep the order they were
  built in (global risks first, then categories in priority order).
- `routes/financial_health.py` — `GET /financial-health` now returns all
  three: `{ overallHealth, decisionTrace, categoryHealth, riskFlags,
  metadata }`.
- `frontend/lib/screens/reports_screen.dart` — fetches `/financial-health`
  (fourth parallel call), stores `_riskFlags` (already in priority
  order, never re-sorted in Flutter). New `_buildRiskFlagsCard()` — a
  plain "Risks to Watch" list, one line per flag (category + code, or
  just the code for global risks), a severity-colored dot, nothing
  invented beyond that (per the design: expose only, Phase 6's Explainer
  owns wording, Phase 5 owns whether/when to interrupt). **Home was
  deliberately left untouched** — the consumer table marked Home as
  "maybe one banner," not a requirement, and Home already shows Overall
  Health's status; adding a second, overlapping risk surface there
  wasn't judged to add enough value to justify the touch this phase.

**Acceptance criteria — all checked:**

| Criteria | Result |
|---|---|
| One question only | Yes — "is there something worth noticing," never health status or a recommendation |
| Never computes money | Yes — verified by inspection: only lookups and a stable sort, no arithmetic |
| Never decides notifications | Yes — the module has no concept of "should this interrupt," that's explicitly left to Phase 5 |
| Reads previous engines only, no duplicated calculation | Yes — `_evaluate_rules`/`_evaluate_category_rules` are literally the same functions Overall/Category Health use |
| Uses existing reason codes | Yes — every code in `_RISK_SEVERITY` already existed from Phase 3.1/3.2; no new code was invented except the deferred, explicitly-not-built `GOAL_AT_RISK` |
| Tested, real-account verified, UI exposed | Yes — see below |

**Unit tests** (`backend/tests/test_health_engine.py`, all new scenarios
passing): healthy account → no flags; an exhausted category → a Budget
Risk for that category exists, **and** no duplicate
`FOOD_HIGH_PRESSURE`; projected deficit → a critical Projection Risk;
multiple simultaneous risks → correct severity ordering
(`critical, medium, medium, low`) with the highest-severity flag first;
per-flag confidence propagation verified independently for two different
flags in the same response (`RECOVERY_NEEDED` → `medium`,
`CATEGORY_HIGH_PRESSURE` → `high`) — proving confidence is genuinely
per-flag, not a single aggregate; the no-duplication invariant verified
explicitly (`FOOD_HIGH_PRESSURE` never appears, exactly one Food-related
flag exists). Goal Risk was **not** tested, because it isn't built —
noted in the test file itself, not silently absent.

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`) — the most revealing check of the whole phase: `riskFlags`
returned `CATEGORY_EXHAUSTED` (Food, high), `RECOVERY_NEEDED` (medium),
`SPENDING_TOO_FAST` (low) — correctly in severity order. Cross-checked
against `overallHealth.reasons` from the same account, which separately
listed `FOOD_HIGH_PRESSURE` (Overall Health's own aggregate framing of
the same category) — confirming, on real data, that Risk Flags
correctly **replaces** Overall Health's coarser per-category signal with
Category Health's more precise one (`CATEGORY_EXHAUSTED` beats
`FOOD_HIGH_PRESSURE` because exhaustion is more specific than "under
pressure"), and that the exclusion filter actually works end-to-end, not
just against synthetic inputs.

**Frontend verification**: `dart analyze` clean on `reports_screen.dart`
(only pre-existing `const`-constructor info hints); app rebuilt and
booted successfully in Chrome (Dart VM Service came up, no compile or
runtime errors) — same verification depth as every prior UI phase.

**Risk Flags is Done, per every acceptance criterion.**

## Phase 3 — Final Freeze (2026-07-18)

The Health Engine is complete: **Overall Health (3.1), Category Health
(3.2), and Risk Flags (3.3)**, all built on the four rules frozen in
Phase 3.0, all computed on demand, all verified against real data at
every stage, all reusing the same handful of pipeline primitives
(`_determine_confidence`, `_build_health`, `_evaluate_rules`,
`_evaluate_category_rules`) rather than each phase inventing its own
version.

```
Phase 1     Financial Engine       — a trusted source of financial truth
Phase 2     Metrics Engine         — a trusted source of financial interpretation
Phase 3     Health Engine          — a trusted source of financial judgment
   3.0        Health Philosophy      — four rules, five answered product questions
   3.1        Overall Health         — Green/Amber/Red + reason codes, no score
   3.2        Category Health        — the same judgment, per category
   3.3        Risk Flags             — which of those judgments are worth surfacing
```

**One honestly-named gap carried forward, not fixed silently**: Goal
Risk (`GOAL_AT_RISK`) has no signal to consume yet — Phase 2 never built
a metric for "is this goal's pace threatening its timeframe." Building
that, if it's wanted, is a Phase 2 addition (a new Goal Metric), not
something Phase 3 should reach past its inputs to compute itself. Noted
here so it isn't rediscovered as a surprise later.

**Phase 3 is now frozen**, the same declaration Phase 2 received at its
own completion. Phase 4 (Recommendation Engine) is built to consume
Health + Recovery Plan + Category Pressure's `priorityOrder` completely
— it does not recompute judgment, only decides what advice to offer on
top of it, per the same layered discipline that has now held across
three complete phases.

---

## Phase 4.0 — Recommendation Philosophy (Design Only)

The shift starts here. Phases 1-3 are all descriptive — "what is true,"
"what does it mean," "is it healthy." Phase 4 is the first **prescriptive**
layer — "what should the user do." That makes it a product-design phase
first, an engineering phase second, the same weight Phase 3.0 gave
Health's philosophy before any code existed.

### The one question this engine answers

> "What is the single best action the user could take next?"

Not five actions. Not financial education. Not motivation for its own
sake. **One** actionable recommendation, plus optional alternatives —
never a list presented as equally important choices.

### Five philosophy rules, frozen before implementation

**Rule 1 — Never change money.** Recommendations only suggest; the same
principle Metrics and Health already committed to. The flow is always
`Recommendation → user chooses → Financial Engine updates money` — the
Recommendation Engine itself never writes to `financialSummary`, never
calls `recompute()`, never touches a transaction or budget document.

**Rule 2 — Recommend actions, not observations.** "Food budget is
exhausted" is Health's sentence, not this engine's. This engine's
sentence is "reduce Food spending for the rest of the month" — a verb,
not a status. If a recommendation could be satisfied by restating a
Health/Risk Flag reason instead of proposing a next step, it isn't a
recommendation yet.

**Rule 3 — One recommendation per problem.** Never a checklist ("spend
less, cook more, reduce transport, cancel subscriptions, delay
shopping") — exactly one `primaryRecommendation`, with any others
demoted to `alternatives`, never presented as equally weighted options.

**Rule 4 — Recommendations must be achievable, grounded in existing
metrics, never invented numbers.** Never "save Rs 1000/day" when
Recommended Daily Spend is Rs 120/day. Concretely: any recommendation
that names a number (a daily limit, a category to avoid) must carry that
number as a **value sourced directly from an existing metric** (e.g.
`recoveryPlan.dailyTarget`), never a number composed independently by
this engine. This is the direct, one-layer-up continuation of Phase
2.0's "can this metric ever lie" test — a recommendation that suggests
an impossible target is a lie of a different shape.

**Rule 5 — Every recommendation must be explainable via traceability.**
"Why am I seeing this?" must always be answerable by walking back through
already-existing decision trails — `Recommendation → Risk Flag → Health
reason → Metrics Engine value → Financial Summary` — the same shape
Health's own `decisionTrace` already established, extended one layer
further, not reinvented.

### Inputs — previous engines only, zero new computation

```
Financial Summary → Metrics → Health → Risk Flags → Recommendation Engine
```

**Decision, frozen: the Recommendation Engine consumes Risk Flags
directly, not Overall Health or Category Health independently.** Risk
Flags (Phase 3.3) is already exactly "a priority-ordered list of
problems worth surfacing" — precisely the input a one-best-action engine
needs. Reaching past Risk Flags into Overall Health's `reasons` or
Category Health's per-category objects directly would re-derive
prioritization and deduplication Risk Flags already solved (the same
"<CATEGORY>_HIGH_PRESSURE" vs. `CATEGORY_EXHAUSTED` collision Phase 3.3
already resolved once). One list in, one recommendation out — no new
judgment, no new deduplication logic.

### Recommendation types (categories frozen now, not all implementable yet)

| Type | Example |
|---|---|
| Recovery | "Spend no more than Rs 150/day for the rest of the month." |
| Budget Adjustment | "Reduce Food spending this week." |
| Goal Protection | *(deferred — see below)* "Delay discretionary spending to protect your Earphones goal." |
| Spending Behaviour | "You're spending faster than planned — slow down this week." |
| Positive Reinforcement | "You're on track. Keep your current spending pace." |

**Goal Protection is explicitly deferred, not built — the same honest
gap as Risk Flags' `GOAL_AT_RISK`.** Phase 3.3 already named that no
engine computes whether a goal's pace threatens its timeframe; without
that signal, a "protect your goal" recommendation would have nothing
real to trigger on. Building Goal Protection recommendations depends on
building Goal Risk first (a Phase 2 addition), not something this engine
can shortcut around.

**Positive Reinforcement matters as a category, not an afterthought.** A
system that only ever speaks when something is wrong trains users to
dread it. `HEALTHY` (Risk Flags empty) is a real, first-class waterfall
outcome, not a fallback message bolted on afterward.

### Output shape

```
{
  "primaryRecommendation": {
    "code": "LIMIT_DAILY_SPENDING",
    "type": "recover",
    "priority": 1,
    "confidence": "medium",
    "actionValue": 150,
    "actionUnit": "per_day",
    "category": null,
    "source": "recoveryPlan",
    "generatedFrom": "RECOVERY_NEEDED",
    "expiresWhen": "Recovery Plan is no longer needed"
  },
  "alternatives": [
    {
      "code": "STOP_CATEGORY_SPENDING",
      "type": "stop",
      "priority": 2,
      "confidence": "medium",
      "actionValue": 0,
      "actionUnit": "per_day",
      "category": "Food",
      "source": "categoryHealth",
      "generatedFrom": "CATEGORY_EXHAUSTED",
      "expiresWhen": "Food is no longer exhausted"
    }
  ]
}
```

Field-by-field, and why each exists:

- **`actionValue`** (renamed from an earlier draft's `value`) — Rule 4
  enforced structurally: whenever a recommendation names a number, it
  travels with the object sourced directly from the triggering metric
  (e.g. `recoveryPlan.dailyTarget`), never re-derived, never composed
  independently.
- **`actionUnit`** — added alongside `actionValue` specifically so
  consumers never have to guess what an `actionValue` number means.
  `80` alone is ambiguous — `80` + `"per_day"` isn't. Frozen starting
  vocabulary: `"per_day"` (a daily rate, Rs), `"currency"` (a flat Rs
  amount, not a rate), `"percentage"`, `"days"`, `"count"` — extended
  only alongside a new recommendation code that actually needs a new
  unit, never invented ad hoc. `null` when `actionValue` is also `null`
  (nothing to unit-ize).
- **`type`** — see "Recommendation Type taxonomy" below; a coarser
  grouping than `code`, specifically for consumers that want to style
  by *kind of action* (styling five colors for five types) rather than
  maintaining a lookup table keyed by every individual code.
- **`category`** — nullable, present so category-specific recommendations
  carry the same per-item shape Risk Flags already established.
- **`priority`** — an explicit rank (1 = primary, 2+ = alternatives, in
  order) so a consumer can sort/display without depending on array
  position implicitly.
- **`generatedFrom`** — the exact Risk Flag / Health reason code that
  triggered this recommendation (Rule 5's traceability chain, one
  explicit link: `Recommendation → generatedFrom → Risk Flag → Health
  reason → Metrics Engine value → Financial Summary`). Distinct from
  `source`, which names the *metric* the underlying value came from —
  `generatedFrom` names the *condition*, `source` names the *data*.
- **`expiresWhen`** — a **human-readable description**, not a stored
  timestamp or scheduled job. See "Automatic expiry" below — this field
  is static text tied to the recommendation code in the Matrix itself,
  describing the condition under which the *next* computation naturally
  stops producing this recommendation. Nothing here is actually
  scheduled to expire anything.

### Recommendation Type taxonomy — a coarser grouping than `code`, for styling

**Decision, frozen: every recommendation code maps to exactly one of five
types**, so Notifications/Chat/Home can style by type (one color per
type) instead of maintaining a per-code lookup table that grows every
time the Matrix does:

| Type | Codes (today) | Typical styling |
|---|---|---|
| Maintain | `KEEP_CURRENT_HABITS` | 🟢 |
| Reduce | `REDUCE_CATEGORY_SPENDING`, `SLOW_SPENDING_PACE` | 🟡 |
| Stop | `STOP_CATEGORY_SPENDING` | 🔴 |
| Recover | `LIMIT_DAILY_SPENDING`, `START_RECOVERY_PLAN`, `ACCEPT_REDUCED_SAVINGS` | 🔴 |
| Monitor | *(none yet — reserved)* | 🟡 |

**Monitor is reserved, not fabricated.** A code like `WATCH_CATEGORY`
would fit this type once a trigger for it exists (e.g. a category
trending toward pressure but not there yet) — no such trigger exists in
the current Risk Flags vocabulary, so no Monitor-type code is added
today. The type exists in the taxonomy now so adding one later is a
one-row Matrix addition, not a taxonomy redesign.

### Automatic expiry — a consequence of "computed on demand," not new machinery

**Decision, frozen: recommendations are never stored, so nothing ever
needs to be manually removed.** This is the same "computed on demand"
principle Overall Health, Category Health, and Risk Flags all already
committed to, one layer further: the Recommendation Engine reads
`riskFlags` fresh on every call, so the moment a Risk Flag stops firing
(the user raises the Food budget, undoes the transaction that made
recovery impossible, etc.), the *next* call to the Recommendation Engine
simply doesn't produce that recommendation anymore. There is no expiry
check, no TTL, no cleanup job — `expiresWhen` only documents, in plain
language, what change in the underlying data would cause that to happen.

### Consistency guarantee — recommendations can never contradict each other

**Decision, frozen: because every recommendation comes from exactly one
row of the frozen Recommendation Matrix below, two contradictory
recommendations (e.g. "reduce Food spending" and "increase Food budget")
can never both appear.** The Matrix is the single source every code
comes from — there is no second code path that could independently
decide to recommend the opposite of what the Matrix already says for the
same trigger. Consistency is a structural property of "one lookup table,
one deterministic answer per trigger," not something checked after the
fact.

### Priority — the same waterfall shape as Health, reusing Risk Flags' own ordering

```
Projected Deficit       → START_RECOVERY_PLAN
Recovery Impossible     → ACCEPT_REDUCED_SAVINGS
Recovery Needed         → LIMIT_DAILY_SPENDING
Category Exhausted      → STOP_CATEGORY_SPENDING     (per category)
Category High Pressure  → REDUCE_CATEGORY_SPENDING   (per category)
Too Fast Spending       → SLOW_SPENDING_PACE
Healthy (no flags)      → KEEP_CURRENT_HABITS
```

(`Category Exhausted` and `Category High Pressure` are two separate
tiers, not one — Risk Flags already keeps them as distinct codes with
distinct severities, `high` vs. `medium`, so their recommendations stay
distinct too, per the Recommendation Matrix below.)

**Decision, frozen: this priority order is not reinvented — it is Risk
Flags' own severity ordering, read directly.** `riskFlags[0]` (already
the highest-severity flag) maps to `primaryRecommendation`;
`riskFlags[1:]` map to `alternatives`, each via the same lookup table.
No second priority list exists anywhere in this engine.

### The Recommendation Matrix (the actual contract — implementation is only ever translating this table into code)

**Revised now that Phase 2.3a closed the gap this table originally
named.** `REDUCE_CATEGORY_SPENDING`'s `actionValue` is no longer `null`
— it reads `categoryDailyTarget[cat].value` directly. This also split
what was one row into two, since Category Health (and therefore Risk
Flags) already distinguishes "under high pressure, still has buffer"
from "already exhausted" as two different codes —
`CATEGORY_HIGH_PRESSURE` and `CATEGORY_EXHAUSTED` — which deserve two
different recommendations, not one recommendation reused for both
severities:

| Trigger (Risk Flag / Health code) | Recommendation Code | Type | `actionValue` | `actionUnit` | Source | `expiresWhen` |
|---|---|---|---|---|---|---|
| `PROJECTED_DEFICIT` | `START_RECOVERY_PLAN` | Recover | `null` | `null` | `projectedSavings` | "Projected Savings is no longer negative" |
| `RECOVERY_IMPOSSIBLE` | `ACCEPT_REDUCED_SAVINGS` | Recover | `null` | `null` | `recoveryPlan` | "Recovery becomes possible again" |
| `RECOVERY_NEEDED` | `LIMIT_DAILY_SPENDING` | Recover | `recoveryPlan.dailyTarget` | `per_day` | `recoveryPlan` | "Recovery Plan is no longer needed" |
| `CATEGORY_EXHAUSTED` | `STOP_CATEGORY_SPENDING` | Stop | `0` (always — Phase 2.3a's own edge case) | `per_day` | `categoryHealth` | "`{category}` is no longer exhausted" |
| `CATEGORY_HIGH_PRESSURE` | `REDUCE_CATEGORY_SPENDING` | Reduce | `categoryDailyTarget[category].value` | `per_day` | `categoryHealth` + `metrics.categoryDailyTarget` | "`{category}` pressure returns to normal/low" |
| `SPENDING_TOO_FAST` | `SLOW_SPENDING_PACE` | Reduce | `null` | `null` | `spendingPace` | "Spending Pace is no longer too_fast" |
| *(no risk flags at all)* | `KEEP_CURRENT_HABITS` | Maintain | `null` | `null` | `overallHealth` | "Overall Health changes from green" |

(`category` is also a parameter on every per-category row —
`CATEGORY_EXHAUSTED`/`CATEGORY_HIGH_PRESSURE` — omitted from this table
only for column width; it's still part of every recommendation object,
per the Output Shape above.)

Renamed `AVOID_CATEGORY_SPENDING` → **`REDUCE_CATEGORY_SPENDING`** in an
earlier revision — a clearer action verb, matching the user's own
repeated naming.

**The gap named in the previous revision of this table is now closed.**
`REDUCE_CATEGORY_SPENDING`'s `actionValue` used to be `null` because no
metric computed a per-category daily figure. Phase 2.3a (Category Daily
Target) exists specifically to close that gap — the Recommendation
Engine still computes nothing itself, it only reads
`categoryDailyTarget[category].value`, exactly the same discipline every
other row already followed. `STOP_CATEGORY_SPENDING`'s `actionValue` of
`0` is not a special case either — it's the same field read from the
same metric, which itself already returns `0` for an exhausted category
by design (Phase 2.3a's own edge case), so no new logic exists anywhere
to produce that zero.

### A gap found while enumerating every Risk Flag code the Matrix must cover

**Before implementing, every code Risk Flags can actually emit was
checked against the Matrix above — and two were missing:
`MULTIPLE_CATEGORIES_PRESSURED` and `CATEGORY_RECOVERABLE`.** Both are
real, already-shipped Risk Flag codes (Phase 3.3's `_RISK_SEVERITY`
table), and silently dropping them from the Recommendation Engine would
have meant: if either were ever the highest-severity flag present, the
engine would either crash (no Matrix row) or — worse — silently skip it
and promote a lower-severity flag to `primaryRecommendation`, quietly
breaking "priority inherited directly from Risk Flags" the moment it
mattered. **Corrected now, before code, not discovered as a bug later:**

| Trigger | Recommendation Code | Type | `actionValue` | `actionUnit` | Source | `expiresWhen` |
|---|---|---|---|---|---|---|
| `MULTIPLE_CATEGORIES_PRESSURED` | `REVIEW_MULTIPLE_CATEGORIES` | Reduce | `null` | `null` | `categoryPressure` | "Fewer than two material categories are pressured" |
| `CATEGORY_RECOVERABLE` | `MONITOR_CATEGORY_SPENDING` | **Monitor** | `categoryDailyTarget[category].value` | `per_day` | `categoryHealth` + `metrics.categoryDailyTarget` | "`{category}` pressure changes from medium" |

**This also corrects something stated one turn too early.** The
Recommendation Type taxonomy previously claimed Monitor was "reserved,
not fabricated — no such trigger exists in the current Risk Flags
vocabulary." That was wrong — `CATEGORY_RECOVERABLE` (Category Health's
`medium`-pressure, `info`-severity code, shipped in Phase 3.2/3.3) is
exactly that trigger; it had simply been overlooked when the taxonomy
was first drafted. `MONITOR_CATEGORY_SPENDING` fills the Monitor type
with a real code today, not a placeholder. The Matrix now has eight
trigger rows plus the no-flags fallback — covering every code Risk Flags
can produce, verified by direct enumeration against
`health_engine.py`'s `_RISK_SEVERITY` table, not by assumption.

### Four behavioral principles — how recommendations behave over time, not what they contain

**1. Recommendation identity.** Every recommendation is a complete,
self-contained object the moment it's created — never a code alone that
some other layer has to enrich later. `{code, type, priority, confidence,
actionValue, actionUnit, category, source, generatedFrom, expiresWhen}`
is produced whole, in one step, from one Matrix lookup. This is what
makes two recommendations comparable (for testing, for "is this the same
recommendation as last time") without reconstructing context from
scattered fields.

**2. Recommendation lifecycle (conceptual only — nothing is stored).**

```
Risk appears → Recommendation exists → user changes spending →
Risk disappears → Recommendation disappears
```

This was already true by construction (the "Automatic expiry" section
above), documented here explicitly as its own named concept because it's
worth stating plainly: there is no recommendation database row to
create, update, or delete anywhere in this system — the lifecycle is
just "Risk Flags changed, so the next call returns something different."

**3. Recommendation priority is inherited, never recomputed.**
`recommendations[i].priority` is *always* `i + 1` in the order Risk
Flags already returned them — there is no second sort, no secondary
comparison, anywhere in the Recommendation Engine. `riskFlags[0]` becomes
`primaryRecommendation`; the rest become `alternatives`, in the same
order. One ordering, established once in Phase 3.3, threaded through
unchanged.

**4. Recommendation traceability — a `recommendationTrace`, the same
philosophy as `decisionLog`/`decisionTrace`.** Every recommendation
object can answer "why do I exist" by construction (`generatedFrom` +
`source` already do this per-object), but the engine's response also
carries a short, ordered trace of the pipeline itself — mechanical, not
narrative:

```
"recommendationTrace": [
  "Risk: CATEGORY_EXHAUSTED",
  "Matrix lookup: STOP_CATEGORY_SPENDING",
  "actionValue: 0 (per_day)"
]
```

Debug-only, never user-facing — the same treatment `decisionTrace`
already gets.

### The implementation pipeline (mechanical, per the four principles above)

```
Load Risk Flags → Validate → Matrix Lookup → Build Recommendation Object
→ Sort (inherited, not recomputed) → Return
```

No calculation, no money, no thresholds, no percentages — every step is
either a read or a lookup.

### Consumers (frozen before coding)

| Consumer | Uses Recommendations? |
|---|---|
| Reports | ✅ |
| Home | Maybe — at most one card |
| Notification Engine (Phase 5) | Yes |
| Chatbot (Phase 6) | Yes |
| Explainer (Phase 6) | Primary consumer — turns `code`/`actionValue`/`category` into a sentence, never receives raw prose from this engine |

### Acceptance criteria

- **Design** — one question only; never computes or changes money;
  every recommendation is achievable (grounded in a real metric value,
  or `null` when no such metric exists yet — never invented); every
  recommendation traceable back through `generatedFrom` → Risk Flags →
  Health → Metrics → Financial Summary.
- **Implementation** — reads Risk Flags only (never re-derives Overall
  Health/Category Health prioritization independently); no duplicated
  calculation; exactly one `primaryRecommendation`, others demoted to
  `alternatives`; every field (`code`, `type`, `priority`, `confidence`,
  `actionValue`, `actionUnit`, `category`, `source`, `generatedFrom`,
  `expiresWhen`) populated from the frozen Matrix, never inline.
- **Testing** (suggested, to run once implementation starts): healthy
  account → `KEEP_CURRENT_HABITS` (type `maintain`); recovery needed →
  `LIMIT_DAILY_SPENDING` (type `recover`) with the correct `actionValue`/
  `actionUnit: per_day`; category exhausted → `STOP_CATEGORY_SPENDING`
  (type `stop`) for the right category with `actionValue: 0`; category
  under high pressure but not exhausted → `REDUCE_CATEGORY_SPENDING`
  (type `reduce`) with `actionValue` matching
  `categoryDailyTarget[category].value`; projected deficit →
  `START_RECOVERY_PLAN` wins over every lower-priority alternative;
  multiple simultaneous issues → correct primary + alternatives split,
  each with the correct `priority`; confidence propagation per
  recommendation; no duplicate recommendation codes competing for
  `primaryRecommendation`; two recommendations for the same category
  never contradict (structural, verified by inspection of the Matrix,
  not a runtime check); every code's `type` matches the frozen taxonomy
  table exactly.

**Not started yet.** This design — the one-question framing, the five
philosophy rules, the Risk-Flags-only input decision, the five
recommendation types (with Goal Protection explicitly deferred pending
Goal Risk), the output shape (`actionValue`/`actionUnit`/`type`/
`priority`/`generatedFrom`/`expiresWhen`), the five-type taxonomy
(Maintain/Reduce/Stop/Recover/Monitor, with Monitor reserved rather than
fabricated), automatic expiry as a consequence of on-demand computation
(not new machinery), the structural consistency guarantee, the
reused-not-reinvented priority ordering, the frozen Recommendation
Matrix (now grounded end-to-end in real metrics — including Phase 2.3a,
added specifically to close the one gap this table originally had to
leave as `null`), the consumer table, and acceptance criteria — is the
freeze before any Phase 4 code. Implementation follows on the user's
go-ahead.

### Phase 4 — Done (2026-07-18)

Implementation, exactly the mechanical pipeline frozen above — a lookup
table, never a calculation:

- `services/recommendation_engine.py` (new) — `_RECOMMENDATION_MATRIX`
  (now nine trigger rows, including the two found missing while
  enumerating `health_engine.py`'s `_RISK_SEVERITY` table before writing
  a single line of pipeline code) and `compute_recommendations(db, uid,
  month_key)`, the only public function. Pipeline:
  `_load_risk_flags → _validate_flags → _build_recommendation` (one call
  per flag, pure Matrix lookup) `→` priority assigned by list position
  (never recomputed) `→ _build_recommendation_trace → return`.
  `_lookup_action_value()` is the only place a number is read, and it
  only ever reads `recoveryPlan.dailyTarget` or
  `categoryDailyTarget[cat].value` — both pre-existing Metrics Engine
  fields, never composed independently.
- `routes/financial_recommendations.py` (new) — `GET
  /financial-recommendations`, the same thin-read shape as every other
  Phase 3/4 route. Registered in `main.py`.
- `frontend/lib/screens/reports_screen.dart` — fetches
  `/financial-recommendations` (fifth parallel call), stores
  `_primaryRecommendation`. New `_buildRecommendationCard()` — "What To
  Do Next," one plain sentence per recommendation code, colored by
  `type` (not by `code` — exactly the coarser-grouping benefit the Type
  taxonomy was designed for). Placed first among the advisory cards,
  since it's the headline guidance Recovery Plan and Risk Flags already
  feed into.

**Acceptance criteria, all checked:**

| Criteria | Result |
|---|---|
| One question only | Yes — "what's the single best next action," never restates a Health/Risk reason |
| Never computes or changes money | Yes — verified by inspection: the entire module is dict lookups, list comprehension, and enumeration; the only arithmetic anywhere is `i + 1` for priority |
| Achievable, grounded in metrics | Yes — every non-null `actionValue` traced to `recoveryPlan.dailyTarget` or `categoryDailyTarget`, both real, already-shipped fields |
| Every code has exactly one Matrix row | Yes — verified by direct enumeration against `_RISK_SEVERITY`, not assumption; this is what caught the two missing rows before they became a bug |
| Reads Risk Flags only | Yes — never re-derives Overall/Category Health prioritization independently |
| One primary + alternatives | Yes — `recommendations[0]`/`recommendations[1:]`, never a checklist |
| Priority inherited, not recomputed | Yes — verified by test: priority always equals list position, list position always matches Risk Flags' own order |
| Tested, real-account verified, API/UI ready | Yes — see below |

**Unit tests** (`backend/tests/test_recommendation_engine.py`, all 13
passing): healthy account → `KEEP_CURRENT_HABITS`; recovery needed →
`LIMIT_DAILY_SPENDING` with the exact expected object (all nine fields);
category exhausted → `STOP_CATEGORY_SPENDING` for the right category,
`actionValue: 0`; category under high pressure (not exhausted) →
`REDUCE_CATEGORY_SPENDING` with `actionValue` matching
`categoryDailyTarget`; projected deficit beats a lower-priority
alternative; three simultaneous issues → exact priority order preserved
end to end (`STOP_CATEGORY_SPENDING` → `LIMIT_DAILY_SPENDING` →
`SLOW_SPENDING_PACE`, priorities `1, 2, 3`); confidence propagation
verified independently for two different recommendations in the same
response; `recommendationTrace` mentions every trigger and its Matrix
lookup; no duplicate recommendation codes in the Matrix; **every Risk
Flag code has a Matrix row** (the specific test that would have caught
the gap, now permanent regression coverage); every code's `type` matches
the frozen taxonomy exactly.

**Real-account verification** against `botbachat@gmail.com` (month
`2026-07`) — the account's actual state (`CATEGORY_EXHAUSTED` for Food,
`RECOVERY_NEEDED`, `SPENDING_TOO_FAST`, in that Risk Flags order)
produced: `primaryRecommendation: STOP_CATEGORY_SPENDING` (Food,
`actionValue: 0`), `alternatives: [LIMIT_DAILY_SPENDING (actionValue: 5,
matching recoveryPlan.dailyTarget exactly), SLOW_SPENDING_PACE]` — a
genuinely more specific, more actionable primary recommendation than a
generic "reduce spending" would have been, and the priority order
matched Risk Flags' own order exactly, field for field.

**Frontend verification**: `dart analyze` clean on `reports_screen.dart`
(only pre-existing `const`-constructor info hints); app rebuilt and
booted successfully in Chrome (Dart VM Service came up, no compile or
runtime errors) — same verification depth as every prior UI phase.

**Phase 4 (Recommendation Engine) is Done, per every acceptance
criterion.**

## Phase 4 — Frozen (2026-07-18)

The prescriptive layer now exists, and it inherited every discipline the
descriptive layers (Phases 1-3) already established: no calculation, one
frozen lookup table as the entire contract, priority inherited rather
than recomputed, and — per this session's own example — a real gap
(the missing per-category daily figure, then the two missing Matrix
rows) found and fixed at the layer where it actually belonged, not
patched downstream. The full pipeline, one question per layer:

```
Phase 1   Financial Engine        — What is true?
Phase 2   Metrics Engine          — What does the data say?
Phase 3   Health Engine           — What does it mean?
Phase 4   Recommendation Engine   — What should the user do?
Phase 5   Notification Engine     — When should we interrupt?
Phase 6   Chatbot / Explainer     — How do we explain it?
```

Phase 5 (Notification Engine) is next, on separate confirmation — it
consumes Recommendations + Overall Health, and per the frozen rule
already stated back in Phase 4.0's design, it decides *whether and when*
to interrupt the user; it does not compute a risk, a health status, or a
recommendation itself.

---

## Phase 4.5 & Phase 5 — Roadmap and Philosophy (Design Only)

Everything through Phase 4 answers "what is the user's financial
situation, and what should they do about it." Phase 5 answers a
completely different question: **"when should we interrupt the user?"**
Not "what notification can I send" — that framing leads to a feature
that notifies because it *can*, not because a specific moment matters.
This section is design only, capturing the full shape before any Phase
4.5 or Phase 5 code — nothing below is implemented yet.

### A new phase inserted first: Phase 4.5 — Behavior Engine

**Decision, frozen: streaks, habits, and milestones get their own
engine, inserted between Recommendation (4) and Notification (5) —
Notification never computes a streak itself.** This is the same
separation every prior phase already enforced (Health never computes
money; Recommendation never computes a metric) applied one layer
further: pattern detection over time (a healthy streak, a logging
streak, a savings streak, a first-time achievement) is its own kind of
fact, distinct from a single-snapshot Financial/Metrics/Health/
Recommendation read, and deserves its own owner rather than being
computed inline wherever Family E ("Behavior Notifications") happens to
need it.

**Behavior Engine owns:**
- Healthy streak, logging streak, saving streak, recovery streak
- Monthly consistency, first-week achievements, milestones
- Habit analytics generally

**Behavior Engine does not own**: whether any of the above becomes a
notification — that's still entirely Phase 5's decision. The relationship
is the same shape as Recommendation → Notification: Behavior Engine
produces facts about patterns; Notification Engine decides whether,
when, and how to surface them.

Not designed in detail yet — this is a placeholder acknowledging the
phase exists and what it owns, so Phase 5's design below can correctly
treat "Family E: Behavior Notifications" as consuming an engine that
will exist, not something Notification computes inline.

### Phase 5 — Notification Engine: the sub-phase breakdown

```
5.0  Philosophy
5.1  Notification Types (families)
5.2  Eligibility Engine
5.3  Priority Engine
5.4  Frequency Engine
5.5  Timing Engine
5.6  Notification Generator
5.7  Notification Lifecycle
5.8  Notification Center
5.9  Review & Freeze
```

Same shape as the Health Engine's own 3.0→3.1→3.2→3.3 breakdown, because
Notification is another decision engine, not a delivery mechanism bolted
onto the side of the app.

### Phase 5.0 — Philosophy

**The one question**: "Should we interrupt the user right now?" Never
"what notification can I send" — the second framing optimizes for having
something to say, not for the moment mattering.

**Five frozen rules:**

1. **Notifications never invent information.** They only surface
   outputs from Financial/Metrics/Health/Risk Flags/Recommendation/
   Behavior — never compute a new fact themselves.
2. **Notifications should change behaviour.** If nothing would change as
   a result of seeing it, don't send it. This is the test that
   distinguishes "technically true" from "worth an interruption."
3. **Respect the user's attention.** One useful notification beats ten
   annoying ones — Frequency (5.4) exists specifically to enforce this
   as a rule, not a hope.
4. **Everything must be explainable.** Tapping "why?" on any notification
   must trace back through the same kind of `generatedFrom`/`source`
   chain every engine since Health has already carried.
5. **Every notification expires.** Nothing lives forever — a stale
   notification about a condition that's no longer true is worse than no
   notification at all.

### Phase 5.0b — Notification Psychology (deepens Rule 2, doesn't replace it)

**First principle, frozen, sharpening Rule 2 rather than adding a new
one: the Notification Engine is not a reminder engine — it is a
behavior-change engine.** Every notification answers exactly one
question: *"can this notification improve the user's financial
behavior?"* If the answer is no, it doesn't get sent, regardless of
whether it's technically true. **Deliberately not copying Duolingo's
notification system** — studying *why* it works and applying the
underlying psychology to a fundamentally different problem (financial
behavior, not a language-learning game) is the frozen approach; the two
apps should not feel the same, because they aren't solving the same
problem.

**Five behavioral-economics principles, frozen, each with the BachatBot
vocabulary they apply to — not abstract theory, concrete phrasing:**

1. **Loss aversion (strongest lever)** — frame the *consequence*, not
   just the state. Not "You have a 12-day streak" but "One missed day
   ends your 12-day healthy streak." Not "Recovery plan active" but
   "Spending ₹400 today could extend your recovery by another week."
2. **Goal gradient effect** — proximity motivates more than distance.
   Not "Keep saving" but "Only Rs. 320 left to complete this month's
   target," or "Two more healthy days and you'll unlock your first
   Healthy Week."
3. **Small wins, explained, not just praised** — not "Good job" but
   "Seven days of consistent logging. Your reports are now far more
   accurate." The *why it matters* is what makes it land.
4. **Identity, not instruction** — invite the user into an identity
   rather than commanding them. Not "Log today's expenses" but
   "Consistent budgeters rarely miss two days in a row." Never "You
   are X" — the invitation, not the label, is what's frozen.
5. **Curiosity gap** — not "View report" but "Something changed in your
   spending today." The user is drawn to find out, never told what to
   feel about it first.

**What NOT to do, frozen as explicit anti-patterns — things Duolingo
itself does that this app must not:**

- **Fake urgency** ("Your owl is sad") — finance must never manipulate;
  every notification's urgency must be real, traceable to an actual
  engine output, never manufactured for engagement.
- **Shame** ("You failed your streak") — reframe instead: "Your healthy
  streak ended today. Tomorrow starts a new opportunity." The fact is
  identical; only the framing changes, never the underlying truth
  (matching the "tone changes, not the facts" principle below).
- **Infinite reminders** — every reminder chain terminates. Example:
  a pending transaction follows up at 30 minutes, 4 hours, then the next
  morning, then **stops** — this extends, not replaces, the frequency
  discipline already frozen in 5.4.
- **Clickbait** — never "Something exciting happened!" Always something
  concrete and true: "A new recommendation is available to reduce this
  week's food spending."

**User state shapes tone, never the underlying facts, frozen:**

| User state | Emotion | Notification style |
|---|---|---|
| New user | Curious | Educational |
| First expense | Encouraging | Positive reinforcement |
| Building habit | Gentle | Small progress |
| Healthy streak | Protective | Preserve momentum |
| Recovery | Supportive | Practical guidance |
| Overspending | Calm | Actionable |
| Goal reached | Celebration | Achievement |
| Long inactivity | Re-engagement | Low pressure |

This table governs *tone only* — the facts a notification reports are
always whatever the source engine (5.1's families) already computed;
nothing here invents a new fact for a given emotional state, per Rule 1.

**Seven psychological purposes, frozen — every notification belongs to
exactly one, and there is deliberately no "spam" category:**

| Purpose | Question it answers | Example |
|---|---|---|
| Awareness | Something happened | Transaction detected |
| Action | Something needs your attention | Confirm transaction |
| Protection | Prevent losing progress | Healthy streak at risk, recovery getting worse |
| Progress | Show improvement | 7 healthy days, logging streak extended |
| Achievement | Celebrate a meaningful milestone | First Healthy Week, 30-Day Logging Streak, Goal Completed |
| Reflection | Help users understand themselves | "You spent 18% less on transport this month" |
| Re-engagement | Bring the user back after absence | "You haven't reviewed this week's spending yet" |

**This is a second, orthogonal dimension to 5.1's seven families below —
not a replacement.** 5.1 answers "which engine produced this fact";
this table answers "why does the user care." A single notification
carries both: e.g. a Family E (Behavior) notification about a healthy
streak at risk is simultaneously a Protection-purpose notification. The
Notification Generator (5.6) records both, since each answers a
genuinely different question about the same notification.

### Phase 5.0c — Attention, Value, and Interruption (frozen before 5.2)

**Principle: respect the user's attention, treated as a spent resource,
not an infinite channel.** Every notification costs something. This
reframes the standing question from "can we notify" to **"is this
interruption worth spending the user's attention?"** — a mindset shift,
not a new rule layered on top of the already-frozen Rule 3, but the
reasoning that makes Rule 3 ("respect the user's attention... one
useful notification beats ten annoying ones") an actual decision
procedure instead of a sentiment.

**Rule: every notification must justify the interruption, frozen.**
One question: *if the user never opened this notification, would
something meaningful be lost?* No → don't notify. Yes → continue
through the eligibility pipeline (5.2). Concrete, using facts this
system already produces:

- ❌ `LOGGING_STREAK_EXTENDED` (a routine day, no threshold crossed) —
  nothing is lost seeing it tomorrow in the Notification Center. No
  interruption.
- ✅ `RECOVERY_BECAME_IMPOSSIBLE` — waiting until tomorrow may let
  spending worsen further. Interrupt now.
- ❌ Primary recommendation reordering alternatives without changing the
  primary (e.g. an alternative moving from 5th to 4th place) — nothing
  the user needs to act on differently. No interruption.
- ✅ `PRIMARY_RECOMMENDATION_CHANGED` from `LIMIT_DAILY_SPENDING` to
  `START_RECOVERY_PLAN` — this changes what the user should actually do.
  Interrupt.

**A second, related but distinct rule: never notify because something
changed — notify because the user should care that it changed.**
These sound similar and are not. `HEALTH_WORSENED`/`HEALTH_IMPROVED`
firing between two amber substates a user was never shown as distinct
in the first place is a real Diff Generator event that nobody should
be notified about; `spending.currentHealthyStreak: 6 → 7` is the same
kind of "a field changed" fact, but here the user genuinely cares. **This
becomes a design filter sitting directly after the Diff Generator**: the
Diff Generator's job ends at "this changed" (Step 10's own frozen
question); the Notification Engine's first real job is asking "should a
human care that it changed" — a separate, later question, never
answered by the Diff Generator itself, which is exactly why Diff Rule 5
(Step 10.0) already forbade it from judging importance.

**A new concept, frozen: Notification Value — distinct from Priority
(5.3), not a replacement for it.** Priority (already frozen) answers
"how important is this event." Value answers a different question:
**"how valuable is it for the user to know this right now"** — timing-
sensitivity combined with importance, not importance alone. (The
"Urgency" label used informally when first describing this is the same
axis as the already-frozen Priority — one concept, not a fourth
dimension; named here explicitly so it isn't mistaken for something
new, the same "one fact, one name" discipline already enforced
elsewhere.)

| Notification | Priority (Urgency) | Value | Outcome |
|---|---|---|---|
| Pending transaction confirmation | High | High | Notify immediately |
| Monthly report available | Low | High | Notify tomorrow morning |
| Healthy streak extended | Low | Medium | Notify at night |
| Minor recommendation reordering | Low | Low | Don't interrupt — Notification Center only |

**A third new concept, frozen: Interruption Levels — a different
decision from Priority, informed by it and by Value, but not a strict
function of either.** Priority answers "how important is this event;"
Interruption Level answers **"how much of the user's attention may I
consume to deliver it."**

| Level | Delivery | Example |
|---|---|---|
| 0 | No notification — visible only inside the app | A minor recommendation reordering |
| 1 | Notification Center only, badge appears, no push | Routine progress facts a user might want later, not now |
| 2 | Standard push notification | Healthy streak, monthly report, pending transaction |
| 3 | High-importance push, very rare | Recovery became impossible, monthly rollover failed, bank sync requires attention |

### The overarching philosophy for Phase 5, frozen

**The Diff Generator detects changes. The Notification Engine protects
the user's attention.** One sentence, and it's the same separation of
responsibility this entire architecture has maintained end to end:

```
Financial Engine       → money truth
Metrics Engine         → measurements
Health Engine          → interpretation
Recommendation Engine  → actions
Behavior Engine        → habits
Snapshot/Diff          → historical change detection
Notification Engine    → decides whether a change deserves attention
```

Notification Engine invents no facts and detects no events of its own —
consistent with everything frozen since Phase 4.5A. It decides how,
when, and whether to communicate what already exists. **5.2's
Eligibility waterfall (already sketched) will need a new first gate**
— "would something meaningful be lost if this were never seen" — sitting
before the existing preference/relevance/already-shown/expired checks;
not designed in detail yet, named here so it isn't missed when 5.2 is
actually built.

### Phase 5.1 — Notification Types (seven families)

| Family | Source | Example |
|---|---|---|
| A — Transaction | Existing pending-transaction flow (formalized, not new) | "Was this your transaction?" |
| B — Health | Health Engine | Overall Health becomes Red |
| C — Risk | Risk Flags | `CATEGORY_EXHAUSTED` |
| D — Recommendation | Recommendation Engine | "Limit spending" |
| E — Behavior | Behavior Engine (Phase 4.5) | Healthy streak, logging streak, milestone |
| F — Goal | Goal data / Financial Engine | Goal completed, goal behind, goal milestone |
| G — System | App/infra, not financial reasoning | Pending confirmations, sync failed, bank disconnected |

Each family has a distinct source engine — Notification never
re-derives what any of them already computed, per Rule 1.

### Phase 5.2 — Eligibility (superseding the earlier six-step sketch above)

**One question, frozen**: *"Should this event become a notification?"*
Not how important it is, not when it should be sent, not how it should
look — those are 5.3 (Priority), 5.5 (Timing), and 5.6 (Generator).
Eligibility decides yes/no and nothing else.

**One input, frozen**: an Event — the object Step 10's Diff Generator
already produces. Not a snapshot, not Health, not Recommendation, not a
transaction. This is what keeps ownership intact: Notification Engine
starts exactly where the pipeline already ends
(`Snapshot → Diff Generator → Events → Notification Engine`), never
reaching back upstream to recompute or re-read a domain engine's output
for itself.

**Seven-gate waterfall, frozen — one failure ends evaluation, same
shape as every prior waterfall (Health's status determination, the
Recommendation Matrix's lookup):**

```
Event
  |
  v
Gate 1  Justification         -- would something meaningful be lost
  |                              if this were never seen?
  v
Gate 2  Context                -- is the user already looking at this
  |                              information right now?
  v
Gate 3  Notification Eligible? -- does this event TYPE ever notify,
  |                              or does it only ever populate history?
  v
Gate 4  Already Informed?      -- has this exact fact already been
  |                              communicated?
  v
Gate 5  Frequency               -- has this event type already fired
  |                              too recently?
  v
Gate 6  Timing                  -- is right now a good moment to
  |                              deliver it? (delays, never rejects)
  v
Gate 7  Interruption Level      -- how much attention may delivering
  |                              this actually spend?
  v
Create Notification
```

**Gate 1 — Justification.** The philosophy just frozen in 5.0c, applied
as the literal first gate: `LOGGING_STREAK_EXTENDED` on a routine day
fails here (nothing lost seeing it tomorrow); `RECOVERY_STARTED` and
`PENDING_TRANSACTION_DETECTED` pass (the user needs to know, or must
act); `PRIMARY_RECOMMENDATION_CHANGED` passes only when the change is
itself meaningful (per the Eligibility Matrix, not hardcoded here).

**Gate 2 — Context, a new gate found while designing this step, inserted
between Justification and "Notification Eligible."** A fact can pass
Justification and still not deserve a push: if the user is already
looking at the relevant screen (just opened the app, is viewing the
dashboard when a goal completes), a push notification for something
they're already seeing feels broken — open app, receive push, while
inside the app. Context doesn't reject the fact; it downgrades *how* it
surfaces (a banner, not a push) — which is why it sits before Gate 3,
not after: context can turn a would-be-push into an in-app-only
presentation before eligibility-for-notification is even asked.

**Gate 3 — Notification Eligible?, a genuinely different question from
Justification.** Some event *types* never become a notification at all,
even when a specific instance would individually pass Gate 1. Example:
`NEW_BEST_STREAK` — the event legitimately exists (Behavior Engine
computed it, the Diff Generator correctly detected it), but this gate
can decide the type itself only notifies every 7/30/100/365 days, never
on every single occurrence. **The event existing and the event
notifying are two different facts, and this gate is where that
distinction lives** — not in the Diff Generator (which only detects
transitions) and not in Justification (which asks about one instance,
not the type as a whole).

**Gate 4 — Already Informed?** Not a repeat of Justification (which
asks "does this matter") or Frequency (which asks "too often") — this
asks only: *has this exact fact already been communicated?* Three
snapshots today all still showing `RECOVERY_STARTED` (because the
condition hasn't changed) means one notification, not three; the same
holds for a pending transaction already surfaced once.

**Gate 5 — Frequency.** Already frozen (5.4) — per-family windows, not
one global rule: Recovery at most once a day; a pending confirmation
follows up at 30 minutes, 4 hours, then the next morning, then stops
(the already-frozen anti-infinite-reminders rule); a healthy streak
notifies only on a genuine extension, never on an hourly poll.

**Gate 6 — Timing.** Already frozen (5.5) — and explicitly **a delay,
never a rejection**: healthy streak waits for night, recovery reminder
waits for evening, monthly report waits for the next morning, pending
confirmation goes immediately. Timing never turns a "yes" into a "no" —
it only decides *when* the already-decided "yes" gets delivered.

**Gate 7 — Interruption Level.** Already frozen (5.0c) — the last
decision, made only once every earlier gate has passed: Level 0 (in-app
only) through Level 3 (rare, high-importance push).

### A new frozen principle: events are immutable, notifications are contextual

**The same event can produce a push, a Notification-Center-only entry,
or nothing at all, depending on context (Gate 2) and the user's prior
notification history (Gate 4/5) — the event itself never changes.**
This is what keeps the `events` collection (Step 10) and whatever the
Notification Engine produces permanently separate: an event is a
historical fact, written once, immutable; a notification is a decision
made *about* that fact, which can legitimately differ from one delivery
attempt to the next without ever touching the event record itself.

### Eligibility Matrix, frozen as the structural pattern — not hardcoded event names in the waterfall

**Following the same discipline as the Diff Matrix (Step 10.2) and the
Recommendation Matrix (Phase 4): the waterfall above stays generic —
`Justification`, `Context`, `Notification Eligible?`, and so on are
fixed, permanent gate *names*, never branching on a specific event code
inline.** Every event-specific decision (does `NEW_BEST_STREAK` need a
7/30/100/365-day gate; does `PRIMARY_RECOMMENDATION_CHANGED` need a
"meaningful change" sub-rule; which events skip Context entirely) lives
in a separate Eligibility Matrix — a table the waterfall's Gate 3 (and
others, where relevant) looks up against, never a growing chain of
`if event == "X"` branches inside the engine itself. Adding a new event
type later means adding one matrix row, exactly the same maintenance
shape the Diff Matrix already proved out. **The matrix itself is not
built yet** — this freezes the *pattern* it must follow, not its
contents.

### Acceptance test, frozen

Every eligibility decision must be explainable in exactly this shape:

```
LOGGING_STREAK_EXTENDED  -> Should notify? No.
                            Why? Fails Justification (Gate 1) --
                            nothing lost seeing it tomorrow.

RECOVERY_STARTED         -> Should notify? Yes.
                            Why? Passes Justification (Gate 1) --
                            the user loses actionable information
                            otherwise.
```

Same traceability discipline every engine since Health has carried —
never a decision without a named, gate-level reason.

### Phase 5.2A — Eligibility Matrix

**Purpose, frozen: the waterfall (5.2) never changes; the matrix
contains the policy.** Every row answers exactly one question: *can
this event type ever become a notification?* Frequency, timing, and
interruption-level specifics are looked up from their own already-frozen
tables (5.4/5.5/5.0c), not duplicated here.

**Eligibility Type, frozen as three values, not a boolean** — this is
the refinement that makes the matrix scale:

| Type | Meaning |
|---|---|
| `ALWAYS` | Always proceeds to the later gates (Frequency/Timing/Interruption still apply — `ALWAYS` means "always eligible," not "always notifies unconditionally") |
| `CONDITIONAL` | An additional rule (owned by whichever engine the condition references — see `Condition Source`) must evaluate true first |
| `NEVER` | Never becomes a notification — history/analytics only, no further logic needed |

**The matrix, built from this system's actual frozen event vocabulary**
(Step 10.2's Diff Matrix, Step 7's Milestones, and the reused Financial
Events) — not illustrative placeholders:

| Event | Eligibility | Condition Source | Why user cares |
|---|---|---|---|
| `TRANSACTION_CREATED` / `TRANSACTION_CONFIRMED` (pending confirmation) | `ALWAYS` | — | Needs confirmation before it affects finances |
| `HEALTH_WORSENED` | `ALWAYS` | — | Financial health declined |
| `HEALTH_IMPROVED` | `CONDITIONAL` | Health Engine (only when recovering from Red/Amber, not amber-to-amber) | Positive reinforcement, not noise |
| `PRIMARY_RECOMMENDATION_CHANGED` | `ALWAYS` | — (see note below) | Advice changed — this event, by the Diff Matrix's own frozen definition, only fires on an actual `primaryRecommendationCode` change, never on alternatives reordering |
| `RECOVERY_STARTED` | `ALWAYS` | — | User should begin corrective action |
| `RECOVERY_COMPLETED` | `ALWAYS` | — | Reinforces success |
| `RECOVERY_FAILED` | `ALWAYS` | — | The recovery attempt didn't work — user needs to know |
| `RECOVERY_BECAME_IMPOSSIBLE` | `ALWAYS` | — | Immediate attention needed |
| `CATEGORY_BECAME_EXHAUSTED` | `ALWAYS` | — | A budget category just ran out |
| `HEALTHY_STREAK_EXTENDED` | `CONDITIONAL` | Behavior Engine (celebrate meaningful checkpoints only — e.g. 7/14/30 days, not every single day) | Avoid daily congratulation fatigue |
| `HEALTHY_STREAK_BROKEN` | `ALWAYS` | — | A protected streak just ended |
| `LOGGING_STREAK_EXTENDED` | `CONDITIONAL` | Behavior Engine (same checkpoint cadence as above) | Avoid daily congratulation fatigue |
| `LOGGING_STREAK_BROKEN` | `CONDITIONAL` | Behavior Engine (only past a minimum streak length — breaking a 1-day streak isn't news) | User may want to re-engage |
| `SAVING_STREAK_EXTENDED` | `CONDITIONAL` | Behavior Engine (monthly cadence already limits frequency naturally, but still gated by checkpoint) | Encourage long-term saving |
| `SAVING_STREAK_BROKEN` | `ALWAYS` | — | A savings-protection month just failed |
| `NEW_BEST_STREAK` | `CONDITIONAL` | Behavior Engine (only a personal record beyond some minimum margin — not every 1-day improvement over a previous best of 1) | Notify only at genuinely major personal records |
| `MILESTONE_UNLOCKED` | `ALWAYS` | — | A permanent, one-time achievement — never repeats, always worth surfacing |

**Infrastructure operations were never given event codes to begin
with — a stronger form of the same principle, not a `NEVER` row.**
Snapshot creation, Diff Generator runs, and scheduler executions have
no corresponding row in the Diff Matrix (Step 10.2) at all — they were
never events in this system's vocabulary, so there's nothing for the
Eligibility Matrix to even mark `NEVER`. The `NEVER` type is frozen and
kept in the table above as a genuine safety net for whenever a future
event turns out to be infrastructure-flavored despite having a Diff
Matrix row — not because any real event needs it today.

**One reconciliation surfaced while building this, not silently
resolved**: `PRIMARY_RECOMMENDATION_CHANGED` was proposed as
`CONDITIONAL` ("only if advice materially changed") — but the Diff
Matrix (Step 10.2) already only fires this event when
`primaryRecommendationCode` itself changes, never on `alternatives`
reordering, since only the primary code is a diffed field at all. Every
firing is already a real change in what the user should do. Frozen here
as `ALWAYS` for that reason — revisit only if a future case surfaces
where two different codes turn out to feel equivalent to a user (not
demonstrated yet).

**`PENDING_TRANSACTION_DETECTED`, named honestly as not yet a formal
event code**: Family A (5.1) already describes this as "the existing
pending-transaction flow, formalized, not new," but it has never
actually been assigned a Diff-Matrix-style event code — it's detected
live (a bank notification parse), not via daily snapshot comparison,
the same immediate-trigger shape as the reused Financial Events. Listed
above by its natural name for now; formalizing its actual event code is
Family A's own unfinished business, not something to invent inline
here.

### Policy Matrix Pattern — named, frozen as a standing design rule

**Whenever business rules are expected to evolve independently of
engine logic, represent them as declarative tables owned by the
relevant engine, rather than embedding them in procedural code.** This
project has now accumulated four such tables, each doing the same
thing in a different layer:

```
Recommendation Matrix   (Phase 4)     -- Recommendation Engine
Risk Severity Table     (Phase 3.3)   -- Health Engine
Diff Matrix             (Step 10.2)   -- Diff Generator
Eligibility Matrix      (Step 5.2A)   -- Notification Engine
```

Naming this now gives future contributors a standing answer to "where
does a new rule go": if it's a business rule likely to change on its
own timeline, it becomes a table row, not a code branch — the same
"one row, not a rewrite" property that made the Recommendation Matrix
and Diff Matrix each easy to extend without touching their engine's
actual logic.

### Phase 5.3 — Priority (supersedes the earlier five-tier sketch above)

**One question, frozen**: *if every eligible notification were delivered
at the same moment, which should appear first?* Nothing more — Priority
only orders notifications. It has nothing to do with whether a push is
sent (5.0c's Interruption Level), when (5.5's Timing), or how often
(5.4's Frequency).

**Frozen distinction from Eligibility**: Eligibility (5.2) asks "should
this event become a notification at all"; Priority asks a completely
different, later question — given that it already passed Eligibility,
how urgently does it deserve attention relative to everything else that
also passed.

**Four levels, frozen — not five or six; simpler systems reason more
easily:**

| Priority | Meaning |
|---|---|
| Critical | User may lose money or miss an important action |
| High | User should know soon |
| Normal | Useful information, delay is acceptable |
| Low | Positive reinforcement or informational update |

**Frozen principle: Priority depends on user impact, never on the
producing engine.** `RECOVERY_BECAME_IMPOSSIBLE` and
`HEALTHY_STREAK_EXTENDED` both originate from Behavior-adjacent
reasoning, yet land at opposite ends of the scale — Critical vs. Low —
because the question is "what does this mean for the user," never
"which engine said so." A hardcoded `Behavior → High` /
`Health → Medium` mapping was explicitly rejected for this reason.

**A second application of the same principle, found while building the
matrix below, not given in the original example**: a shared name prefix
isn't a shared priority either. `HEALTHY_STREAK_BROKEN`,
`LOGGING_STREAK_BROKEN`, and `SAVING_STREAK_BROKEN` all match the shape
"a streak broke," but they carry different real consequences — a
healthy-spending streak ending is a financial-behavior signal
(High); a logging streak ending is an engagement gap, not a financial
one (Normal); a saving-protection streak ending is retrospective, the
month already closed with nothing left to act on immediately (Normal).
Grouping all three under one "`*_BROKEN` → High" rule would repeat
the exact mistake the engine-based mapping was rejected for, just one
level lower — priority by naming pattern instead of by engine, still
not by actual impact.

**Priority Matrix, frozen, covering this system's real event vocabulary
(Step 10.2's Diff Matrix, Step 7's Milestones):**

| Event | Priority | Reason (one sentence) |
|---|---|---|
| `RECOVERY_BECAME_IMPOSSIBLE` | Critical | Immediate financial action needed |
| `TRANSACTION_CREATED`/`CONFIRMED` (pending confirmation) | High | Needs confirmation before it affects the user's real financial picture |
| `HEALTH_WORSENED` | High | Financial condition deteriorated |
| `RECOVERY_STARTED` | High | User should begin corrective action |
| `RECOVERY_FAILED` | High | The recovery attempt didn't succeed; understanding why matters now |
| `CATEGORY_BECAME_EXHAUSTED` | High | A budget category just ran out; further spending there is unbudgeted |
| `HEALTHY_STREAK_BROKEN` | High | A protected financial-behavior streak just ended — a fresh window to understand why |
| `PRIMARY_RECOMMENDATION_CHANGED` | Normal | Better guidance is available, but not urgent to act on immediately |
| `RECOVERY_COMPLETED` | Normal | Informational success |
| `LOGGING_STREAK_BROKEN` | Normal | An engagement gap, not a financial one |
| `SAVING_STREAK_BROKEN` | Normal | Retrospective — the month already closed, nothing left to act on now |
| `HEALTH_IMPROVED` | Low | Positive reinforcement |
| `LOGGING_STREAK_EXTENDED` | Low | Celebration |
| `HEALTHY_STREAK_EXTENDED` | Low | Celebration |
| `SAVING_STREAK_EXTENDED` | Low | Celebration |
| `NEW_BEST_STREAK` | Low | Achievement |
| `MILESTONE_UNLOCKED` | Low | Achievement |

**Frozen: Priority is absolute — context is handled later, never here.**
`RECOVERY_BECAME_IMPOSSIBLE` stays Critical whether the app is open,
closed, or the user is asleep. Whether that Critical priority actually
becomes an immediate push, a morning push, or a Notification-Center
entry is entirely Context (5.2's Gate 2) and Interruption Level's job —
Priority itself never bends to the situation, which is exactly what
keeps it from quietly becoming a second context engine.

**Frozen: Priority is stable — it never changes because another
notification exists.** If `RECOVERY_STARTED` and `HEALTH_WORSENED` both
fire together, both stay High; the Notification Engine decides display
*order* between them, but neither is demoted to Normal just because the
other is also High. Priority is a property of the event, not of the
batch it happens to arrive in.

**Frozen: every row must be explainable in exactly one sentence**, never
"we decided." The `Reason` column above is not decoration — it's the
same auditability discipline every prior matrix in this spec has
carried.

**Frozen: Priority, Value (5.0c), Timing (5.5), and Interruption (5.0c)
never collapse into a single weighted score.** No `Priority=8, Value=6,
Interruption=2, Final=16`. This project has spent every phase up to now
avoiding hidden weights and opaque scoring (Health's rule-based
waterfall, the Recommendation Matrix, the Diff Matrix, the Eligibility
Matrix — none of them score, all of them classify) — collapsing four
independently-explainable dimensions into one number here would
quietly reintroduce exactly the kind of unexplainable decision this
architecture has refused everywhere else. Each dimension keeps
answering its own distinct question: Priority — how important is the
event; Value — how beneficial is it for the user to know; Timing — when
is the best moment; Interruption — how much attention is justified. None
of the four ever substitutes for another.

### Phase 5.4 — Frequency Philosophy (supersedes the earlier per-family sketch above)

**One question, frozen**: *"How often is it beneficial for the user to
hear about this fact?"* Not "how often can we send notifications" —
that framing optimizes for engagement, not for the user, and is exactly
the mindset Phase 5.0c already rejected.

**Seven rules, frozen:**

1. **Attention is renewable, trust is not.** A user forgives one
   unnecessary notification; they rarely forgive twenty. Frequency's
   real job is protecting long-term trust, not managing a send-count
   budget.
2. **Different facts expire at different rates.** `RECOVERY_BECAME_IMPOSSIBLE`
   stays useful for hours; `PRIMARY_RECOMMENDATION_CHANGED` stays useful
   until viewed; `MILESTONE_UNLOCKED` is a celebration once, forever
   after that; `LOGGING_STREAK_EXTENDED` matters for roughly one day.
   Frequency is a function of how long the underlying fact stays
   actionable, never a flat, fact-agnostic timer.
3. **Repeat only if value still exists, never because the user ignored
   it.** Never resend `MILESTONE_UNLOCKED` — nothing changes by
   repeating it. Do resend a still-pending transaction — the action is
   still available and still matters. The test is "can this still
   change behavior," never "did they open the last one."
4. **Events own their own frequency rule — another Policy Matrix
   (Phase 5.2A's named pattern), never a branch keyed on Priority.**
   Not `if priority == HIGH: resend every 2 hours` — that conflates two
   independent dimensions (5.3 already froze Priority and Frequency as
   separate questions). Instead, each event type gets its own row,
   exactly like the Diff Matrix and Priority Matrix before it.
5. **Frequency decides whether to remind, never whether the event
   happened.** Events (Step 10) stay immutable; notifications are the
   only thing that's ever temporary or repeated.
6. **Escalation is not repetition — a genuinely new event, never a
   resend of the old one.** Recovery Needed on Monday becoming Recovery
   Impossible on Tuesday is not a second reminder about Monday's fact —
   it's `RECOVERY_BECAME_IMPOSSIBLE`, a distinct event the Diff
   Generator already produces on its own frozen terms (Step 10.2).
   Frequency governs repeats of the *same* fact; it has nothing to say
   about a situation becoming a *different*, worse fact.
7. **Silence is always an allowed answer.** A frequency policy may
   legitimately say "never repeat, one notification is enough" —
   milestones are the clearest case; this isn't a gap in the policy,
   it's a valid policy value.

**Frequency Categories, frozen — reusable policies, not raw time values
assigned per event:**

| Policy | Meaning |
|---|---|
| `ONCE` | Never repeated |
| `UNTIL_RESOLVED` | Repeats on a bounded, event-specific schedule while the condition persists — **not literal infinite repetition**; every `UNTIL_RESOLVED` policy still terminates eventually (the already-frozen anti-infinite-reminder rule from 5.0b: a pending transaction follows up at 30 minutes, 4 hours, then the next morning, then **stops**, even if still unconfirmed) |
| `DAILY` | Maximum once per day |
| `WEEKLY` | Maximum once per week |
| `MONTHLY` | Maximum once per month |

The Frequency Matrix itself (assigning one policy per event, mirroring
the Priority Matrix's per-event rows) is the next sub-step, not built
here — this freezes the categories and the philosophy governing them,
the same order Eligibility (5.2) preceded its own Matrix (5.2A).
Illustrative, not yet the full table:

| Event | Policy |
|---|---|
| `MILESTONE_UNLOCKED` (any milestone) | `ONCE` |
| `RECOVERY_BECAME_IMPOSSIBLE` | `DAILY` |
| Pending transaction confirmation | `UNTIL_RESOLVED` (the already-frozen 30min/4hr/next-morning/stop schedule) |
| `HEALTHY_STREAK_EXTENDED` | `WEEKLY` |

**Acceptance test, frozen**: a frequency policy is correct if the
answer to "why did we notify again" is never *"because they ignored
us"* — it must always be *"because the situation still mattered."*

### Phase 5.4A — Frequency Matrix

**One question, frozen**: *for each event, what reminder policy best
preserves usefulness without wasting attention?* Unlike Priority,
Frequency is never about importance — it's about whether repeating this
specific fact can still change the user's behavior.

**Two mechanism questions surfaced while building the actual table
below, resolved here rather than silently glossed over:**

**First — "ONCE" covers two structurally different reasons, not one.**
For Milestones, `ONCE` means *lifetime-permanent*: the exact same
`eventId` can only ever exist once, ever (Step 7's idempotent unlock).
For `RECOVERY_STARTED`/`RECOVERY_COMPLETED`/`RECOVERY_FAILED`/
`HEALTH_IMPROVED`, `ONCE` means something narrower: these are
*transition-moment* events — the Diff Generator only fires them at the
instant a transition happens (Step 10.2), never again for the same
occurrence, so there is structurally only one notification opportunity
per firing regardless of any policy. Both correctly use the label
`ONCE`, but for different underlying reasons — worth naming so a future
reader doesn't assume every `ONCE` row is lifetime-unique the way a
milestone is.

**Second — a real gap: `DAILY`/`WEEKLY`/`MONTHLY` repeat policies need a
standing-condition check the Diff Generator alone cannot provide.**
`HEALTH_WORSENED` and `RECOVERY_BECAME_IMPOSSIBLE` are themselves
transition-moment events too — the Diff Generator fires them once, at
the moment Health moves to Red or Recovery becomes impossible, and
never again while the condition merely *persists* unchanged across
subsequent days. A `DAILY` reminder policy for either therefore cannot
be "repeat the original event" (there's nothing to repeat — it already
fired once) — it must instead mean **"while today's current snapshot
still shows this condition true, and the last reminder was sent more
than a day ago, generate a new reminder notification."** This is a
distinct mechanism — reading the *current* state directly, not reacting
to a Diff-detected transition — and is **named here as a real
implementation requirement for whenever the Notification Generator
(5.6) is actually built, not resolved in full now.**

**Reconciled against this system's real event vocabulary — some
proposed rows removed or merged, named honestly:**

- **The five separate milestone rows collapse into one.** There is only
  one Diff-Matrix-level event, `MILESTONE_UNLOCKED` (Step 10.2) — which
  specific milestone unlocked (`FIRST_EXPENSE_LOGGED`,
  `FIRST_HEALTHY_WEEK`, `FIRST_GOAL_COMPLETED`,
  `LOGGING_STREAK_30_DAYS`) is a payload field, never a distinct event
  type of its own. One row, not five.
- **`UNHEALTHY_SPENDING_PATTERN` removed — it isn't a real event.** It's
  a Behavior Summary *reason* (Step 8), computed from `behaviorState`
  directly; the Diff Matrix (Step 10.2) has no rule watching Behavior
  Summary's `status`/`primaryReason` fields at all, so the Diff
  Generator would never actually produce this as an event. Not
  included, named honestly rather than silently kept as if it existed.
- **`OTP_REQUIRED`, `TRANSFER_FAILED`, `BILL_DUE_TODAY` removed — these
  describe features this app hasn't built** (no OTP flow, no transfers,
  no bill-due-date tracking anywhere in this spec). Illustrative of a
  real future category ("live, non-diff events also need frequency
  policies"), not fabricated here to fill the table.
- **`PENDING_TRANSACTION_DETECTED` kept, with its already-named
  caveat** (5.2A): not yet a formal event code, live-triggered rather
  than diff-detected — included because the underlying flow is real,
  even though its exact event code isn't formalized yet.

**The Frozen Frequency Matrix:**

| Event | Policy | Reason |
|---|---|---|
| `MILESTONE_UNLOCKED` | `ONCE` | Lifetime-permanent per unique milestone code (Step 7) |
| `LOGGING_STREAK_EXTENDED` | `WEEKLY` | Daily praise becomes repetitive |
| `LOGGING_STREAK_BROKEN` | `DAILY` | User can recover tomorrow — situation may change day to day |
| `HEALTHY_STREAK_EXTENDED` | `WEEKLY` | Celebrate sustained behavior, not every increment |
| `HEALTHY_STREAK_BROKEN` | `DAILY` | Actionable while rebuilding |
| `SAVING_STREAK_EXTENDED` | `MONTHLY` | Evaluated monthly (Step 5's own cadence) |
| `SAVING_STREAK_BROKEN` | `MONTHLY` | A month-level outcome, nothing sub-monthly to repeat |
| `RECOVERY_STARTED` | `ONCE` | Transition-moment event — one firing per occurrence, structurally |
| `RECOVERY_COMPLETED` | `ONCE` | Transition-moment event — celebrate the completion once |
| `RECOVERY_FAILED` | `ONCE` | Transition-moment event — the outcome is already finalized |
| `RECOVERY_BECAME_IMPOSSIBLE` | `DAILY` | Standing-condition check (see mechanism note above) — action is still valuable each day it remains true |
| `HEALTH_WORSENED` | `DAILY` | Standing-condition check — the user still has opportunity to improve while Health stays Red |
| `HEALTH_IMPROVED` | `ONCE` | Transition-moment event — the positive transition already occurred |
| `PRIMARY_RECOMMENDATION_CHANGED` | `UNTIL_RESOLVED` | Continues until the user acts, or the recommendation changes again |
| `CATEGORY_BECAME_EXHAUSTED` | `DAILY` | Standing-condition check — the category may un-exhaust or stay exhausted; each day it's still true is still worth a reminder, same shape as `HEALTH_WORSENED` |
| Pending transaction confirmation | `UNTIL_RESOLVED` | The bounded 30min/4hr/next-morning/stop schedule already frozen in 5.0b/5.4 |

**`CATEGORY_BECAME_EXHAUSTED` added here, found missing while auditing
this matrix for 5.6B's Rule 3** — every other event in the frozen
Priority Matrix (5.3) and Eligibility Matrix (5.2A) had a Frequency
policy; this one didn't, an oversight in the original pass, not a
deliberate omission.

**Rule 8 — Frequency is event-owned, frozen.** Every event has exactly
one frequency policy; the matrix is the single source of truth. No
event inherits a policy from its family or its Priority — the same
"policy in data, not code" discipline the Diff Matrix and Priority
Matrix already established.

**Rule 9 — Frequency and Timing are independent, frozen.** `Frequency =
DAILY` answers "may we notify again"; `Timing = 8:00 PM` (5.5) answers
"if we do, when." Neither ever substitutes for the other — the same
non-collapsing-dimensions principle already frozen for Priority/Value/
Interruption in 5.0c/5.3, extended here to a fourth dimension.

**Acceptance test, frozen**: every row must be defensible with one
sentence — *"repeating this notification at this cadence can still help
the user make a better decision."* If that sentence can't honestly be
defended, the policy is too frequent.

### Phase 5.5 — Timing Philosophy (supersedes the earlier "never random" sketch above)

**One question, frozen**: *if this notification deserves to exist, when
is the moment the user is most likely to benefit from seeing it?* Not
"when are they most likely to click," not "when are they online" —
either framing optimizes for engagement, the same mistake 5.0c already
rejected for the rest of Phase 5.

**Nine rules, frozen:**

1. **Timing optimizes benefit, not delivery.** A notification can be
   important, eligible, and valuable, and still be badly timed — "your
   spending is unhealthy" at 2:30 AM is technically correct and
   practically useless; the same fact at 8 PM, before tomorrow's
   spending begins, is actually useful.
2. **Timing never changes importance.** Priority (5.3) decides how
   important; Timing decides only when to say it. Completely
   independent dimensions, the same non-collapsing principle already
   frozen for Priority/Value/Interruption/Frequency.
3. **Deliver before the next relevant decision.** Spending feedback
   before tomorrow begins; a recommendation shortly after it's
   computed; a pending transaction soon after detection; a saving
   evaluation once the month has actually closed.
4. **Natural user rhythm beats clock precision.** Prefer Morning/
   Afternoon/Evening/Night over `19:43` — humans live by routines, not
   timestamps; the scheduler maps a rhythm window to an actual
   execution time, never the reverse.
5. **Late is better than wrong.** If the ideal window is missed, deliver
   later — a healthy-streak celebration arriving tomorrow morning is
   acceptable; one arriving "yesterday" is impossible, and fabricating
   urgency to avoid the delay would violate the anti-manipulation rule
   already frozen in 5.0b.
6. **Timing may delay, batch, or suppress duplicate delivery — it never
   invents a new event.** The same "transports, never creates" boundary
   already frozen for every piece of Era 2 infrastructure.
7. **Immediate is justified only when delay would reduce usefulness.**
   Pending transaction detected, a changed recommendation, recovery
   becoming impossible — these lose value quickly, so they're delivered
   immediately; most facts don't share this property and shouldn't be
   rushed just because urgency feels more important.
8. **Celebrations prefer reflection over action.** Healthy week, monthly
   savings, recovery completed — the achievement already happened;
   recognition after the fact reinforces the behavior better than
   recognition mid-action would.
9. **Timing is context-aware — the event never changes, only delivery
   does.** A recommendation generated at 9 AM can send immediately; the
   same recommendation generated at 2 AM waits until morning. This is
   Gate 2 (Context, spec 5.2) and Rule 5 above working together, not a
   new decision layered on top of them.

**A real scheduling conflict found while reconciling this against what
Steps 9-12 actually built, resolved here rather than left implicit**:
Spending/Recovery Behavior can only be evaluated once a day is *fully
over* (4.5.2's own frozen reasoning — a day's health status isn't known
until it ends), and the Daily Snapshot Scheduler that performs that
evaluation is registered to run at **00:30**, not midnight itself (Step
12.4). This means a healthy-streak fact about *today* isn't actually
known until roughly half an hour into *tomorrow* — a `NIGHT` timing
window, read literally as "tonight," is structurally impossible for
anything depending on that day's own evaluation. **Resolved: `NIGHT`
means the evening of the day the scheduler's 00:30 run belongs to (the
next calendar day from the user's perspective), not the same evening
the underlying day's activity happened** — there is an inherent ~20-hour
lag between "the streak extended" and "the user finds out," and per
Rule 5, that lag is the correct, honest tradeoff, not a bug to
engineer around. The already-frozen "3 AM is never acceptable" floor
rule is exactly what prevents anyone from "fixing" this by pushing the
notification the moment the 00:30 job completes.

**Timing Categories, frozen — reusable windows, not raw timestamps:**

| Category | Meaning |
|---|---|
| `IMMEDIATE` | Within minutes |
| `MORNING` | First active period of the day |
| `AFTERNOON` | Midday |
| `EVENING` | End of the active day |
| `NIGHT` | After that day's evaluation has actually completed (see the scheduling note above — in practice, the following day's evening, not the same night) |
| `MONTH_END` | After that month's evaluation (the month rollover, Step 12.3) has completed |

The Timing Matrix itself (assigning one category per event, mirroring
the Frequency Matrix's per-event rows) is the next sub-step, not built
here — same order as Eligibility/Frequency, philosophy before matrix.

**Acceptance test, frozen**: for every notification, ask *"would
delivering this earlier or later reduce its usefulness?"* If no, timing
doesn't matter and should stay simple (deliver whenever it's eligible).
If yes, the chosen window must maximize usefulness — never clicks.

**The four communication dimensions are now complete, frozen as a
set**: Eligibility (should this become a notification), Priority (how
important), Frequency (how often may it repeat), Timing (when should it
be delivered). Once the Timing Matrix exists, the remaining work shifts
from philosophy into orchestration — taking an event and applying all
four policies consistently to produce the final notification.

**3 AM is never an acceptable time for anything**, regardless of family
or priority — a floor rule carried forward, not a per-family exception.

### Phase 5.5A — Timing Matrix

**One question, frozen**: *given this event, when is the first moment
the user can actually benefit from knowing it?* Not when it happened,
not when it was detected, not when the scheduler runs — those are
implementation details Timing must not leak into its own reasoning.

**The redefinition already proposed for `NIGHT`/`MONTH_END`, adopted
exactly as given**: `NIGHT` means *first delivery after the daily
evaluation cycle completes*, not a literal clock time; `MONTH_END`
means *first delivery after the monthly rollover finishes*. Both are
now defined relative to a completed computation, never a wall-clock
hour — removing the clock dependency entirely, consistent with Rule 4
(natural rhythm over clock precision).

**A larger finding, surfaced by auditing *how* these events actually
get produced, not just what they mean — bigger than any prior matrix's
correction:** nearly every event in the proposed `IMMEDIATE` column is
**only ever discovered once a day, at 00:30**, because the Diff
Generator (Step 10) that produces `HEALTH_WORSENED`, `HEALTH_IMPROVED`,
`RECOVERY_STARTED`, `RECOVERY_BECAME_IMPOSSIBLE`, `RECOVERY_COMPLETED`,
`PRIMARY_RECOMMENDATION_CHANGED`, and `MILESTONE_UNLOCKED` is *only ever
invoked* by the Daily Snapshot Scheduler (Step 11/12), which runs once
daily. There is no live, intra-day path that calls the Diff Generator
at all. **This means "immediate" cannot mean "the instant the
underlying real-world fact became true" for any of these events — it's
already hours-to-a-day old by the time it's even discovered.** Only
genuinely live-triggered facts (the reused Financial Events —
`TRANSACTION_CREATED`/`CONFIRMED` — and the not-yet-formalized
`PENDING_TRANSACTION_DETECTED`) can be truly instantaneous, because
they never pass through the once-daily Diff Generator at all.

**Resolution, frozen: `IMMEDIATE` means two different things depending
on the event's source, the same "one label, two underlying reasons"
shape already found for `ONCE` in the Frequency Matrix (5.4A) — named
explicitly here for the same reason, so it isn't misread as a single
concept:**

- **Live-triggered `IMMEDIATE`** (Financial Events,
  `PENDING_TRANSACTION_DETECTED`) — genuinely real-time, no scheduler
  dependency, delivered within minutes of the actual fact.
- **Diff-sourced `IMMEDIATE`** (everything else in the table below) —
  *don't artificially withhold past the earliest available moment*,
  where "earliest available" is bounded by the 00:30 discovery and the
  already-frozen "3 AM is never acceptable" floor — in practice, this
  resolves to **first thing the following morning**, not real-time.
  `IMMEDIATE` here is a statement about *not deliberately delaying
  further*, not a claim about matching the speed of the underlying
  event.

**This reframes what `NIGHT` actually means relative to diff-sourced
`IMMEDIATE`, too**: since both are discovered at the same 00:30 moment,
the distinction isn't "how fast can we tell the user" — it's **whether
the notification should ship at the earliest available moment
(`IMMEDIATE`) or be deliberately *held* past that moment for a better
psychological effect (`NIGHT`)**. A streak celebration doesn't wait
until evening because discovery was slow — it waits because reflection
(5.5's Rule 8) genuinely lands better later in the day, even though the
fact was already known since early morning.

**One real, honest limitation named here, not solved**: under the
current once-daily-scheduler architecture, `RECOVERY_BECAME_IMPOSSIBLE`
cannot actually reach the user same-day if the underlying overspending
happened, say, at 8 PM — the earliest possible discovery is still
00:30 the *next* day. Achieving genuine same-day urgency for a
Diff-Matrix event would require either a live, intra-day diff check or
computing Recovery Plan status directly at transaction time (bypassing
the Diff Generator for this one case) — neither exists today. Timing
policy alone cannot close this gap; it can only decide not to make the
gap worse by adding an artificial delay on top of it.

**The Frozen Timing Matrix:**

| Event | Timing | Why |
|---|---|---|
| Pending transaction confirmation | `IMMEDIATE` (live-triggered) | User can still act — genuinely real-time, not scheduler-bound |
| `PRIMARY_RECOMMENDATION_CHANGED` | `IMMEDIATE` (diff-sourced) | Don't withhold past the morning discovery — the advice is already actionable |
| `HEALTH_WORSENED` | `IMMEDIATE` (diff-sourced) | The sooner known, the sooner today's decisions improve |
| `HEALTH_IMPROVED` | `IMMEDIATE` (diff-sourced) | Reinforce progress without artificial delay |
| `RECOVERY_STARTED` | `IMMEDIATE` (diff-sourced) | User should begin corrective action without delay |
| `RECOVERY_BECAME_IMPOSSIBLE` | `IMMEDIATE` (diff-sourced) | Requires attention; already inherently late (see limitation above) — don't make it later |
| `RECOVERY_COMPLETED` | `IMMEDIATE` (diff-sourced) | Positive reinforcement loses value if withheld further |
| `LOGGING_STREAK_EXTENDED` | `NIGHT` | Deliberately held for evening reflection, not urgent |
| `LOGGING_STREAK_BROKEN` | `NIGHT` | User should know before tomorrow, not mid-afternoon |
| `HEALTHY_STREAK_EXTENDED` | `NIGHT` | Reflection-timed celebration |
| `HEALTHY_STREAK_BROKEN` | `NIGHT` | Same day's evaluation, held for evening |
| `SAVING_STREAK_EXTENDED` | `MONTH_END` | Only discoverable once the month closes |
| `SAVING_STREAK_BROKEN` | `MONTH_END` | Same — a month-level outcome |
| `MILESTONE_UNLOCKED` | `IMMEDIATE` (diff-sourced) | Positive reinforcement strongest without delay — a judgment call, not forced by Rule 8's reflection preference, which could equally justify `NIGHT` here; kept `IMMEDIATE` per explicit product intent |
| `CATEGORY_BECAME_EXHAUSTED` | `IMMEDIATE` (diff-sourced) | The sooner known, the sooner the user can stop overspending in that category |
| `RECOVERY_FAILED` | `IMMEDIATE` (diff-sourced) | The outcome is already finalized; withholding it further serves no purpose |

**Both rows above were missing, found while auditing this matrix for
5.6B's Rule 3** — each already has a Priority and (for
`CATEGORY_BECAME_EXHAUSTED`, now) a Frequency row; Timing simply hadn't
caught up, an oversight in the original pass, not a deliberate
omission.

**Frozen principle, exactly as proposed**: *the Timing Matrix describes
the earliest beneficial delivery window, never an exact timestamp.*
The matrix says *when it becomes appropriate*; a future Delivery layer
(5.8) decides the exact moment within that window (quiet hours,
batching, device availability) — the same "policy decides what,
infrastructure decides how" split this project has used everywhere
else.

### Phase 5.6 — Notification Generator Philosophy (supersedes the earlier output-shape sketch above)

**One question, frozen**: *given one event, how do we produce exactly
one notification?* Not how do we send it, not how do we schedule it —
those are 5.8's (Delivery) job. The Generator owns composition only.

**What it must never do, frozen**: detect changes, evaluate health,
compute streaks, determine spending, recompute recommendations, choose
eligible events, or schedule delivery. Every one of those is already
solved by an earlier layer; the Generator only receives their answers.

```
Event
  |
  v
Eligibility Matrix (5.2A) -> Priority Matrix (5.3) ->
Frequency Matrix (5.4A) -> Timing Matrix (5.5A)
  |
  v
Notification Generator
  |
  v
Notification Object
```

This is Notification Engine's equivalent of Snapshot Builder (Step
9.3): Snapshot Builder assembled fields from five engines into one
record; the Notification Generator assembles one record from four
matrix lookups. Neither computes anything new — pure assembly, both
times.

**One input, reconciled against what this system actually produces —
not the illustrative shape first proposed.** The real Event object
(`services/diff_generator.py`'s actual output, Step 10.3) is
`{diffRuleId, event, payload, eventId}` — no `uid` field embedded (it's
implicit in the Firestore path the event was read from, `users/{uid}/
events/{eventId}`, the same "don't duplicate what's already known from
context" discipline used everywhere else), and, found while reconciling
this step, **no `occurredAt`/timestamp field at all** — the only trace
of *when* is embedded inside `eventId`'s string
(`{uid}:{snapshotDate}:{diffRuleId}[:distinguisher]`), which works, but
only implicitly. **Named as a real, small gap, not fixed by changing
already-frozen code here**: a proper `snapshotDate` field on the event
object itself would make "when did this happen" an explicit, readable
field instead of something a caller has to parse out of an ID string —
worth adding to `diff_generator.py`'s `_build_events()` whenever 5.6
actually moves to implementation, not required to design the
Generator's philosophy today.

**Existing inputs, besides the event, frozen as delivery preferences,
never business logic**: user profile, notification preferences,
current quiet hours, language. None of these change *what* the
notification says — only how/when it's ultimately delivered (5.8).

**One output — exactly one Notification object, reconciled against the
already-frozen Lifecycle (5.7) and vocabularies (5.0c, 5.3, 5.5A) rather
than the illustrative shape first proposed:**

```
{
  "id": "...",
  "eventId": "...",              // traces back to exactly one Event, Rule 2
  "eventCode": "HEALTH_WORSENED",
  "priority": "High",            // 5.3's real vocabulary: Critical/High/Normal/Low
  "timing": "IMMEDIATE",         // 5.5A's real vocabulary: IMMEDIATE/NIGHT/MONTH_END
  "interruptionLevel": 2,        // 5.0c's real vocabulary: 0/1/2/3, never a new label
  "title": "...",
  "body": "...",
  "deepLink": "...",
  "createdAt": "...",
  "status": "Created"            // 5.7's real first lifecycle state, not a new "Pending"
}
```

**Corrected from the first draft**: `interruptionLevel: "ACTIVE"` and
`status: "PENDING"` were placeholder labels that don't match anything
actually frozen — Interruption Level is a numeric 0-3 scale (5.0c), and
the Lifecycle's first state is `Created` (5.7), not a separately
invented `Pending`. Reusing the real vocabularies here rather than
letting the Generator's own output drift into a third naming scheme.

**Rule: one event produces one notification candidate, frozen.** Never
one event fanning out to three notifications, never three events
collapsing into one mega-notification — bundling, if it ever happens,
is a Delivery-layer concern (5.8), never the Generator's.

**Six Generator rules, frozen:**

1. **Never invents facts — only copies.** Every value in the output
   traces back to the event, a matrix lookup, or user preferences —
   never a new computation.
2. **Every notification originates from exactly one event** — `eventId`
   is always present and always singular, never a merge of several.
3. **Deterministic.** The same event, run through the Generator twice,
   produces the same notification — the same Rule 9 determinism
   already frozen for Snapshot Builder, extended here.
4. **Never decides delivery.** It proposes; Delivery (5.8) executes —
   the same "logic owns logic, caller owns timing/execution" split
   already used for Snapshot Builder vs. the Scheduler.
5. **Never changes the event.** Events (Step 10) stay immutable;
   notifications are the disposable, re-creatable side of the pipeline.
6. **Owns wording — the first layer in this entire system that converts
   a system fact into human language.** `HEALTH_WORSENED` becomes "You've
   been spending faster than planned." **Checked against Recommendation
   Engine's own output for a potential duplicate-wording conflict**:
   Recommendation objects carry `code`/`type`/`actionValue`/
   `actionUnit`/`category`, never a natural-language sentence — so there
   is no existing wording anywhere upstream for the Generator to
   duplicate or fail to reuse. This really is new ground, not a
   re-authoring of something that already existed.

### Where templates live — the Template Matrix (Option C), frozen as the pattern

**Same discipline as every matrix before it**: not hardcoded
`if event == X` branches (Option A), not a bare dictionary with no
review structure (Option B) — a **Notification Template Matrix**,
`Event -> Title -> Body -> CTA -> Deep Link`, the same "policy in data,
never in procedural code" shape as the Recommendation Matrix, Diff
Matrix, Eligibility Matrix, Priority Matrix, Frequency Matrix, and
Timing Matrix before it. **The actual per-event wording table is the
next sub-step (5.6A), not built here** — this freezes the pattern the
table must follow, matching how Eligibility/Priority/Frequency/Timing
each froze their philosophy before their own matrix.

**Acceptance test, frozen**: *if a product designer wants to change a
notification's wording, can they do it by editing the Template Matrix
alone, without touching Generator logic?* If yes, product content stays
separate from system behavior — the same separation this project has
maintained at every layer since the Recommendation Matrix.

### Phase 5.6A — Notification Template Matrix

**One question, frozen**: *given an event, how should BachatBot talk to
the user?* Not what notification to send — the event, eligibility,
priority, and timing are already decided by the time this question is
asked. Only expression remains.

**Two corrections found while reconciling this against what's actually
real, before building the table:**

1. **The localization claim needed checking, not assuming.** The actual
   frozen `LanguageEnum` (`schemas/common.py`) has exactly two values —
   `NEPALI ('ne')` and `ENGLISH ('en')` — no third "Romanized Nepali"
   language preference exists anywhere in this codebase. Romanized
   Nepali is something the chat NLU can *parse as input* (e.g. "aja
   maile 500 momo ma khaye"), which is a different capability from
   having a *declared output-language target* — conflating the two
   would overstate what's actually built. **The localization
   *principle* is still correct and frozen as given** (template
   identifiers resolved through a localization layer, never a literal
   string baked into the matrix) — it just resolves against the real
   two-language `LanguageEnum`, not three.
2. **"Guidance" (used in the illustrative Purpose examples) isn't one of
   the seven psychological purposes actually frozen in 5.0b.** The real
   seven are Awareness, Action, Protection, Progress, Achievement,
   Reflection, Re-engagement — no eighth category. Every row below maps
   to one of those seven exactly, not a new one invented to fit a
   specific event more comfortably.

**Five rules, frozen, exactly as given:**

1. **Title states the fact; body explains the meaning; CTA suggests the
   next action.** Never mixed — "Spend less today!" is advice
   masquerading as a title, not a fact.
2. **Never lie, never exaggerate beyond what the source engine actually
   concluded.** A template for `HEALTH_WORSENED` may not say "You're in
   danger" unless Health Engine's own classification actually reached
   that severity — the template can never editorialize past its source.
3. **One emotional purpose per notification, never several stacked
   together** — one emotion, one action, not "Congratulations! But be
   careful! Check your report!"
4. **The CTA must always resolve the specific event, never a generic
   "Open App."** `LOGGING_STREAK_BROKEN` → "Log today's expenses";
   `HEALTH_WORSENED` → "Review your spending"; `RECOVERY_STARTED` →
   "Open Recovery Plan"; `PRIMARY_RECOMMENDATION_CHANGED` → "View
   Recommendation."
5. **Never mention internal terminology.** No "Recovery Behavior
   updated," no "Spending Behavior Engine detected," no "Diff Generator
   found" — only human language. This is the same Fact/Presentation
   separation already frozen for the Event vs. the Notification
   themselves (5.6): the event is `HEALTH_WORSENED`; the notification is
   "Spending is increasing faster than planned."

**The Frozen Template Matrix** — `Event | Purpose | Title (template ID) |
Body (template ID) | CTA | Deep Link`, reconciled against this system's
real event vocabulary. Template IDs stand in for the actual localized
string, which a future localization layer resolves per user
`preferences.language` — the English shown here is illustrative, not
the frozen artifact itself:

| Event | Purpose | Title (`TEMPLATE_ID` → illustrative English) | Body | CTA |
|---|---|---|---|---|
| Pending transaction confirmation | Action | `TITLE_PENDING_TXN` → "New transaction detected" | `BODY_PENDING_TXN` → "Was this your transaction?" | "Confirm transaction" |
| `PRIMARY_RECOMMENDATION_CHANGED` | Action | `TITLE_RECOMMENDATION_CHANGED` → "Your recommendation has changed" | `BODY_RECOMMENDATION_CHANGED` → "Your financial situation changed, so has our advice" | "View recommendation" |
| `HEALTH_WORSENED` | Awareness | `TITLE_HEALTH_WORSENED` → "Spending pace increased" | `BODY_HEALTH_WORSENED` → "You're spending faster than your monthly plan" | "Review your spending" |
| `HEALTH_IMPROVED` | Progress | `TITLE_HEALTH_IMPROVED` → "Your finances are back on track" | `BODY_HEALTH_IMPROVED` → "Your spending pace has improved this week" | "View your report" |
| `RECOVERY_STARTED` | Action | `TITLE_RECOVERY_STARTED` → "Recovery plan started" | `BODY_RECOVERY_STARTED` → "We've built a plan to help you get back on track" | "Open Recovery Plan" |
| `RECOVERY_BECAME_IMPOSSIBLE` | Protection | `TITLE_RECOVERY_IMPOSSIBLE` → "Your recovery plan needs attention" | `BODY_RECOVERY_IMPOSSIBLE` → "The current plan is no longer enough — let's adjust it" | "Review Recovery Plan" |
| `RECOVERY_COMPLETED` | Achievement | `TITLE_RECOVERY_COMPLETED` → "Recovery complete" | `BODY_RECOVERY_COMPLETED` → "You brought your spending back on track" | "View your progress" |
| `LOGGING_STREAK_EXTENDED` | Progress | `TITLE_LOGGING_EXTENDED` → "{n}-day logging streak" | `BODY_LOGGING_EXTENDED` → "Consistent budgeters rarely miss two days in a row" | "View your streak" |
| `LOGGING_STREAK_BROKEN` | Protection | `TITLE_LOGGING_BROKEN` → "Your logging streak ended" | `BODY_LOGGING_BROKEN` → "Tomorrow starts a new opportunity" | "Log today's expenses" |
| `HEALTHY_STREAK_EXTENDED` | Progress | `TITLE_HEALTHY_EXTENDED` → "{n} healthy days" | `BODY_HEALTHY_EXTENDED` → "Your spending has stayed on track this week" | "View your streak" |
| `HEALTHY_STREAK_BROKEN` | Protection | `TITLE_HEALTHY_BROKEN` → "Your healthy streak ended today" | `BODY_HEALTHY_BROKEN` → "Tomorrow starts a new opportunity" | "Review today's spending" |
| `SAVING_STREAK_EXTENDED` | Progress | `TITLE_SAVING_EXTENDED` → "Another month protected" | `BODY_SAVING_EXTENDED` → "You saved money again this month" | "View your savings" |
| `SAVING_STREAK_BROKEN` | Reflection | `TITLE_SAVING_BROKEN` → "This month's savings goal was missed" | `BODY_SAVING_BROKEN` → "Here's what changed this month" | "View monthly report" |
| `MILESTONE_UNLOCKED` | Achievement | `TITLE_MILESTONE_{code}` → e.g. "First Healthy Week unlocked!" | `BODY_MILESTONE_{code}` → per-milestone, e.g. "You kept your spending healthy for 7 days straight" | "View milestone" |
| `CATEGORY_BECAME_EXHAUSTED` | Protection | `TITLE_CATEGORY_EXHAUSTED` → "{category} budget exhausted" | `BODY_CATEGORY_EXHAUSTED` → "You've used all of this month's {category} budget" | "Review {category} spending" |
| `RECOVERY_FAILED` | Reflection | `TITLE_RECOVERY_FAILED` → "This recovery attempt didn't succeed" | `BODY_RECOVERY_FAILED` → "Here's what happened, and what might help next time" | "View recovery history" |

**Both rows above were missing, found while auditing this matrix for
5.6B's Rule 3** — same oversight as the Frequency and Timing gaps just
found; neither was a deliberate exclusion.

**Deep Link column intentionally left as a design placeholder, not
frozen row-by-row here** — it depends on Flutter's actual route names
(Step 13, not yet built), so freezing exact route strings now would be
guessing at a UI layer that doesn't exist yet; each row still gets one
once routes exist, per Rule 4's "always resolves the event."

**Acceptance test, frozen**: *if the app's tone changes (formal to
friendly, English to Nepali, emoji to no emoji), can the Template Matrix
change without touching Notification Generator logic?* If yes, the same
separation held everywhere else in this project — facts from engines,
policy from matrices, language from templates — extends cleanly to
this final, most human-facing layer too.

### Phase 5.6B — Notification Generator Pipeline

**One question, frozen**: *how does one event become one notification?*
Not how it's delivered, not how it's stored — only how it's assembled.

**One input, frozen**: exactly one Event. Nothing else triggers the
Generator — no polling, no business logic of its own.

**A structural overlap resolved before freezing the pipeline, found by
checking this against the already-frozen 5.2 Eligibility waterfall
rather than accepting the proposed stage list as-is**: the original
sketch listed "Run Eligibility Matrix" then separately "Assign
Frequency," "Assign Timing," "Assign Interruption Level" as later
Generator stages — but 5.2's own waterfall *already* has Frequency
(Gate 5), Timing (Gate 6), and Interruption Level (Gate 7) as its own
gates. By the time the Generator is ever invoked, the full waterfall
has already run and those three values are already decided — the
Generator doesn't re-decide them, it only **carries them forward**
(pure copying, no lookup) onto the output object. **Priority (5.3) is
different — the Eligibility waterfall never touches it at all**
(5.3 itself: "Priority only orders notifications... after passing
eligibility"), so Priority genuinely does need its own fresh lookup
inside the Generator, unlike the other three.

**Corrected pipeline, frozen:**

```
Receive an already-eligible Event (Eligibility waterfall has already run)
        |
        v
Look up Priority (5.3)              -- a genuine new lookup
        |
        v
Carry forward Frequency/Timing/Interruption Level
        (already decided by the Eligibility waterfall's own gates 5-7 --
         copied, never re-decided)
        |
        v
Find Template (5.6A)
        |
        v
Resolve Localization
        |
        v
Assemble Notification
        |
        v
Return Notification
```

Every stage either looks something up once or copies an already-decided
value — nothing computes new financial information, matching the
original intent exactly, just without the redundant double-decision the
first sketch would have created.

**Seven rules, frozen:**

1. **The Generator never re-evaluates.** Eligibility already answered
   "should this notify" — the Generator never asks again.
2. **One matrix per decision, no matrix depends on another.** Priority,
   Frequency, Timing, Template — each a single, independent lookup.
3. **Missing policy is an error, never a silent default.** If an event
   has no Priority row, no Frequency row, or no Template row, that is a
   configuration error, not "default Normal" — the mirror image of the
   Diff Generator's Rule 10 ("unknown changes produce nothing"): there,
   silence is correct because the change was never claimed by any rule;
   here, silence is *wrong*, because the event is already known to
   exist and every policy table is expected to know about it too.
4. **The Generator is pure.** Same input, same notification, every
   time — no timestamps generated internally, no randomness, no
   database writes, no side effects. Fully unit-testable.
5. **Delivery metadata comes later.** No `deliveredAt`/`readAt`/
   `openedAt`/`dismissedAt` — those belong to the Lifecycle (5.7); the
   Generator only creates the initial object.
6. **Human language is the final step.** All policy decisions happen
   before wording, never the reverse — text is never generated and then
   conditionally discarded.
7. **The payload is preserved, never discarded.** The event's own
   payload (e.g. `{"from": 6, "to": 7}` or `{"code": "FIRST_HEALTHY_WEEK"}`)
   carries through onto the notification object unchanged — templates,
   future UI, and analytics may all need it later.

**Rule 3, actually run as an audit against the four already-frozen
matrices, not just stated as a principle — and it found real gaps,
exactly as every previous cross-matrix check in this project has:**

- **`CATEGORY_BECAME_EXHAUSTED`** had Eligibility and Priority rows, but
  **no Frequency, Timing, or Template row at all** — now added to all
  three (above).
- **`RECOVERY_FAILED`** had Eligibility, Priority, and Frequency rows,
  but **no Timing or Template row** — now added to both (above).
- **`NEW_BEST_STREAK`** is a different, deeper kind of gap, named but
  not fixed here: it has Eligibility (5.2A) and Priority (5.3) rows, but
  no Frequency, Timing, or Template row *and*, more fundamentally, **no
  Diff Matrix rule producing it at all** (Step 10.2) — the same
  unreachable-event status already flagged for `BACK_ON_TRACK`,
  `CONSISTENT_LOGGER`, and `MONTH_FINISHED_UNDER_BUDGET` in the Event
  Catalog. A phantom event with partial downstream policy but no
  upstream producer can never actually violate Rule 3 in practice (it
  never fires), but the partial configuration is worth naming as
  unfinished, not silently left inconsistent. Completing its Diff
  Matrix rule is a Step 10.2 amendment, out of scope for this pipeline
  step.

**Output, frozen, reconciled against the real Event/vocabulary
corrections already made in 5.6:**

```
{
  "id": "...",
  "eventId": "...",
  "eventCode": "HEALTH_WORSENED",
  "priority": "High",
  "frequency": "DAILY",
  "timing": "IMMEDIATE",
  "interruptionLevel": 2,
  "templateId": "TITLE_HEALTH_WORSENED",
  "title": "Spending pace increased",
  "body": "You're spending faster than your monthly plan",
  "payload": { "from": "green", "to": "amber" },
  "deepLink": "...",
  "status": "Created"
}
```

No delivery information anywhere in this object — `createdAt` is
assigned by whichever layer actually persists the notification (5.7),
not fabricated inside the pure Generator itself (Rule 4).

**Acceptance test, frozen**: *if tomorrow a new event is added to the
Diff Matrix, can the Notification Generator support it by adding one
row to each policy matrix and one template, without modifying Generator
logic?* Given the corrected pipeline above (Priority, Template, and
Localization are the only genuine lookups; Frequency/Timing/
Interruption are carried forward, never re-implemented), the answer is
yes — the same "code defines the pipeline, matrices define product
behavior" property this project has held since the Recommendation
Matrix.

### Rule 8 — Generator Fails Fast, frozen

**If any required policy is missing — no Template, no Priority, a
malformed event, an unknown event code — the Generator must fail
explicitly.** It must never silently assign a default priority, invent
a template, skip wording, or produce a partial notification. A
notification is either fully defined, or it is not generated at all.

This is the same "complete or nothing" invariant already frozen for
Snapshot Builder (Rule 3, Step 9.0) and the mirror image of the Diff
Generator's Rule 10 ("unknown changes produce nothing") — there,
silence is correct because nothing claimed the change; here, silence
would be *wrong*, because the event is already known to exist and every
policy table is expected to know about it too. Both rules protect the
same property from opposite directions: neither module ever fabricates
a fact it wasn't given.

### Notification Generator — Implementation — FROZEN

Implemented in `services/notification_generator.py`,
`generate_notification(event) -> dict`, matching the corrected 5.6B
pipeline exactly: Priority is a genuine lookup; Frequency and Timing are
read from their own static tables (Rule 3's audit already confirmed
every real event has a row in each); Template resolution and payload
interpolation are the only remaining work. `MILESTONE_UNLOCKED` gets a
second-level lookup keyed by `payload["code"]`, since it needs a
different template per milestone rather than one shared template.

**One real mismatch found and fixed during implementation, not
silently worked around**: the illustrative Template Matrix (5.6A) used
`{n}` as a streak-count placeholder, but the actual Event payload shape
`diff_generator.py` produces is `{"from": X, "to": Y}` — there is no
`n` key anywhere. Every streak-count template now interpolates `{to}`
(the new value after the transition), matching the real payload rather
than the illustrative one.

All 15 unit test scenarios pass (`tests/test_notification_generator.py`
— no Firestore needed, since this module only looks up static tables
and assembles an object): correct resolution for a plain event, correct
`{to}`/`{category}` interpolation using the real payload shape, both
rows the Rule 3 audit added (`CATEGORY_BECAME_EXHAUSTED`,
`RECOVERY_FAILED`) resolving correctly end to end, the milestone
per-code lookup returning genuinely different templates for different
codes, Rule 8 firing for an unknown milestone code/unknown event
code/missing `event` key/payload missing a required template key,
determinism across two identical calls, and the output containing
exactly the frozen keys with no delivery metadata leaking in.

**Deliberately not implemented yet**: the 5.2 Eligibility waterfall
itself (the stateful gates — Justification, Context, Already-Informed —
that decide whether `generate_notification()` should even be called for
a given event) doesn't exist as code. This module assumes its
precondition is already satisfied, per Rule 1; building the waterfall
itself is separate, future work, not something this step needed to
implement to be complete on its own terms.

**A second real gap found while starting Phase 5.7, fixed before
building the Repository around it**: the frozen 5.6B output shape
includes `interruptionLevel` and `deepLink`, but the actual
implementation had silently dropped both. Fixed — both fields are now
always present on the object, valued `None` rather than fabricated,
since neither has a real dependency built yet (`interruptionLevel`
needs the unimplemented Context gate; `deepLink` needs Flutter routes,
Step 13). Present-but-honestly-unknown, not missing.

### Phase 5.7 — Notification Repository

**A numbering collision found and fixed before adding new content**:
this slot previously held an early "Notification Lifecycle" placeholder
(a 7-state sketch: `Created → Delivered → Seen → Opened → Completed →
Expired → Dismissed`), and the next slot held a "Notification Center"
placeholder — both written long before the current roadmap fixed 5.7 as
Repository, 5.8 as Delivery, 5.9 as Review & Freeze. Reconciled below,
not left colliding with two different meanings for the same phase
number.

**One question, frozen**: *how are notifications stored and retrieved?*
Not sending, not push, not FCM, not scheduling, not templates, not
wording — those are already solved (5.6) or belong to Delivery (5.8).
Only persistence.

**Repository responsibilities, frozen — exactly these operations, never
more**: `save(notification)`, `get(notificationId)`, `list(uid)`,
`listUnread(uid)`, `listRecent(uid, limit)`, `markRead(notificationId)`,
`markDismissed(notificationId)`. `listUnread`/`listRecent` are included
deliberately — filtering logic belongs in the Repository, never
duplicated inline in Flutter.

**Five rules, frozen:**

1. **The Repository never generates.** It cannot change wording,
   priority, or timing — those are 5.6's outputs, copied in, never
   edited here.
2. **The Repository never delivers.** It stores; Delivery (5.8) sends.
3. **The Repository never deletes history.** Notifications are user
   history — a user dismissing one doesn't erase it, it only changes
   `status`. This is the append-only-in-spirit philosophy already
   frozen for snapshots and events, extended to notifications.
4. **`status` is the only mutable part.** `title`/`body`/`priority`/
   `eventId`/`payload`/`createdAt` never change after creation; only
   `status`, `readAt`, and `dismissedAt` may.
5. **One notification, one document.** No batching, no arrays — the
   same pattern already used for `dailySnapshots` and `events`.

**The Lifecycle, reconciled — five states, not the original seven,
named as a deliberate simplification**: `Created → Delivered → Read →
Dismissed`, plus `Expired` (a status a notification can reach instead of
being read/dismissed, if its underlying condition resolves first). The
original sketch's `Seen`/`Opened` collapse into `Read` (no distinct
product need yet to track "seen but not opened" separately), and
`Completed` is dropped — a notification doesn't have a completion state
of its own; the underlying event either resolved or didn't, and that's
tracked by the event/behavior layers, not duplicated here.

**A real, serious collision found during real-account verification,
before any test data was written — the collection name itself, not just
its contents.** `users/{uid}/notifications` is already in active
production use by the existing bank-SMS pending-transaction flow
(`routes/chat.py`, `routes/confirm.py` — documents shaped like
`rawText`/`parsedAmount`/`transactionId`/`status: pending|confirmed`,
a completely different system answering a completely different
question). Writing this Repository's documents into that same
collection would have silently mixed two unrelated document shapes
together — caught only because a real-account check found 4
pre-existing, unrelated documents before any write happened, not
because anything in the design phase flagged it. **Frozen: this
Repository uses `users/{uid}/generatedNotifications`, not
`notifications`** — verified free of any existing use anywhere in the
codebase, `firestore.rules`, or `firestore.indexes.json` before
adopting it, the same "check the claim against real code" discipline
already applied to the localization claim in 5.6A.

**Firestore structure, frozen**: `users/{uid}/generatedNotifications/{notificationId}`.
**`notificationId` is the same as the originating `eventId`, not a
freshly generated ID** — this is a deliberate, deterministic choice
(not explicitly stated in the original sketch, added here for the same
idempotency reasons as every other ID in this system): since 5.6B
already guarantees one event produces at most one notification,
reusing `eventId` as the document ID makes `save()` naturally
idempotent — calling it twice for the same event is a safe no-op,
exactly like `create_daily_snapshot()` and `persist_events()` before it,
rather than requiring a separate uniqueness check.

```
users/{uid}/generatedNotifications/{notificationId}   (== eventId)
├── eventId
├── eventCode
├── priority
├── frequency
├── timing
├── interruptionLevel
├── templateId
├── title
├── body
├── cta
├── payload
├── deepLink
├── status          -- Created | Delivered | Read | Dismissed | Expired
├── createdAt
├── deliveredAt
├── readAt
└── dismissedAt
```

**Acceptance test, frozen**: *if Delivery changes from Firebase Cloud
Messaging to another provider tomorrow, does the Notification
Repository remain unchanged?* If yes, storage and transport are
correctly separated — the same test already applied to every other
storage-vs-transport boundary in this project.

**`Notification Center`, the other stale placeholder found in this
slot, reframed rather than deleted**: it isn't a phase of its own — it's
simply the Repository's `list`/`listUnread` operations, read by
whichever UI surface (Flutter, Step 13) displays them. No separate
design needed beyond what's already frozen above; noted here so the
concept isn't lost, just correctly placed.

### Notification Repository — Implementation — FROZEN

Implemented in `services/notification_repository.py`:
`save`/`get`/`list_notifications`/`list_unread`/`list_recent`/
`mark_read`/`mark_dismissed`, exactly matching the five frozen rules —
`save()` is idempotent by construction (`notificationId == eventId`),
`mark_read`/`mark_dismissed` touch only `status` and their own
timestamp field, and no function ever deletes a document.

**A real, serious collision found during real-account verification,
before any test data was written, not caught at design time.** The
originally-planned collection name, `users/{uid}/notifications`, is
already in active production use by the existing bank-SMS
pending-transaction flow — a real-account check found 4 pre-existing,
unrelated documents there before this Repository ever wrote anything.
Fixed by renaming the collection to `users/{uid}/generatedNotifications`,
verified free of any existing use across the whole codebase,
`firestore.rules`, and `firestore.indexes.json` before adopting it. This
is the same "check the claim against real code" discipline already
applied to the 5.6A localization claim — except this time the thing
being checked was a collection name, and getting it wrong would have
meant silently corrupting a real, already-in-production feature rather
than just an inaccurate spec sentence.

All 15 unit test scenarios pass (`tests/test_notification_repository.py`
— a fake Firestore supporting `order_by`/`limit`/`stream`, with a fake
`SERVER_TIMESTAMP` resolved to a monotonic counter so ordering is
testable without real time): idempotent `save()`, correct list ordering,
`list_unread` correctly excluding Read/Dismissed notifications,
`mark_read`/`mark_dismissed` touching only their own fields and never
deleting the document, both being idempotent themselves, and `list_recent`
respecting its limit. Verified end-to-end against the real account too —
generate → save → idempotent re-save → mark_read → list_unread/
list_recent, all against real Firestore — with the pre-existing bank-SMS
`notifications` collection explicitly confirmed untouched before and
after, and the test document cleaned up afterward.

### Phase 5.8 — Delivery Philosophy (frozen before any code)

**One principle, frozen: creation and delivery sit on two different
idempotency boundaries, and they must never be conflated.** `Event →
Notification` (5.6B) happens exactly once — the Generator's determinism
and the Repository's `notificationId == eventId` guarantee this
structurally. `Notification → Device` is the opposite: it *may* need to
happen more than once internally (a push provider timeout, a transient
network failure) before it succeeds, and every one of those retries
must still resolve to the *same* notification, never a regenerated or
duplicated one. This is the same shape already frozen for Snapshot
Builder: if the Firestore write fails, the retry is the *same* write
retried, never a freshly recomputed snapshot. Delivery inherits that
exact discipline, one layer further downstream.

**The philosophy question this phase must answer before any code,
mirroring the question that opened Era 2 ("what is a Daily Snapshot"):
what does it mean for a notification to be *delivered*?** Not "sent,"
not "shown," not "opened" — those are genuinely different claims, and
conflating them would make the already-frozen `Delivered` status (5.7)
mean something no one actually decided.

**The candidate breakdown, and which of it actually matters to
BachatBot, decided here rather than left open:**

```
Created  ->  Handed to delivery service  ->  Accepted  ->
Displayed on device  ->  Opened
```

**Decision, frozen: `Delivered` means "successfully handed to the push
provider (FCM), confirmed accepted — not merely attempted."** Not
"displayed on device": that's a claim push infrastructure generally
cannot reliably confirm at all (FCM confirms hand-off, not that the OS
actually rendered the notification on a screen that may be off, in Do
Not Disturb, or offline) — freezing `Delivered` to mean "displayed"
would be a status this system could never honestly set. "Handed to
delivery service" and "Accepted" collapse into one moment for
BachatBot's purposes — the same reasoning that already removed
`Queued`/`Sending` from the Lifecycle (5.7) as delivery-implementation
detail, not persisted state. "Opened" needs no new state at all — it's
the same real-world signal `Read` (5.7) already captures; inventing a
separate `Opened` status would just be two names for one fact, the same
mistake already caught and fixed twice before in this project
(the `*_STARTED`/`*_EXTENDED` merge, `NEW_RECOMMENDATION_GENERATED`).

**What this means for Delivery's implementation, once it's built**:
Delivery may retry its own hand-off to FCM as many times as needed
(its own internal retry loop, its own concern) — but it only ever
updates the Repository's `deliveredAt`/`status` fields once, the moment
that hand-off is actually confirmed, never speculatively before, never
more than once after. Delivery consumes an already-created notification
exactly as-is; it never changes or reinterprets the fields the
Generator and Repository already froze.

### Phase 5.8 — Implementation Scope, decided before code

**Checked before writing anything, the same discipline as every prior
step**: this codebase has **no FCM infrastructure at all** — no
device-token field anywhere in the user schema, no token-registration
endpoint, and the Flutter app has no `firebase_messaging` dependency or
client-side registration. `firebase-admin==6.5.0` (already a pinned
dependency, used today for Firestore) fully supports
`firebase_admin.messaging` with no additional setup — the server-side
send is genuinely buildable today; there is simply nothing real to send
*to* yet.

**Decision: build the real `send()` function and a device-token
registration endpoint (backend only); Flutter-side FCM registration is
named as the explicit remaining prerequisite, not built here.** Building
the Flutter half would be the first time this entire multi-hundred-turn
design/implementation arc touches the frontend — a genuinely different
scope of work than everything before it, and out of place to take on
silently inside a "finish the backend Delivery layer" step. Without a
real device token, `deliver_notification()` correctly has nothing to
deliver to — that's not a flaw in this step, it's an honest reflection
of where the project actually stands.

### Delivery — Implementation — FROZEN

Implemented in `services/delivery_service.py`:
`save_device_token(db, uid, token)` and `deliver_notification(db, uid,
notification, max_retries=3)`, plus `notification_repository.py`'s new
`mark_delivered()` (the only function that ever sets `status:
Delivered`, exactly once, only on confirmed FCM acceptance). A new
route, `POST /notifications/device-token`
(`routes/notifications.py`, registered in `main.py`), lets a client
register its token — the backend half of the named prerequisite.

**The idempotency-boundary principle holds exactly as designed**:
`deliver_notification()` retries its own `messaging.send()` call up to
`max_retries` times on failure, but every retry targets the *same*
notification document — never regenerating it, never creating a second
one. An already-`Delivered`/`Read`/`Dismissed` notification short-
circuits immediately, without attempting to send again.

All 9 unit test scenarios pass (`tests/test_delivery_service.py` — a
fake Firestore, `messaging.send` swapped for a test function rather
than mocked at the network layer): no-token no-op, successful send
marking `Delivered` exactly once, exhausting all retries leaving the
notification untouched and still retryable later, succeeding on a
later attempt after prior failures, and an already-delivered
notification never being re-sent.

**Verified against real FCM, not just a mock** — this is the one place
in the whole Notification Engine where a real external service could
actually be exercised without needing a real device: a real token
string was registered on the real test account, and `deliver_notification()`
was pointed at real `firebase_admin.messaging.send()`. FCM correctly
rejected the fake token ("The registration token is not a valid FCM
registration token"), and the retry/error-handling logic correctly
caught this real rejection, retried the configured number of times, and
left the notification as `Created` rather than crashing or falsely
marking it delivered. The test token and notification were removed from
the real account afterward.

**Confirms the Phase 5.8 scoping decision was correct**: the backend
half (`send()`, token storage, the registration endpoint) is real,
tested against real infrastructure, and complete on its own terms.
Flutter-side FCM registration remains the one named, external
prerequisite before an actual device can ever receive a push — not
something this step could have closed on its own.

### Phase 5.9 — Review & Freeze

**Milestone-5-style review performed against the real code, not just
the spec** — six audits, two real findings:

- **Ownership, Idempotency, Repository, Matrix (code) audits: pass.**
  Every field has exactly one write-path; `save`/`mark_delivered`/
  `mark_read`/`mark_dismissed` are all confirmed no-ops on repeat calls;
  no duplicate storage; all 17 real event codes (15 Diff Matrix + 2
  reused Financial Events) have consistent Priority/Frequency/Timing
  rows, and Template's apparent gap on `MILESTONE_UNLOCKED` is a false
  positive — it's intentionally handled by a separate per-milestone-code
  lookup, not the flat table.
- **Integration Audit: fails.** `scheduler_service.py` had zero
  references to the Notification Engine at all (confirmed by grep, not
  assumed) — events were generated and persisted, and nothing turned
  them into notifications. The real cause: **the 5.2 Eligibility
  waterfall was only ever designed, never implemented as code.**
  Without it there was nothing legitimate to wire the pipeline through.
- **Lifecycle Audit: incomplete.** `Created`/`Delivered`/`Read`/
  `Dismissed` all have real code paths; `Expired` has none — no
  `mark_expired()`, no staleness check anywhere.
- **Re-confirmed, not new**: `NEW_BEST_STREAK` still has orphaned rows
  in the Eligibility (5.2A) and Priority (5.3) matrices with no Diff
  Matrix producer — already named during 5.6B's own audit, still open,
  correctly excluded from the real code.

### Eligibility Waterfall — Implementation, frozen before code

**Scope, decided honestly rather than over-built**: Gates 6 (Timing)
and 7 (Interruption Level) never reject — they only inform *when*/*how*
an already-eligible notification is delivered (5.2's own frozen
framing), so they contribute no gating logic here; their values are
already looked up inside the Generator. Gate 2 (Context) has no real
signal to check against — this codebase has no app-presence/session
tracking anywhere — so it is implemented as a deliberate, named
pass-through today, not a fabricated check. The gates that actually
reject are **1/3 combined (Justification + Notification-Eligible, via
the Eligibility Matrix's `ALWAYS`/`CONDITIONAL`/`NEVER` type), 4
(Already Informed), and 5 (Frequency)**.

**Several `CONDITIONAL` rows, checked against what their own Diff Rule
already guarantees, turned out to need no extra logic at all — the
same reconciliation already found once for `PRIMARY_RECOMMENDATION_CHANGED`
in 5.6B, found again here for a second event**: `HEALTH_IMPROVED`'s
condition ("not amber-to-amber") is already structurally guaranteed by
its own Diff Rule (`_better(a, b)` only ever fires on a genuine
downgrade in severity — an unchanged status can never satisfy it), so
it's reclassified `ALWAYS`, needing no runtime check. The genuinely
`CONDITIONAL` events are the ones whose Diff Rule fires on *every*
occurrence regardless of magnitude: `LOGGING_STREAK_EXTENDED`,
`HEALTHY_STREAK_EXTENDED`, `SAVING_STREAK_EXTENDED` (checkpoint-gated —
eligible only when the new streak length lands on `{7, 14, 30, 60, 90,
180, 365}`, first cut, tunable) and `LOGGING_STREAK_BROKEN` (eligible
only when the broken streak was at least 3 days long — breaking a
1-2 day streak isn't news, per 5.2A's own original reasoning).

**Gate 5 (Frequency), implemented against the Repository's own
history** — for each event code, its Frequency policy (5.4A) is
checked against the most recent existing notification of that same
`eventCode` for this user: `ONCE` passes only if none has ever been
created; `DAILY`/`WEEKLY`/`MONTHLY` pass only if the most recent one is
older than 1/7/30 days respectively (a calendar-naive first cut for
`MONTHLY`, named as tunable); `UNTIL_RESOLVED` always passes here — its
real escalating cadence (30min/4hr/next-morning/stop) is a Delivery/
scheduling-layer concern beyond what a single eligibility check can
express, simplified rather than half-built.

**Gate 4 (Already Informed)** is checked directly against the
Repository: if a notification already exists for this exact `eventId`,
it's not eligible again — the same fact this Repository's own
`save()` idempotency already guarantees downstream, checked here too
for an explicit, named reason rather than relying on a side effect.

### Eligibility Waterfall — Implementation — FROZEN

**Built**: `services/eligibility_engine.py` (`check_eligibility()`,
`process_event()`), wired into `scheduler_service.process_day()` right
after `persist_events()` — every persisted Event is now offered to the
waterfall, isolated per-event inside its own try/except so a
notification-pipeline failure can never fail the snapshot/event
pipeline it rides alongside. `notificationsCreated` was threaded
through `process_day()` → `process_user()` → `run_daily_snapshot_job()`'s
aggregation and logging, the same shape every other per-run stat
already followed. `notification_repository.py` gained `mark_expired()`
and `expire_stale_notifications()` (time-based staleness, 14-day
default — named honestly as a limitation, since re-checking whether
the underlying condition is still true would mean this infrastructure
layer reaching back into domain engines, which it must never do).

**Unit tests, all passing**: `test_eligibility_engine.py` (12
scenarios — every `ALWAYS` pass, `CONDITIONAL` pass/fail at and off the
streak checkpoints and the minimum mourned-streak length, an unknown
event code's named rejection, Already-Informed rejection, a `ONCE`
policy's second-event rejection, and `process_event()`'s full
orchestration both ways); `test_notification_repository.py` extended
with `mark_delivered`/`mark_expired`/`expire_stale_notifications`
coverage (9 new scenarios, including one that deliberately backdates a
real `datetime` past the cutoff to exercise the actual staleness
comparison, not just the happy path); `test_scheduler_service.py`
extended with two scenarios that exercise `process_day()`'s actual
notification loop directly (both snapshots pre-seeded as already
existing so the five-engine gather step is bypassed and only the
diff → eligibility wiring is under test) — confirming
`notificationsCreated` counts exactly the events eligibility actually
accepted, and that one event's pipeline exception never fails the day
or blocks the next event from being attempted. Full suite: 14 test
files, zero regressions.

**Real-account verification, against `BvjbjFOGHQNmI1xcRm5xowKPpoB3`,
cleaned up afterward**: a fresh `HEALTH_WORSENED` event became a real,
persisted notification; re-processing the identical event was rejected
as Already Informed; a same-day second `HEALTH_WORSENED` (a `DAILY`
policy) was rejected by Frequency; an unknown event code was rejected
with a named reason and persisted nothing; `mark_expired()` and
`expire_stale_notifications()` both behaved correctly against the real
document. Every test document was deleted afterward.

**Closes the Phase 5.9 Integration Audit finding.** Re-confirmed by
grep: `scheduler_service.py` now reaches the Notification Engine
(`eligibility_engine.process_event`, one call site) — no longer zero
references. The Lifecycle Audit's `Expired` gap is also closed
(`mark_expired`/`expire_stale_notifications` now exist and are tested).
The `NEW_BEST_STREAK` orphaned-matrix-rows finding remains open,
unchanged — a pre-existing, already-named gap, not something this pass
introduced or was scoped to fix.

### Duolingo-style triggers, reframed for a finance app without becoming manipulative

The psychological trigger *categories* Duolingo uses (come-back,
streak-at-risk, achievement, milestone, fear-of-loss, celebration,
curiosity) are legitimate engagement patterns — the difference between
using them well and manipulatively is **Rule 1 (never invent
information) plus Rule 4 (always explainable)**. Concretely:

- Not "Spend less" → **"You've protected your healthy streak for 11
  days. One more day completes your best week this month."** (a real,
  traceable fact — the streak — framed as a near-term milestone.)
- Not "Budget exceeded" → **"Food budget is exhausted. Spending in Food
  today would come from your Savings Pool."** (factual, consequence
  stated plainly, no invented urgency.)

Every one of these must still trace back to a real engine output — the
line between "engaging" and "manipulative" is whether the notification
is describing something true (Rule 1) that the user could verify by
asking "why?" (Rule 4), not whether it uses an emotional frame at all.

**Not started yet.** This section — the Phase 4.5 Behavior Engine
insertion and what it owns (vs. what stays Notification's job), and
Phase 5's full 5.0-5.9 breakdown (philosophy, seven notification
families, the eligibility waterfall, priority tiers, per-family
frequency rules, timing rules, the Generator's output shape, the
lifecycle states, the Notification Center concept, and the reframed
Duolingo trigger categories) — is the roadmap and philosophy freeze
before any Phase 4.5 or Phase 5 code. Detailed design of each sub-phase
(starting with 4.5, then 5.0) follows on separate confirmation, the same
one-piece-at-a-time discipline every phase since 2.1 has followed.

---

## Phase 4.5 — Behavior Engine (Design Only)

**The one question this engine answers**: "How is the user's financial
*behavior* evolving over time?" Not "are they financially healthy" —
Health already answers that, at a single point in time. Behavior is
explicitly about the *shape* of a pattern across time (streaks,
consistency, recovery speed), never a snapshot.

```
4.5.0  Philosophy
4.5.1  Logging Behavior
4.5.2  Spending Behavior
4.5.3  Saving Behavior
4.5.4  Recovery Behavior
4.5.5  Milestones
4.5.6  Behavior Summary
4.5.7  Review & Freeze
```

### 4.5.0 — Philosophy (five frozen rules)

1. **Behavior never changes money.** Read-only, same as every engine
   since Health.
2. **Behavior never predicts money.** That's Projected Savings' job
   (Phase 2.7) — Behavior observes what already happened, it doesn't
   forecast what will.
3. **Behavior observes habits, not financial status.** "12 healthy
   days in a row" is a habit fact; "Overall Health is Green" is a status
   fact (Health's job) — related, never the same thing.
4. **Behavior can celebrate success and detect consistency** — this is
   the one engine in the whole pipeline explicitly permitted a positive,
   not just a risk-detecting, framing (mirroring `KEEP_CURRENT_HABITS`
   and Positive Reinforcement's first-class status back in Phase 4.0).
5. **Behavior can only use outputs from previous engines or historical
   events** — never raw transactions, never a recomputation of a metric
   Phase 1/2/3/4 already owns.

### A necessary, honest departure from "computed on demand" — named explicitly, not glossed over

**Every engine through Phase 4 is stateless: computed fresh from current
data on every call, nothing persisted, nothing to go stale.** Behavior
is the first one that cannot be, and this needs to be said plainly
rather than discovered as a surprise during implementation: **detecting
a streak, a "just broke," or a "just started" requires knowing what was
true last time** — a pure function of *today's* data alone cannot tell
you whether today is the *12th* consecutive healthy day or the *1st*.
This is not a violation of the architecture's core discipline; it's
*why Behavior Engine exists as its own phase* — it is the one component
whose entire job is remembering history, so no other engine (Financial,
Metrics, Health, Recommendation) ever needs to become stateful just to
answer "how long has this been true." State (streak counters, last-known
values, last-notified markers) has exactly one legitimate home: here.

## Phase 4.5A — Event Architecture (checkpoint before coding Behavior Engine)

**Not another engine — infrastructure that serves Behavior and
Notification both.** Per the closing principle of this checkpoint (see
end of this section): an engine exists when a layer answers a
fundamentally different *question* (money → metrics → health →
recommendation → behavior). Events are not a new question — they're the
mechanism Behavior and Notification both need to communicate through,
and freezing that mechanism now avoids re-deriving it inconsistently
inside each.

### What is an Event?

```
{
  "eventId": "...",
  "eventType": "HEALTHY_STREAK_BROKEN",
  "sourceEngine": "behavior",       // financial | health | recommendation | behavior — never metrics, never notification (see Ownership below)
  "sourceObject": { "category": null, "streakLength": 12 },
  "createdAt": "...",
  "priority": "medium",             // the emitting engine's own hint — Phase 5.3's own priority waterfall still makes the final call, this is not binding
  "payload": { ... },               // event-specific context (streak length, category name, milestone code, etc.)
  "consumedBy": [],                 // append-only log: {consumer, consumedAt} — reading never deletes or hides an event from another consumer
  "expiresAt": "..."
}
```

### Are events persistent? Yes — all of them, uniformly

**Decision, frozen: every event is persisted the moment it's detected,
with no ephemeral tier.** The scenario that settles this: if
`RECOVERY_COMPLETED` happens today and Notification isn't opened until
tomorrow, the event must still be there tomorrow — Notification, Chat,
and the UI's Notification Center (Phase 5.8) all read the *same*
persisted event independently and asynchronously, not a live stream
that only whoever's listening right now receives. An event only exists
because it's already a real, detected fact (Rule 1 — never invent
information) — treating a real fact as ephemeral risks losing it before
anything downstream saw it, exactly the failure mode this checkpoint
exists to prevent.

### Can duplicate events exist? No — "one fact = one event," frozen — corrected mechanism

**Revised from the previous draft of this section.** The original
resolution made Behavior Engine "the single centralized detector for
all cross-engine transitions" — on review, that gives Behavior Engine a
responsibility that isn't actually its own: when Food becomes exhausted,
Category Health changes, Overall Health changes, and the Recommendation
changes — Behavior Engine didn't *decide* any of those, it would only be
*noticing* them, which is a fundamentally different kind of work than
"how long has this healthy streak been running," the actual question
Behavior Engine exists to answer.

**Decision, frozen instead: two separate concepts, not one.**

1. **Domain engines** — Financial, Metrics, Health, Recommendation,
   Behavior — each still only computes its own output, answering its
   own one question, exactly as already frozen. Behavior Engine is a
   **peer** in this list, not a special detector sitting above the
   others — it computes streaks/milestones/habits, nothing more.
2. **Event Infrastructure** (Daily Snapshot + Diff Generator) — a small,
   generic layer that takes yesterday's full snapshot and today's full
   snapshot and reports the differences as Events. **No engine —
   including Behavior — has to remember yesterday itself; only the
   snapshot system does.**

```
Financial → Metrics → Health → Recommendation → Behavior
                                    │
                                    ▼
                          Daily Snapshot (infrastructure)
                                    │
                                    ▼
                          Diff Generator (infrastructure)
                                    │
                                    ▼
                                 Events
                                    │
                                    ▼
                        Notification / Chat / UI / Analytics
```

**Daily Snapshot — field shape, frozen.** One document per day,
capturing that day's output from *every* domain engine, including
Behavior's own current counters:

```
users/{uid}/dailySnapshots/{date}
├── financialSummaryVersion   (FINANCIAL_ENGINE_VERSION at capture time)
├── metricsVersion            (METRICS_ENGINE_VERSION at capture time)
├── healthVersion             (HEALTH_ENGINE_VERSION at capture time)
├── recommendationVersion     (RECOMMENDATION_ENGINE_VERSION at capture time)
├── behaviorVersion           (BEHAVIOR_ENGINE_VERSION at capture time)
│
├── financialSummary   (excerpt: income, totalSpent, remainingBudget, savingsPool)
├── metrics            (excerpt: spendingPace.status, recommendedDailySpend.value,
│                        recoveryPlan.recoveryPossible if a Recovery Plan exists that
│                        day, else absent — see 4.5.4's RECOVERY_BECAME_IMPOSSIBLE)
├── health             (overallHealth.status, categoryHealth[cat].status per category)
├── recommendations    (primaryRecommendation.code)
├── behavior           (behaviorState's current counters, as of that day)
│
├── snapshotDate       (the calendar day this snapshot represents)
└── generatedAt        (the timestamp the job actually ran — not always
                         the same day; see rebuild policy below)
```

**Why the per-engine `*Version` fields, frozen alongside the shape, not
added later:** every engine already carries its own version constant
(`FINANCIAL_ENGINE_VERSION`, `METRICS_ENGINE_VERSION`,
`HEALTH_ENGINE_VERSION`, `RECOMMENDATION_ENGINE_VERSION`, and the
forthcoming `BEHAVIOR_ENGINE_VERSION`) — a snapshot is a photograph of
*that engine's* output, and a photograph without a timestamp on the
camera settings can't later be told apart from a photograph taken with
a different lens. Six months from now, "why does this snapshot say
`healthy` when the Health rules have since changed" is answered by
comparing `healthVersion` to the current constant, not by guessing.

**`snapshotDate` vs. `generatedAt`, frozen as distinct fields on
purpose:** `snapshotDate` is the calendar day the snapshot is *about*;
`generatedAt` is when the job actually produced it. These are the same
moment in the normal case (the nightly job runs, captures "today"), but
they diverge for a manually rebuilt or backfilled snapshot (rebuild
policy below) — keeping them as two fields, rather than one timestamp
serving both purposes, is what makes that distinction visible in the
data itself rather than left to be inferred.

Written once daily by the same scheduled job already named for Phase
4.5.2's healthy-day check — that requirement doesn't change, it's just
now framed as "capture everything," not "capture Health only."
**Owned by the Snapshot infrastructure, not by any single domain
engine** — a deliberate difference from every other collection in this
spec, which each have exactly one engine owner.

**Diff Generator** — a generic function, `diff(yesterday, today) →
events`, driven by a frozen **Diff Rules table**. This table *is* the
source of truth for what counts as an event — not the idea of diffing,
the literal rows below. Adding an event type later means adding a row
here first, the same discipline the Recommendation Matrix and Risk
Flags severity table already enforce elsewhere in this spec (first cut,
same tuning caveat every threshold table in this spec carries — the
*existence* of each row is frozen, the exact trigger condition can be
retuned under `DIFF_VERSION`, below):

| Snapshot field | Transition | Event |
|---|---|---|
| `health.overallHealth.status` | → `red` | `HEALTH_WORSENED` |
| `health.overallHealth.status` | `red`/`amber` → `green` | `HEALTH_IMPROVED` |
| `health.categoryHealth[cat].status` | → `red` | `CATEGORY_BECAME_EXHAUSTED` |
| `recommendation.primaryRecommendation.code` | any change | `PRIMARY_RECOMMENDATION_CHANGED` |
| `behavior.spending.currentHealthyStreak` | `N` → `N+1` | `HEALTHY_STREAK_EXTENDED` |
| `behavior.spending.currentHealthyStreak` | `N>0` → `0` | `HEALTHY_STREAK_BROKEN` |
| `behavior.logging.currentStreak` | `N` → `N+1` | `LOGGING_STREAK_EXTENDED` |
| `behavior.logging.currentStreak` | `N>0` → `0` | `LOGGING_STREAK_BROKEN` |
| `metrics.recoveryPlan.recoveryPossible` | `true` → `false` | `RECOVERY_BECAME_IMPOSSIBLE` (Health Event — reports what's true *right now*, judges nothing) |
| `behavior.recovery.totalResolved` | `N` → `N+1` | `RECOVERY_COMPLETED` (Behavior Event — a retrospective classification Behavior Engine already made before this field changed, not something the Diff Generator determines itself) |
| `behavior.recovery.totalFailed` | `N` → `N+1` | `RECOVERY_FAILED` (same — retrospective, already classified) |
| Behavior's own milestone check | `false` → `true` | `MILESTONE_UNLOCKED` |

**Corrected from the original draft, found while designing 4.5.4**: the
original two rows above conflated a live signal with a retrospective
one. `recoveryPossible` flipping false is true *the moment it happens*
— a Health-layer fact, not yet a judgment about the whole recovery
attempt, so it maps to the already-named Health Event
`RECOVERY_BECAME_IMPOSSIBLE`. Whether the *attempt as a whole* ends up
`RECOVERY_COMPLETED` or `RECOVERY_FAILED` can only be known once the
attempt closes (Recovery Plan disappears) and depends on the entire
history of that attempt (was it ever impossible at any point, not just
now) — a fact only Behavior Engine can hold, because a snapshot only
ever answers "what is true now," never "what happened over time." By
the time `totalResolved`/`totalFailed` change, Behavior Engine has
already done the classifying; the Diff Generator is just reporting a
counter changed, the same mechanical role it plays for every other row.

**This is the same mechanism for every row — `HEALTHY_STREAK_EXTENDED`
is detected exactly the same way `HEALTH_WORSENED` is**, a plain
field-level diff between two snapshots. Behavior Engine still *computes*
`currentHealthyStreak`'s value each day (that computation is its own
domain work), but it no longer decides "did this change enough to be an
event" — the Diff Generator does, uniformly, for every field from every
engine.

**"One fact = one event" now holds for a cleaner reason than before**:
there is exactly one Diff Generator, run once per snapshot pair, so
"Food exhausted" produces exactly one `CATEGORY_BECAME_EXHAUSTED` event
— not because one engine was designated the sole detector, but because
diffing itself only happens once, generically, over the whole snapshot.
**"Once" is a scheduling fact, not a correctness guarantee** — see
idempotency below for what happens when it accidentally runs twice.

**The scalability case this resolves**: adding a future Investment
Engine or Credit Score Engine means adding one more field to the Daily
Snapshot and a few more rows to the Diff Rules table — **Behavior
Engine itself needs zero changes**, because it was never the thing
watching other engines in the first place.

### Event idempotency — frozen

**Question this closes**: snapshot generated → diff runs → server
crashes before the events are marked consumed → diff runs again against
the same snapshot pair. Does the user get the same `HEALTHY_STREAK_EXTENDED`
event twice?

**Decision, frozen: no. The Diff Generator must be idempotent — running
it any number of times against the same pair of snapshot dates produces
the same event set, never duplicates.** Mechanism: an event's identity
is derived deterministically from its cause, not assigned freshly on
each run — `eventId` is a deterministic key built from
`(uid, snapshotDate, diffRuleId)` (e.g. a hash of those three), not a
random ID. Writing an event becomes an *upsert* keyed on that
deterministic ID, not an `append`/`insert`. Re-running the same diff
overwrites the same document with the same content; it never produces a
second row. This is the same reasoning `TRANSACTION_CONFIRMED` already
relies on elsewhere in this spec (an operation safe to retry after a
crash, because retrying it lands on the same state, not a new one) —
extended here to the Diff Generator specifically because it is the one
piece of new infrastructure in this checkpoint that runs unattended, on
a schedule, with no user present to notice or retry a failure by hand.

### Event lifecycle

```
Detected (by the Diff Generator) → Generated → Stored →
Notification reads → Chat reads → UI reads → Archived
```

Simple and linear. "Stored" is the persistence decision above; the three
"reads" are independent, non-destructive (`consumedBy` grows, nothing is
removed); "Archived" is what `expiresAt` transitions an event into —
kept for historical debugging (being able to reconstruct *why* the
current state looks the way it does), never deleted outright.

### Event storage — a neutral collection, not owned by any single domain engine

**Decision, frozen: `users/{uid}/events/{eventId}`, owned by the Event
Infrastructure (Snapshot + Diff), not by Behavior Engine** — since an
event can now describe a change in *any* domain engine's output, not
only Behavior's own. `sourceEngine` on the event object (frozen shape,
above) still names whose *field* changed, for traceability — it just no
longer implies that engine, or Behavior, did the detecting.

### Snapshot timing — Daily Snapshot vs. Live Snapshot, frozen

**Question this closes**: when does a snapshot get created — midnight
only, after every recompute, after any state change, on demand?

**Decision, frozen: two different things, not one, because they answer
two different questions:**

- **Daily Snapshot** — exactly one immutable document per calendar day,
  written once by the nightly scheduled job (the shape frozen above).
  This is the only snapshot that exists in storage, the only one the
  Diff Generator ever reads, and the only one streaks/trends/history are
  computed from. It answers "what did the system say yesterday, so we
  can compare it to today."
- **Live Snapshot** — not a stored thing at all, just a name for what
  every domain engine already does on every request: compute-on-demand,
  reused from Phase 0 onward (`get_financial_summary`, `get_metrics`,
  `compute_overall_health`, `compute_recommendations`, all already
  stateless and callable "right now"). The UI's current screen is
  always a Live Snapshot — freshly computed, never persisted, never
  diffed against anything.

```
Current screen         →  Live Snapshot   (computed on demand, never stored)
Yesterday vs. Today     →  Daily Snapshot  (one per day, stored, immutable)
```

**Why this distinction matters enough to freeze explicitly**: without
it, it would be tempting to have the UI read from the stored Daily
Snapshot for convenience — which would silently make the UI show
stale, once-a-day data instead of the live numbers every earlier phase
worked to keep instantly accurate. Freezing "UI always reads Live, Diff
Generator always reads Daily" prevents that mixup from ever being a live
question during implementation.

### Snapshot and Diff versioning — frozen

**Following the same discipline already frozen for every engine
(`FINANCIAL_ENGINE_VERSION`, `METRICS_ENGINE_VERSION`,
`HEALTH_ENGINE_VERSION`, `RECOMMENDATION_ENGINE_VERSION`)**, the
infrastructure layer gets its own two version constants:

- **`SNAPSHOT_VERSION`** — versions the *shape* of the Daily Snapshot
  document itself (which fields it captures, per the frozen shape
  above). Bumped only when the snapshot's own structure changes, not
  when an underlying engine's values change.
- **`DIFF_VERSION`** — versions the Diff Rules table (which rows exist,
  what transition each row watches for). Bumped when a rule is added,
  removed, or its trigger condition is retuned.

**Why two, not one**: the snapshot's shape and the rules that read it
can change independently — a new engine field can be added to the
snapshot without any Diff Rule changing, and a Diff Rule's threshold can
be retuned without the snapshot shape changing at all. Collapsing them
into one version number would make it impossible to tell, from an old
event, which of the two actually changed. Every stored Event and every
stored Daily Snapshot document is stamped with the version(s) active
when it was produced — the same "don't guess, read it off the record"
principle the per-engine `*Version` fields already serve.

### Rebuild policy — snapshots are historical record, not source of truth for money, frozen

**Question this closes**: if every Daily Snapshot document were deleted,
could they all be rebuilt exactly as they were?

**Decision, frozen: no — and that answer is the point, not a gap to
close.** Snapshots are **reproducible historical records derived from
the underlying data available at the time**, not the source of truth
for money (that remains `financialSummary`, per Section 8's Ground
Truth Principle, unchanged). But they *are* the historical source of
truth for **how the system evaluated the user's financial state on a
given day** — and that's a meaningfully different claim from "just a
cache, rebuild anytime."

**Why rebuilding isn't safe to treat as free**: formulas evolve.
`HEALTH_ENGINE_VERSION` will eventually bump past `1.0.0`; when it does,
recomputing "was July 19th healthy" with the *new* rules could produce a
different answer than what the user actually saw and reacted to on July
19th. A rebuilt snapshot under new formulas is not the same historical
fact as the original — it's a different question wearing the same
date. This is exactly why `*Version` fields are stamped onto every
snapshot: a snapshot is only ever safe to regenerate byte-for-byte
identically if its stamped versions match the engines' current
versions; if they don't match, "rebuilding" is actually re-evaluating
history under today's rules, and must never silently overwrite the
original document — at most it produces a new, separately labeled
record, never a replacement.

**Practical consequence for the not-yet-built scheduler**: snapshots are
therefore treated operationally as append-only and are never deleted or
regenerated in place, the same permanence Financial Engine already
guarantees for `financialSummary` history and Behavior Engine guarantees
for `behaviorHistory`.

### Behavior State Model — split into current state vs. history

**The `behaviorState`/`behaviorHistory` split from last session still
holds** — this correction only changes *where events and snapshots
live* (their own neutral collections, above), not the state-vs-history
separation itself:

```
behaviorState                          (mutable — current values only,
                                         owned by Behavior Engine)
├── logging:  { currentStreak, bestStreak, streakStartedOn, lastLoggedDate }
├── spending: { currentHealthyStreak, bestHealthyStreak,
│               currentOverspendingStreak, lastHealthyDate,
│               lastEvaluatedDate }
├── saving:   { currentProtectionStreak, bestProtectionStreak,
│               lastMonthKeyEvaluated }
└── recovery: { currentStreak, bestStreak, totalAttempts,
                totalResolved, totalFailed, openRecoveryStartedOn,
                openRecoveryEverImpossible }

behaviorHistory                        (append-only, owned by Behavior
                                         Engine — narrowed to records
                                         that aren't simple field diffs)
├── milestones[]          { code, type, threshold, unlockedAt }
└── recoveryAttempts[]    { startedOn, resolvedOn, outcome }
                          (the structured log successRate/averageRecoveryDays
                           are computed from — richer than a single Event)
```

**Narrowed from the previous draft**: `dailySnapshots[]` and `events[]`
moved out of `behaviorHistory` entirely, into the new neutral
`dailySnapshots`/`events` collections above — they were never uniquely
Behavior's data once the Diff Generator became generic across all
engines. `streakTransitions[]` was removed as a separate array too: a
streak extending or breaking *is* an Event now (`HEALTHY_STREAK_EXTENDED`/
`_BROKEN`, produced by the Diff Generator), so recording it a second
time in `behaviorHistory` would just be the same fact in two places.
What's left in `behaviorHistory` is only the data that genuinely isn't a
simple before/after field comparison — milestone unlock records, and
the recovery-attempt log Recovery Behavior's own success-rate/average-
time calculations need.

**Both `behaviorState` and `behaviorHistory` are written only by
Behavior Engine; `dailySnapshots` and `events` are written only by the
Event Infrastructure. Everything downstream (Notification, Chat, UI)
reads, never writes — the same single-owner discipline every collection
in this spec has followed since Section 8.**

**Firestore paths — frozen (Step 1 schema, no logic):**

| Collection | Path | Cardinality |
|---|---|---|
| `behaviorState` | `users/{uid}/behaviorState/current` | one document per user, overwritten in place |
| `behaviorHistory` | `users/{uid}/behaviorHistory/current` | one document per user; its arrays (`milestones[]`, `recoveryAttempts[]`) grow by append, the document itself is never replaced |
| `dailySnapshots` | `users/{uid}/dailySnapshots/{snapshotDate}` | one document per calendar day, immutable once written |
| `events` | `users/{uid}/events/{eventId}` | one document per detected transition, `eventId` deterministic (idempotency, above) |

`behaviorState`/`behaviorHistory` use a fixed `current` document ID
rather than a generated one — there is exactly one of each per user, the
same reasoning `financialSummary` documents key off `month_key` because
there is exactly one per user per month.

### Closing principle for this checkpoint — not everything needs its own engine

An engine is warranted when a layer answers a *fundamentally different
question* — money → metrics → health → recommendation → behavior each
do. Events, daily snapshots, schedulers, and storage models are
**infrastructure that serves multiple engines**, not new questions of
their own — treating them as engines would be exactly the kind of
unnecessary layer this spec has avoided everywhere else. Phase 4.5A is
explicitly *not* "Phase 4.6" for this reason: it's a checkpoint that
defines shared mechanism, not a new question in the pipeline.

### One invariant before any code — frozen

**Behavior Engine owns behavior. Nothing else does — not Notification,
not UI, not Chat, not the scheduler.** This is not a new design
question; it's the same "one owner per collection" discipline every
earlier phase already followed (`financialSummary` written only by
Financial Engine, `overallHealth` computed only by Health Engine),
stated explicitly here because Behavior is the first engine sharing its
neighborhood with new infrastructure (the scheduler, the Diff
Generator) — components that could tempt someone into writing directly
to `behaviorState` "just this once, since the scheduler's already
touching related data anyway."

**The rule this prevents violating, traced through one concrete flow:**

```
User logs an expense
        |
        v
Financial Engine   (recomputes financialSummary)
        |
        v
Metrics Engine     (recomputes metrics)
        |
        v
Health Engine      (recomputes overallHealth, categoryHealth)
        |
        v
Recommendation Engine  (recomputes primaryRecommendation)
        |
        v
Behavior Engine    updates behaviorState.logging.currentStreak
        |
        v
   ...time passes to the next scheduled run...
        |
        v
Scheduler          creates today's Daily Snapshot
        |
        v
Diff Generator     compares yesterday's snapshot to today's
        |
        v
Event              LOGGING_STREAK_EXTENDED
        |
        v
Notification       decides: should this interrupt the user?
```

**Notice exactly where the streak counter changes, and where it
doesn't**: `currentLoggingStreak` is updated once, by Behavior Engine,
at the moment the qualifying action happens. The scheduler never
touches it — the scheduler's only job is to take a photograph of
whatever Behavior Engine (and every other engine) already computed, the
same "infrastructure records, it doesn't decide" framing Phase 4.5A
already froze for the Diff Generator. If the scheduler ever needed to
write to `behaviorState` directly, that would be a sign the ownership
rule had already been broken.

**The same discipline applies downstream**: Notification Engine (Phase
5, not yet designed) receives `HEALTHY_STREAK_EXTENDED` as an already-
computed fact and decides only whether/when to surface it — it does not
ask Behavior Engine "how many healthy days has this user had," the same
way Notification will never ask Recommendation Engine to recompute a
recommendation on its behalf. Every layer answers its own question and
nothing upstream is ever recomputed or re-queried by a downstream
layer to shortcut its own job.

### Phase 4.5A — FROZEN

Every open question this checkpoint exists to resolve now has a
recorded answer: the Event object shape; the "persist everything, no
ephemeral tier" decision; the Daily Snapshot field shape (including
per-engine `*Version` stamps and the `snapshotDate`/`generatedAt`
split); the Diff Rules table as the literal, frozen source of truth for
which changes become events; the Diff Generator's idempotency guarantee;
the Daily-Snapshot-vs-Live-Snapshot timing split; `SNAPSHOT_VERSION`/
`DIFF_VERSION` as the infrastructure layer's own version constants; the
rebuild policy (historical record, not source of truth for money, never
silently regenerated); the event lifecycle; event storage ownership;
the `behaviorState`/`behaviorHistory` split, narrowed to genuinely
Behavior-specific records; and the ownership invariant above. Nothing
here is implemented yet — this phase froze *design*, deliberately,
before any of it was coded, per the checkpoint's own purpose.

**Implementation order from here — corrected: the scheduler and Diff
Generator move to Steps 9-10, after every behavior category exists, not
before.** Building the scheduler first would mean it starts writing
Daily Snapshots whose `behavior` field is incomplete (only whichever
categories happen to be built so far) — every snapshot taken before
Step 8 would be a permanently incomplete historical record, since
snapshots are never rebuilt after the fact (rebuild policy, above).
Sequencing the scheduler last guarantees every Daily Snapshot it ever
writes captures the complete Behavior picture from day one.

```
Phase 4.5A  [FROZEN] Infrastructure design
        |
        v
Step 1   Collections: behaviorState, behaviorHistory,
         dailySnapshots, events -- schema only, no logic
        |
        v
Step 2   BehaviorState Repository -- load / save / update /
         initialize -- no business logic
        |
        v
Step 3   Logging Behavior    -- implement, test, freeze
        |
        v
Step 4   Spending Behavior   -- implement, test, freeze
        |
        v
Step 5   Saving Behavior     -- implement, test, freeze
        |
        v
Step 6   Recovery Behavior   -- implement, test, freeze
        |
        v
Step 7   Milestones          -- implement, test, freeze
        |
        v
Step 8   Behavior Summary    -- everything now summarizable
        |
        v
Step 9   Scheduler           -- only now; snapshots are complete
        |
        v
Step 10  Diff Generator      -- only now; snapshots have full behavior
        |
        v
Step 11  Phase 4.5 Review & Freeze  (same treatment as
         Phase 2 Review, Phase 3.1 Review)
        |
        v
Phase 5 -- Notification Engine
```

**Explicit rule alongside this order: Phase 5 does not start midway.**
Even a single-notification shortcut ("let's just send the streak
notification now, Behavior mostly works") is deferred until Step 11 is
actually frozen — the same "finish this layer before touching the next
one" discipline already enforced for every phase from 1 through 4.

### 4.5.1 — Logging Behavior

**Question**: "How consistently does the user record transactions?"

**Decisions, frozen:**

- **What counts as a "logged day"?** A calendar day (day boundary
  decision revised below) on which at least one transaction was
  **created as confirmed, or a pending transaction was confirmed** that
  day.
- **Does confirming a bank notification count?** Yes — on the day of
  confirmation, not the day of the original bank event. Confirming is a
  real engagement action.
- **Does editing count?** No. Editing modifies an already-logged
  record; it doesn't represent new engagement on the day of the edit.
- **Does deleting count?** No, same reasoning — a correction, not a new
  logging act.
- **Does only income count?** No — expense or income, either counts.
  The question is "did the user engage with recording financial
  activity today," not "did they log spending specifically."
- **Minimum number of transactions?** One. There is no "the more the
  better" scoring — a single confirmed transaction is sufficient to
  count the day as logged.
- **What breaks a logging streak?** Any full calendar day with zero
  qualifying actions above.
- **Can a missed day be recovered retroactively?** No. Backfilling a
  missed day by logging it late would misrepresent real-time engagement
  — exactly the honesty this metric exists to observe. A missed day
  ends the streak; the next logged day starts a new one at 1.

**Logging Behavior State Machine — frozen.** Thinking in transitions,
not in the streak number itself, is what makes the "once per day, not
once per transaction" rule explicit rather than implicit in code:

```
No activity today
        |
        v
First valid transaction today  --------->  (any further valid
        |                                   transaction today: no-op,
        v                                   see invariant below)
Today becomes Logged
        |
        v
Logging streak updates (continue, or restart at 1 after a gap)
        |
        v
Behavior state saved
```

**Valid triggers — frozen table.** These reuse the exact same
`RecomputeReason` vocabulary Financial Engine already defines (Section
0/Phase 1 — "reused, not reinvented," the same discipline that carried
the Financial Events straight into the Event Catalog) rather than
inventing a parallel set of action names:

| Action | `RecomputeReason` | Counts as logged? | Why |
|---|---|---|---|
| Manual expense | `TRANSACTION_CREATED` | ✅ | Financial activity |
| Manual income | `TRANSACTION_CREATED` | ✅ | Financial activity |
| Chat transaction | `TRANSACTION_CREATED` | ✅ | User intentionally logged it |
| Confirm notification / pending transaction | `TRANSACTION_CONFIRMED` | ✅ | User confirmed it |
| Edit transaction | `TRANSACTION_EDITED` | ❌ | Doesn't create a new logged day |
| Delete transaction | `TRANSACTION_DELETED` | ❌ | Doesn't create activity |
| Undo transaction | *(none — see below)* | ❌ | Correction only |
| Budget change | `BUDGET_CREATED`/`_UPDATED`/`_DELETED` | ❌ | Planning only |
| Goal creation | `GOAL_CREATED`/`_UPDATED`/`_DELETED` | ❌ | Planning only |
| Income figure updated | `INCOME_UPDATED` | ❌ | Not a transaction |
| Month rollover | `MONTH_ROLLOVER` | ❌ | System housekeeping, not user activity |

**"Undo transaction" has no dedicated reason code — named honestly, not
invented to fill the table.** Grepping every `engine_recompute(...,
reason=...)` call site (`routes/transactions.py`, `routes/chat.py`,
`routes/confirm.py`) confirms this codebase has no separate "undo"
action distinct from deleting the transaction that was just created —
undo is a delete, and already correctly falls under
`TRANSACTION_DELETED` (❌) with no new code path required. **Category
creation was in the original candidate list but doesn't appear in the
frozen table at all** — categories are a fixed list, not a recompute-
triggering entity anywhere in this codebase, so there is no reason code
for it to map to; it was never a real trigger to begin with.

**Frozen invariant: logging is per day, not per transaction.**

```
09:00  Expense created   -> loggedToday was false -> becomes true -> streak +1
11:00  Expense created   -> loggedToday already true -> no-op, streak unchanged
```

Three transactions logged in one day (`Food 100`, `Food 50`,
`Transport 40`) update the streak exactly **once**, on the first
qualifying transaction of the day — every subsequent qualifying action
that same calendar day is a no-op against `behaviorState.logging`. This
is checked by comparing the incoming event's local date against
`logging.lastLoggedDate` before touching the streak at all, never by
counting transactions.

**Frozen: missed-day logic.**

```
July 18   logged        -> streak continues
July 19   nothing       -> (streak not touched yet; it's still July 18's value)
July 20   first expense -> gap detected (lastLoggedDate was 2 days ago,
                            not 1) -> streak resets to 1, not 3
```

The streak is never incremented "for" a missed day, and a missed day is
never silently absorbed into a running total — a gap of more than one
calendar day between `lastLoggedDate` and today always restarts the
streak at 1 on the next qualifying action, regardless of how long the
prior streak had run.

**Frozen: initialization.** A brand-new user's first-ever qualifying
transaction transitions `behaviorState.logging` directly from the
repository's default shape (`currentStreak: 0, bestStreak: 0,
streakStartedOn: null, lastLoggedDate: null`) to `currentStreak: 1,
bestStreak: 1, streakStartedOn: today, lastLoggedDate: today` — the
same "no activity yet" starting state every user begins in, not a
special first-time code path. This is required to have its own test,
named explicitly rather than assumed to fall out of the general case.

**Frozen: day-boundary timezone.** Every prior date decision in this
spec (`get_current_month_key`, `get_days_remaining_in_month`, and every
other `datetime.now(timezone.utc)` call in `utils.py`) has used server
UTC — and Logging Behavior is a deliberate, named departure from that,
not an oversight. **Decision: Logging Behavior determines "today" using
a fixed Nepal Standard Time offset (UTC+5:45, no daylight saving),
`LOGGING_TIMEZONE`,** not server UTC and not a per-user configurable
timezone. Reasoning: this app has no per-user timezone field anywhere
in the profile schema today (checked — `schemas/profile.py` and
`schema.md` have none), and the app is single-currency (NPR) and
Nepali-English by design, so every real user is in the same timezone;
inventing a `user.preferences.timezone` field to support a
configurability need with zero actual users outside Nepal would be
exactly the premature abstraction this spec has avoided everywhere
else. A fixed constant, not a per-user lookup, is the honest scope for
today's user base — revisit only if the app ever supports users outside
Nepal.

**Named, not fixed here: this creates a real, narrow inconsistency with
Financial Engine's month boundary** (`get_current_month_key()` still
rolls over at UTC midnight, i.e. 05:45 Kathmandu time). A transaction
at 05:30 Kathmandu on the 1st could log against the *previous* UTC
month-key while counting as "today" for Logging Behavior's Kathmandu
calendar day. This is a pre-existing UTC-vs-local mismatch surfaced by
this decision, not created by it — Financial Engine's month boundary is
already frozen (Phase 1) and out of scope to reopen here. Named
honestly so it isn't rediscovered as a surprise later, not silently
patched over by fixing only Logging Behavior's clock.

**Required tests before freezing 4.5.1** (unit, synthetic — no
Firestore needed except where noted):

1. First transaction ever (initialization)
2. Second transaction, same day (no-op invariant)
3. Consecutive days (streak continues)
4. One missed day (streak resets to 1)
5. Two missed days (streak still resets to 1, not further penalized)
6. Edit transaction (no effect on streak)
7. Delete transaction (no effect on streak)
8. Undo transaction (covered by the delete case — no separate code path exists)
9. Notification confirmation (counts)
10. Chat transaction (counts)
11. Manual transaction (counts)
12. Income transaction (counts, same as expense)
13. Timezone boundary (a UTC-day-boundary-crossing timestamp that is
    still "the same day" in `LOGGING_TIMEZONE`, and vice versa)
14. Multiple transactions same day (streak updates exactly once,
    regardless of transaction count)

**Real-account verification — scoped intentionally narrower than the
unit tests, not exhaustive:**

1. Record one qualifying transaction today → streak becomes/stays
   correctly incremented exactly once.
2. Record a second qualifying transaction the same day → streak does
   not increase again.
3. A `TRANSACTION_CONFIRMED` event counts identically to
   `TRANSACTION_CREATED` when it's the day's first qualifying action.
4. `behaviorState/current` read back from Firestore matches the
   expected shape exactly, field for field.

Everything else (missed-day math, initialization, timezone edge cases)
is fully covered by the synthetic unit tests above and doesn't need
real-Firestore re-verification — the repository layer (Step 2) already
proved the read/write path itself is correct; these four scenarios only
need to confirm Logging Behavior's logic is wired to that proven path
correctly.

**Output:**

```
loggingBehavior: {
  currentStreak, bestStreak, streakStartedOn, lastLoggedDate,
  loggingRate,       // logged days / days elapsed this month
  confidence: "high", // pure counting of confirmed transactions — no
                       // future assumption, unlike Recommended Daily Spend
  events: [...]
}
```

### Step 3 — Logging Behavior — FROZEN

Implemented in `services/behavior_engine.py`,
`record_logging_activity(db, uid, reason, occurred_at=None)`. All 14
required unit tests pass (`tests/test_behavior_engine.py`, synthetic,
no Firestore); the 4 scoped real-account scenarios were verified
against `botbachat@gmail.com`'s live `behaviorState/current` document
and the account was reset to the clean default shape afterward.

**Named, not yet done — deliberately deferred, not an oversight:**
`record_logging_activity()` is not yet called from any route. The
~8 call sites that already invoke `engine_recompute(db, uid, month_key,
reason=RecomputeReason.X)` (`routes/transactions.py`, `routes/chat.py`,
`routes/confirm.py`) are the natural place to add a matching call,
passing the same `reason` string straight through — but wiring 8
existing, already-frozen route files is a separate, explicit change,
not something to fold silently into "finish Logging Behavior." Whether
that wiring happens per-category as each is frozen, or all at once
after Step 8 (Behavior Summary), is an open sequencing question for
whenever code needs to actually run in production — not a design gap in
Logging Behavior itself, which is complete on its own terms.

**Noted for later, not built now: a single public entry point.**
`record_logging_activity()` is the first of what will become several
similarly-shaped specialized functions
(`record_spending_activity()`/4.5.2, and presumably a saving/recovery
equivalent). Once all categories exist, Behavior Engine should
consolidate behind one public entry point —

```
BehaviorEngine.recordActivity(activityType, timestamp, source)
    -> internally dispatches to recordLogging(), recordSpending(),
       recordRecovery(), recordSaving()
```

— so callers depend on one stable surface instead of importing a
different specialized function per category. **Deliberately not done
today**: with only one category built, there's nothing yet to
consolidate *behind* — building the dispatcher now would be exactly the
premature abstraction this spec has avoided everywhere else (three
similar functions is fine; a dispatcher for one function is not). Revisit
once Step 7 (Milestones) is frozen and every category's specialized
function actually exists to be wrapped.

### 4.5.2 — Spending Behavior

**Question**: "Is spending becoming more disciplined?"

**Decisions, frozen:**

- **What is a healthy day?** A day whose **snapshotted Overall Health
  status was not Red.** Reuses Health's own classification directly —
  never a separate, parallel threshold invented here.
- **Is one overspent category enough to break a healthy day?** No — one
  material high-pressure (even exhausted) category alone only reaches
  Amber in Overall Health (Phase 3.0's Q2 decision), not Red, so it
  alone doesn't disqualify the day.
- **Does Overall Health determine it?** Yes, entirely — see above.
- **Can Recovery Plan override it?** No separate override needed —
  Recovery Plan already feeds Overall Health (`RECOVERY_NEEDED` →
  Amber, `RECOVERY_IMPOSSIBLE` → Red), so its effect is already
  incorporated once, not reapplied a second time here.
- **Does one bad day immediately break the streak?** Yes — a Red day
  ends the healthy streak the same way a missed day ends the logging
  streak; no partial credit.

**Frozen, before writing any code: a day is judged by its end-of-day
financial state, never by individual transactions during the day.**
Logging asks a binary, moment-in-time question ("did anything happen
today") — Spending Behavior asks a fundamentally different one ("how
did today end up"), and that difference in *kind* of question is what
makes end-of-day evaluation the only rule that doesn't collapse under
its own edge cases.

```
10:00  Spend 500        -> Overall Health: Red
18:00  Income arrives    -> Overall Health: Green
                          -> day is judged Green — evaluated once, at
                             end of day, not once per transaction
```

Trying to evaluate every transaction independently would require a
rule for "how do multiple health states in one day combine" — a
question that doesn't need to exist at all once the day is judged by
its single end-of-day snapshot.

**Frozen: the healthy/overspending streaks are finalized only when the
day closes — during the daily snapshot job (Step 9) — never updated
mid-day, unlike Logging Behavior.** Logging can update the moment a
qualifying transaction happens because its question is already
decided the instant it happens (binary, no further information later
in the day can change the answer). Spending's question can't be
decided until the day is over — an update made at 8 AM would have to be
silently undone at 9 PM, which is exactly the kind of correction this
spec has avoided everywhere else (Ground Truth Principle, Section 8:
recompute from source, never patch a stored value after the fact).

```
08:00  Overall Health: Green  -> NOT applied to streak yet
                                  (the day isn't over)
21:00  Overspend, Overall Health: Red
                                  -> day ends Red
                                  -> streak evaluated once, at end of
                                     day, during the snapshot job
                                  -> healthy streak broken (correctly —
                                     no morning increment ever happened
                                     that would need undoing)
```

This is also exactly why Spending Behavior's streak update is not a
new call site added to the transaction routes the way Logging's
eventually will be (Step 3's named integration gap) — its update has
only one legitimate caller: the Step 9 scheduler, once per day, after
that day's Daily Snapshot has captured the final `overallHealth.status`.
Spending Behavior's own function is therefore fully implementable and
unit-testable now (given a snapshot date and a health status, apply the
same streak math Logging already established), but has no real caller
until Step 9 exists — the same "implemented, not yet wired" gap Step 3
named for its own reason, here for a different one.

**Frozen: the same missed-day safety net Logging Behavior already has,
reused rather than re-derived.** If the scheduler fails to run for a
day (crash, deploy gap), the next successful evaluation compares the
new snapshot date to the last evaluated date — a gap of more than one
day resets the current streak the same way an unlogged gap resets
Logging's streak, rather than silently treating the missing day as
either healthy or unhealthy by assumption.

**A genuine gap in the Behavior State Model, found here and fixed at
the layer it belongs to, same discipline as Phase 2.3a's Category Daily
Target**: `spending.lastHealthyDate` alone can't answer "was there a
scheduler gap," because it's only written on *healthy* days — a
consecutive run of Red days would leave it stale and indistinguishable
from a real multi-day scheduler outage. **`lastEvaluatedDate` added to
the frozen shape** (Phase 4.5A's Behavior State Model, updated) —
written on *every* evaluation regardless of outcome, giving the gap
check one unambiguous field to compare against instead of overloading
`lastHealthyDate` with a second meaning it was never meant to carry.

**A new infrastructure requirement, named honestly**: determining "was
*that* day healthy" requires a **daily Overall Health snapshot** —
`financialSummary` is monthly, and Overall Health is computed on demand
for *now*, not for an arbitrary past date. This is exactly the job the
Phase 4.5A Daily Snapshot infrastructure exists to provide: a once-daily
job (the same scheduling mechanism `main.py` already runs for
month-rollover — see `endpoints.md`'s scheduler jobs) computes Overall
Health, along with every other domain engine's output, once per day and
writes it to `users/{uid}/dailySnapshots/{date}` — a neutral,
infrastructure-owned collection, not a `behaviorState` or
`behaviorHistory` field, since it isn't Behavior-specific data (see
Phase 4.5A). Spending Behavior just reads that day's
`health.overallHealth.status` off the snapshot the same way any other
domain engine would. This is new, not yet built — named now so it isn't
discovered as a missing piece mid-implementation.

**Output:**

```
spendingBehavior: {
  healthyStreak: { current, best },
  overspendingStreak: { current },
  healthyDaysThisMonth,
  confidence: "medium",  // depends on daily logging being complete/timely
  events: [...]
}
```

**Corrected from the original draft**: `overspendingStreak.best` was
listed here before `behaviorState.spending`'s shape was actually
implemented — the state model has no `bestOverspendingStreak`, and
there shouldn't be one. Unlike a best *healthy* streak (a real
achievement worth surfacing), a "longest run of bad financial days" has
no motivating purpose to show the user and was never a real requirement
— it was carried over by analogy with the healthy streak's shape
without being questioned. Removed here rather than implemented just to
match a shape nothing actually needed.

### Step 4 — Spending Behavior — FROZEN

Implemented in `services/behavior_engine.py`,
`record_spending_activity(db, uid, overall_health_status, snapshot_date)`.
All 9 unit test scenarios pass (`tests/test_behavior_engine.py`,
synthetic — healthy/unhealthy transitions, consecutive streaks, the
gap safety net, and same-day idempotency); 3 scoped real-account
scenarios were verified against `botbachat@gmail.com`'s live
`behaviorState/current` document and the account was reset to the
clean default shape afterward.

**A genuine schema gap found and fixed here, not worked around**:
`spending.lastEvaluatedDate` was added to the frozen Behavior State
Model (Phase 4.5A) because `lastHealthyDate` alone couldn't distinguish
"yesterday was evaluated and unhealthy" from "the scheduler didn't run
yesterday at all" — the same "add the missing capability at the layer
where it belongs" discipline as Phase 2.3a's Category Daily Target.
This changed the frozen default shape, which required migrating the
real test account's already-initialized `behaviorState/current`
document (via `save_state()` with the corrected default) before
verification could proceed — named here so a future reader isn't
puzzled by why a "frozen" schema changed shape mid-project: it changed
*before* Spending Behavior was itself frozen, the same way Category
Daily Target amended a frozen Phase 2 without reopening it.

**Same named gap as Step 3, for the same reason**:
`record_spending_activity()` has no caller yet — its only legitimate
caller is the Step 9 daily scheduler, which doesn't exist until every
behavior category is built (per the corrected implementation order,
Phase 4.5A). Fully implemented and tested on its own terms; wiring is
deferred, not an oversight.

### Actual Savings — a new frozen term, introduced here

**Actual Savings = that month's Income − that month's confirmed
Spending, both read directly from the closed month's already-frozen
`financialSummary` document, never recomputed.** Evaluated only *after*
the month has completed — this is the ground truth Saving Behavior
judges against, and the term every later phase (Notifications,
Coaching, Reports) should reuse rather than re-deriving "income minus
spending" independently each time.

**Frozen: three different concepts of "saving" exist in this codebase
and must never be confused with one another:**

| Concept | What it means | When it's known |
|---|---|---|
| Savings Pool | Income minus *budgeted* limits — unallocated planning headroom | Live, throughout the month |
| Projected Savings | A forecast of where Savings Pool will end up if current spending pace continues | Mid-month, under an explicit assumption |
| **Actual Savings** | Income minus *actual confirmed* spending for a **completed** month | Only after the month ends |

Savings Pool and Projected Savings already exist (Financial Engine and
Metrics Engine, Phase 2.7 respectively) and are correct for their own
questions — *planning* and *prediction*. **Neither is Actual Savings,
and Saving Behavior must never read either of them as if it were.**

### 4.5.3 — Saving Behavior

**Question, frozen as exactly one question, deliberately narrower than
the original candidate list**: *"Did the user finish the month with
positive Actual Savings?"* Not "did they save more than last month," not
"did they meet a goal target," not "is Projected Savings trending well"
— those are trend, planning, and coaching questions for a later phase;
Saving Behavior evaluates one completed outcome, the same way Spending
Behavior evaluates one completed day, nothing more.

**Decisions, frozen:**

- **What counts as a successful saving month?** `Actual Savings > 0`
  for that month, evaluated once, after the month closes. Not Savings
  Pool being positive (it almost always is, by construction — a
  planning figure, not a settled fact); not Projected Savings crossing
  a threshold (a forecast, not what happened); not goal progress (no
  such target concept exists as its own tracked state — see the
  research that led here).
- **Is this a relative, month-over-month comparison?** No, and
  deliberately not — a base streak that only rewards *increasing*
  savings would end a "success" streak for someone who saved 9,000
  after a 10,000 month, even though both months were genuinely
  successful outcomes. Trend ("saved more than last month") is a
  distinct, optional coaching signal for later, never the base
  definition.
- **When is this evaluated?** Tied to the **already-existing**
  `MONTH_ROLLOVER` Financial Event (`budget_service.py`'s
  `run_month_rollover`, already scheduled in `main.py`) — not the
  Step 9 Daily Snapshot scheduler, which doesn't exist yet and evaluates
  a different cadence entirely (days, not months). This is a genuine
  asymmetry with Spending Behavior worth naming: Saving Behavior's
  trigger infrastructure already exists today; it simply isn't wired to
  Behavior Engine yet — the same "implemented, not yet wired" shape as
  Steps 3 and 4, for a third distinct reason.
- **What breaks the protection streak?** A month closing with Actual
  Savings ≤ 0 — no partial credit, same binary-break philosophy as
  Logging's missed day and Spending's Red day.

**Output:**

```
savingBehavior: {
  protectionStreak: { current, best },
  confidence: "high",  // Actual Savings is a settled fact from a
                        // closed month, not a forecast — no
                        // assumption to hedge against, unlike
                        // Projected Savings
  events: [...]
}
```

**Corrected from the original draft**: `goalContributionStreak` is
dropped entirely — it depended on Goal Progress, which the research for
this step showed isn't a real, separately-tracked target in this
codebase (`goal_service.py`: a goal is "a label on part of the [Savings]
pool, not a separate wallet"). Tracking a streak against a concept that
doesn't exist as its own ground truth would mean inventing new state
Financial Engine never actually promised. `behaviorState.saving`'s
frozen shape (Phase 4.5A) already only ever had
`currentProtectionStreak`/`bestProtectionStreak`/`lastMonthKeyEvaluated`
— no field for it was ever added, so nothing needs to be removed from
the state model itself, only from this output shape and the original
draft's decision text.

### Step 5 — Saving Behavior — FROZEN

Implemented in `services/behavior_engine.py`,
`record_saving_activity(db, uid, month_key, actual_savings)`. All 9
unit test scenarios pass (`tests/test_behavior_engine.py`, synthetic —
consecutive months, the zero/negative boundary, a skipped-month gap,
idempotency, and the December→January year-boundary case); 3 scoped
real-account scenarios were verified against `botbachat@gmail.com`'s
live `behaviorState/current` document and the account was reset to the
clean default shape afterward.

**Same named gap as Steps 3-4, for a third distinct reason**:
`record_saving_activity()` has no caller yet. Unlike Spending, its
trigger infrastructure already exists today (`run_month_rollover`) —
the gap here is purely that the call hasn't been added yet, not that
anything new needs to be built first.

### 4.5.4 — Recovery Behavior

**Question, frozen as exactly one question**: *"Did the user's Recovery
Plan resolve, and did it ever become impossible along the way?"* Not
"is spending healthy again" (Spending Behavior's own question, and a
signal that can diverge from Recovery Plan's own state — see below),
not "has severity improved" (a within-plan gradation, not a resolution),
not "is the affected category un-exhausted" (incomplete — a plan can be
needed from spending pace alone, with no exhausted category at all).

**Definition of "recovered," frozen: Recovery Plan disappearing** —
`compute_recovery_plan()` (Metrics Engine, Phase 2.5) transitioning
from present to absent. This is the exact signal Health Engine already
treats as the transition (`RECOVERY_NEEDED`/`RECOVERY_IMPOSSIBLE`
presence), reused directly rather than reinvented. **Three other
candidates were considered and rejected**, each for a reason found
while researching the existing engines, not by preference alone:

- **"Overall Health returns to Green"** — rejected. Recovery Plan
  presence and Overall Health are related but not the same signal:
  presence always keeps Health at least Amber, but *absence* doesn't
  guarantee Green — a `PROJECTED_DEFICIT` can hold Health Red for a
  reason that has nothing to do with Recovery Plan. Using Health-Green
  here would make Recovery Behavior silently answer Spending Behavior's
  question instead of its own.
- **"Recovery Plan severity drops"** — rejected. Severity
  (`minor`/`medium`/`high`) can improve while the plan is still fully
  present — that's the plan getting less severe, not resolving.
- **"The affected category is no longer exhausted"** — rejected,
  demonstrably incomplete: Recovery Plan can trigger from spending pace
  or a sudden drop in recommended daily spend with **zero** exhausted
  categories at all (`affectedCategories` can be empty). Defining
  recovery this way would silently miss most real recoveries.

**Recovery is a lifecycle, not a single flag — frozen:**

```
No open recovery
        |
        v
Recovery Plan appears (RECOVERY_NEEDED or RECOVERY_IMPOSSIBLE)
        |
        v
Recovery attempt OPEN -- openRecoveryStartedOn recorded,
                         totalAttempts += 1
        |
        | (plan stays present across however many days;
        |  recoveryPossible can flip false -> true -> false
        |  more than once while still open)
        |
        v
recoveryPossible flips true -> false at any point while open?
        |
   yes  |  no
        v     v
  openRecoveryEverImpossible      (unchanged: stays whatever
  set to true, permanently,       it already was)
  for the rest of this attempt
        |
        v
Recovery Plan disappears -- attempt CLOSES
        |
        v
   if openRecoveryEverImpossible was ever true during this attempt:
       -> RECOVERY_FAILED, totalFailed += 1, streak resets to 0
   else:
       -> RECOVERY_COMPLETED, totalResolved += 1, streak += 1
        |
        v
openRecoveryStartedOn and openRecoveryEverImpossible reset
for the next attempt
```

**A genuine correction found while designing this step, fixed before
coding, not after**: Phase 4.5A's Diff Rules table originally mapped
`recoveryPossible: true → false` directly to `RECOVERY_FAILED`. That
conflated two different moments — the live fact that recovery is
impossible *right now* (a Health-layer signal, judging nothing) with
the retrospective classification of the whole attempt once it closes
(a Behavior-layer judgment that can only be made at resolution, using
memory of the entire attempt). Fixed: the live transition now maps to
the already-named Health Event `RECOVERY_BECAME_IMPOSSIBLE`;
`RECOVERY_COMPLETED`/`RECOVERY_FAILED` are Behavior Events, mapped to
`behaviorState.recovery.totalResolved`/`totalFailed` incrementing — see
Phase 4.5A's corrected Diff Rules table.

**Why `openRecoveryEverImpossible` had to be added to the frozen state
model, not computed on the fly**: a snapshot only ever answers "what is
true now"; only Behavior Engine's own persisted state can answer "has
this ever happened during the current attempt" — the same reasoning
that justified `lastEvaluatedDate` for Spending Behavior, here applied
to a boolean that must survive across however many days one recovery
attempt spans, not just yesterday-to-today.

**`recoveryStartDate` was proposed for future recovery-duration
analytics (average/fastest/longest recovery) — already covered, no new
field needed.** `behaviorState.recovery.openRecoveryStartedOn` (frozen
in the original Behavior State Model, before this step) already *is*
that timestamp — Average Recovery Time, Fastest Recovery, and Longest
Recovery are all derivable from `openRecoveryStartedOn` at the moment
each attempt closes, without adding anything new. Named explicitly here
so a future reader doesn't wonder why it wasn't duplicated.

**Decision, frozen: evaluated once daily, same cadence as Spending
Behavior, via the Step 9 scheduler — never live/immediate like
Logging.** Recovery Plan's own presence and `recoveryPossible` value are
computed live by Metrics Engine on every request; detecting "did this
change since yesterday" is a day-boundary comparison exactly like
Spending Behavior's healthy-day check, not a per-transaction event.
`record_recovery_activity()`'s only legitimate caller is therefore the
same Step 9 Daily Snapshot job Spending Behavior already depends on —
a fourth instance of the "implemented, not yet wired" gap named in
Steps 3-5, here because the same not-yet-built scheduler is the
dependency.

**Output:**

```
recoveryBehavior: {
  currentStreak, bestStreak,
  successRate,        // totalResolved / totalAttempts
  averageRecoveryDays,
  recoveriesThisMonth,
  confidence: "medium",
  events: [...]
}
```

### Step 6 — Recovery Behavior — FROZEN

Implemented in `services/behavior_engine.py`,
`record_recovery_activity(db, uid, recovery_plan_present, recovery_possible, snapshot_date)`.
All 12 unit test scenarios pass (`tests/test_behavior_engine.py`,
synthetic — opening, staying open across multiple days, the sticky
`openRecoveryEverImpossible` flag surviving a mid-attempt recovery,
closing as both `RECOVERY_FAILED` and `RECOVERY_COMPLETED`, consecutive
clean recoveries extending the streak, and same-day idempotency in both
the opening and closing directions); 4 scoped real-account scenarios
were verified against `botbachat@gmail.com`'s live `behaviorState/current`
and `behaviorHistory/current` documents, and the account was reset to
the clean default shape afterward.

**Two genuine corrections found and fixed here, before code, not
after**: the Diff Rules table's `RECOVERY_FAILED` row was conflating a
live Health signal with a retrospective Behavior judgment (fixed —
see 4.5A and above); and `openRecoveryEverImpossible` was added to the
frozen state model because a snapshot can only ever answer "what's true
now," never "did this happen at some point during an attempt that may
span many days." `recoveryStartDate`, proposed for future recovery-
duration analytics, needed no new field — `openRecoveryStartedOn`
already covers it, frozen since before this step.

**Same named gap as Steps 4-5, for the same underlying reason as Step
4**: `record_recovery_activity()` has no caller yet — its only
legitimate caller is the Step 9 Daily Snapshot scheduler, which doesn't
exist yet.

### 4.5.5 — Milestones

**Question, frozen as exactly one question, distinct from every other
category's**: *"Has this ever happened before?"* Once the answer
becomes yes, it can never become no again — that's the one property
that separates a Milestone from a Behavior Event, and it's frozen as
the sole test for which bucket a given achievement belongs in:

- **Milestone** — answers "has this ever happened," permanent once
  true, lives in `behaviorHistory.milestones[]`.
- **Behavior Event** — answers "did this happen again," can recur any
  number of times across a lifetime, belongs to the event system
  (Diff Generator / Event Catalog), never to `behaviorHistory.milestones`.

**Corrected from the original draft, which conflated the two**: the
original candidate list mixed genuinely one-time achievements with
things that can legitimately recur, and referenced a
`behaviorState.milestones.unlocked` field that never actually existed
in the frozen Behavior State Model (milestones were always
`behaviorHistory.milestones[]`, never `behaviorState`). Sorted here,
before any code:

**4 true milestones, implemented this step:**

| Code | Type | Threshold | Reused counter |
|---|---|---|---|
| `FIRST_EXPENSE_LOGGED` | `LOGGING_FIRST` | — | any qualifying logging activity ever occurring |
| `FIRST_HEALTHY_WEEK` | `HEALTHY_STREAK` | 7 | `spending.currentHealthyStreak` |
| `LOGGING_STREAK_30_DAYS` | `LOGGING_STREAK` | 30 | `logging.currentStreak` |
| `FIRST_GOAL_COMPLETED` | `GOAL_COMPLETED` | — | `goal_service.compute_goal_progress()` — the existing calculation, not reinvented |

**4 reclassified as recurring Behavior Events, not Milestones — moved
out of this system entirely**: `BACK_ON_TRACK`,
`MONTH_FINISHED_UNDER_BUDGET`, and `BEST_STREAK` (renamed
`NEW_BEST_STREAK` to make the recurring nature explicit in the name
itself — a streak can set a new personal record more than once in a
lifetime, so permanently "unlocking" it the first time would silently
suppress every future record), and `CONSISTENT_LOGGER`, kept only if a
future phase defines it as a repeated achievement, never a permanent
unlock.

**2 dropped outright, not implemented**: `TRANSACTIONS_LOGGED_100` and
`CONFIRMATIONS_100`. Neither has a real backing counter anywhere —
`behaviorState.logging` tracks streaks, not a lifetime transaction
count, and Financial Engine doesn't persist one either (a count would
require a live query across all transactions, not a stored field).
Building these would mean inventing new persisted state solely to
support a milestone — the same rule that removed
`goalContributionStreak` in Step 5, applied here to a different pair of
candidates.

**Storage shape, frozen as extensible rather than one hardcoded code
per threshold**: each entry is `{ code, type, threshold, unlockedAt }`,
not just `{ code, unlockedAt }`. A future decision to also celebrate a
100-day or 365-day logging streak means adding another `{ type:
"LOGGING_STREAK", threshold: 100 }` definition, never redesigning the
stored shape — `code` (e.g. `LOGGING_STREAK_30_DAYS`) stays the
UI/Notification-facing identifier, `type`/`threshold` are what the
unlock-checking logic actually evaluates against, kept separate so the
two can evolve independently.

**Idempotency, frozen**: a milestone's `code` is checked against every
existing entry in `behaviorHistory.milestones[]` before unlocking —
already-present means skip, silently, every time. This is the same
"has this fact already been recorded" discipline the repository already
enforces structurally elsewhere (Firestore's own document identity for
`behaviorState`/`behaviorHistory`), just applied to array membership
instead of document existence.

**Timing, frozen**: each of the 3 wired milestones is checked
immediately, inline, right after the record function that owns the
relevant counter finishes updating it — `record_logging_activity()`
checks `FIRST_EXPENSE_LOGGED`/`LOGGING_STREAK_30_DAYS` against its own
just-computed streak; `record_spending_activity()` checks
`FIRST_HEALTHY_WEEK` against its own just-computed streak. No new
scheduler dependency, unlike Spending/Recovery — a milestone crossing is
knowable the instant the relevant streak changes, the same reasoning
Logging Behavior itself already relies on. `FIRST_GOAL_COMPLETED` is
implemented but has no caller yet (goal progress isn't produced by any
of the four `record_*_activity()` functions) — the same
"implemented, not yet wired" gap named for every other step, here
because goal completion isn't naturally triggered by a transaction,
day, or month boundary the way the other three are.

### Step 7 — Milestones — FROZEN

Implemented in `services/behavior_engine.py`: `_check_milestone()` (the
shared unlock-once helper every wired milestone funnels through),
inline calls from `record_logging_activity()`
(`FIRST_EXPENSE_LOGGED`, `LOGGING_STREAK_30_DAYS`) and
`record_spending_activity()` (`FIRST_HEALTHY_WEEK`), and the standalone
`check_goal_milestones(db, uid, goal_progress, today=None)` for
`FIRST_GOAL_COMPLETED`. All 10 unit test scenarios pass
(`tests/test_behavior_engine.py` — first-ever unlock, no re-unlock
across many further qualifying days, the exact-threshold boundary for
both streak-based milestones, and goal completion including a second
completed goal not re-triggering it); 4 scoped real-account scenarios
were verified against `botbachat@gmail.com`'s live
`behaviorHistory/current` document, and the account was reset to the
clean default shape afterward.

**The permanent-vs-temporary split, frozen as the sole test governing
this system**: a Milestone answers "has this ever happened" and is
permanent once true; a Behavior Event answers "did this happen again"
and can recur. Applying that test reclassified 4 of the original 9
candidates (`BACK_ON_TRACK`, `MONTH_FINISHED_UNDER_BUDGET`,
`BEST_STREAK` → renamed `NEW_BEST_STREAK`, `CONSISTENT_LOGGER`) out of
the milestone system entirely, and dropped 2 more
(`TRANSACTIONS_LOGGED_100`, `CONFIRMATIONS_100`) for having no backing
counter anywhere in the codebase — the same "don't invent state to
support a feature" rule that removed `goalContributionStreak` in
Step 5, applied here to a different pair.

### 4.5.6 — Behavior Summary (Step 8 — the single object Notification consumes)

**Question, frozen as exactly one question**: *"How has the user been
behaving, over time?"* Not how much money, not how healthy their
finances are, not what to recommend — Behavior Summary reads only
Behavior Engine's own state (`behaviorState`/`behaviorHistory`, via the
same repository every other step already reads), never Financial,
Metrics, Health, or Recommendation output. Money and Health can
disagree with Behavior entirely, on purpose: a large unexpected expense
can legitimately send Overall Health to Red overnight while the user's
underlying habits — logging everything, following the recovery plan,
still saving — stay exactly as good as they were the day before.
Behavior Summary exists to say so.

**Scoping decision, frozen**: the `loggingBehavior`/`spendingBehavior`/
etc. "Output" blocks sketched in Steps 3-6 were design shapes for a
future public API, never built as intermediate functions. Behavior
Summary reads `behaviorState`/`behaviorHistory` directly rather than
depending on accessors that don't exist — still "only Behavior Engine's
own outputs," just their most direct form.

**Closing principle, frozen, and the one that reshaped this design from
its first draft: Health changes quickly; Behavior changes slowly.** A
single bad day can legitimately flip Overall Health from Green to Red
overnight — that's correct, Health is judging *today*. Behavior Summary
judges a *pattern*, so it must not swing on the same signal. A single
broken streak, after 180 days of consistent logging, is a blip — not
evidence the user's habits collapsed. This is why `RECOVERY_IN_PROGRESS`
does **not** appear anywhere below (recovery is a temporary situation,
not a behavior — it belongs to Health/Recommendation/Notification), and
why a single broken streak alone never drops Behavior Summary's status
by itself.

**Reasons, frozen — habit descriptions, not one-time events:**

| Bucket | Reason | Condition (reused counter, no new one) |
|---|---|---|
| Positive | `CONSISTENT_LOGGING` | `logging.currentStreak >= 7` |
| Positive | `HEALTHY_SPENDING` | `spending.currentHealthyStreak >= 7` |
| Positive | `MONTHLY_SAVING_SUCCESS` | `saving.currentProtectionStreak >= 1` |
| Positive | `RECOVERY_SUCCESS` | most recent `behaviorHistory.recoveryAttempts[]` entry has `outcome == "resolved"` |
| Neutral | `NEW_USER` | `logging.bestStreak == 0` — never logged, ever (corrected from the original draft's `NO_RECENT_ACTIVITY`, which actually meant this, not recent inactivity — a genuinely different claim this spec doesn't yet have the data to make) |
| Neutral | `BUILDING_HABITS` | has some history (`logging.bestStreak > 0`) but doesn't yet meet any Positive or Negative condition — covers a short (1-6 day) streak or a streak that recently broke; a broken streak is *neutral*, not negative, per the slow-change principle above |
| Negative | `UNHEALTHY_SPENDING_PATTERN` | `spending.currentOverspendingStreak >= 7` — itself already a streak counter, so this is a sustained pattern by construction, never a single bad day |
| Negative | `REPEATED_RECOVERY_FAILURE` | `recovery.totalFailed >= 2` — a lifetime count, so this requires *repetition*, never a single failed attempt |

**Two candidates named honestly as not implementable yet, not silently
skipped**: "very inconsistent logging" and "repeated broken streaks"
(as their own negative reasons) would need a new persisted counter —
something like a lifetime count of how many times the logging streak
has reset — that doesn't exist in `behaviorState.logging` today.
Inventing one solely to support this reason would be exactly the "don't
add state just to make a feature possible" mistake corrected twice
already (`goalContributionStreak` in Step 5, two milestone candidates
in Step 7). Left out here for the same reason, revisit only if a real
need for a lifetime streak-break count turns up elsewhere.

**Status waterfall, frozen — evaluated in this exact order, first match
wins:**

1. **Inactive** — `NEW_USER` (never logged, ever).
2. **Excellent** — `CONSISTENT_LOGGING` **and** `HEALTHY_SPENDING`
   **and** `MONTHLY_SAVING_SUCCESS`, all at once. Kept deliberately
   strict, per the review that shaped this step — Excellent should stay
   rare.
3. **Good** — **any one** of `CONSISTENT_LOGGING`, `HEALTHY_SPENDING`,
   `MONTHLY_SAVING_SUCCESS`, `RECOVERY_SUCCESS`. Broadened from the
   original draft, which required logging specifically — a strong
   habit in *any* one area is enough, without requiring logging to be
   part of it.
4. **Needs Improvement** — `UNHEALTHY_SPENDING_PATTERN` **or**
   `REPEATED_RECOVERY_FAILURE`, checked here, **before** the Building
   fallback below. This ordering is deliberate: Building's condition
   ("some history, no strong positive signal") would otherwise be broad
   enough to silently swallow every negative-pattern case, since a user
   with a persistent negative pattern usually has no positive one
   either. Needs Improvement never overrides Excellent or Good, though
   — the same slow-change principle protects sustained positive habits
   from being erased by one negative pattern, exactly as Health being
   Red doesn't erase Behavior being Excellent.
5. **Building** (fallback) — `BUILDING_HABITS`, or simply reaching this
   point without matching anything above: some history exists, nothing
   strong enough yet in either direction.

**`primaryReason`** is the single reason that decided the matched
branch above; **`reasons`** is every reason that independently
evaluated true, not only the deciding one — the same "collect
everything, then pick the priority winner" shape Health Engine already
established.

**Confidence, frozen: weakest-link across whichever reasons actually
triggered, reusing each category's own already-frozen confidence
rating** — logging: high (4.5.1), saving: high (4.5.3, corrected),
spending: medium (4.5.2), recovery: medium (4.5.4) — never a new
confidence judgment invented for the summary itself. `NEW_USER` (no
data at all) defaults to high, the same "nothing found, so nothing to
be unsure about" reasoning Health's own `_determine_confidence` already
uses for a clean Green.

```
{
  "status": "excellent",
  "primaryReason": "CONSISTENT_LOGGING",
  "reasons": [...],
  "confidence": "high",
  "summaryVersion": "1.0.0",
  "generatedAt": "...",
  "behaviorTrace": [...]
}
```

### Step 8 — Behavior Summary — FROZEN

Implemented in `services/behavior_engine.py`,
`compute_behavior_summary(db, uid, generated_at=None)` — read-only,
writes nothing. All 14 unit test scenarios pass
(`tests/test_behavior_engine.py` — every status branch, the
Excellent/Good-survives-a-simultaneous-negative-pattern case, a single
broken streak staying neutral rather than dragging status down,
`RECOVERY_IN_PROGRESS` confirmed absent from every reason list, and
weakest-link confidence); 3 scoped real-account scenarios were verified
against `botbachat@gmail.com`'s live `behaviorState/current` and
`behaviorHistory/current` documents (including confirming the summary
computation itself never writes state), and the account was reset to
the clean default shape afterward.

**The design that shaped this step, in one sentence: Health changes
quickly, Behavior changes slowly.** That's why `RECOVERY_IN_PROGRESS`
was removed entirely (a temporary situation, not a habit); why
`NO_RECENT_ACTIVITY` was renamed `NEW_USER` once it became clear the
original condition (`bestStreak == 0`) actually meant "never used the
app," not "recently inactive" — a genuinely different claim this spec
doesn't yet have the data to make; why a single broken streak is
`BUILDING_HABITS` (neutral) rather than a negative signal; and why the
two negative reasons that did survive
(`UNHEALTHY_SPENDING_PATTERN`, `REPEATED_RECOVERY_FAILURE`) are both
backed by counters that only trigger from genuine repetition
(`currentOverspendingStreak >= 7`, `totalFailed >= 2`), never a single
bad day.

**One resolved ambiguity worth recording**: Needs Improvement is
checked *before* the Building fallback in the actual evaluation order,
even though it's listed last by severity — Building's condition ("some
history, nothing strong either way") is broad enough that checking it
first would silently swallow every negative-pattern case. Excellent and
Good are still checked before Needs Improvement regardless, so a
sustained positive pattern is never overridden by a negative one — the
same principle in both directions.

**Two negative reasons named as not yet implementable, not silently
dropped**: "very inconsistent logging" and "repeated broken streaks"
would need a new lifetime streak-break counter that doesn't exist in
`behaviorState.logging` — the same "don't invent state to support a
feature" rule already applied twice before (`goalContributionStreak`
in Step 5, two milestone candidates in Step 7).

This is the last of the Behavior Engine's "reasoning" steps — every
remaining step (Scheduler, Diff Generator, wiring, API, UI) is
infrastructure and integration, not new domain logic.

### Behavior Events — not just states

**Decision, frozen: Behavior Engine emits discrete events, not only a
continuously-queryable summary.** A "12-day streak" is a *state*;
"the streak just broke" is an *event* — and Notification Engine needs
the event, not the state, because notifications are naturally triggered
by things *changing*, not by things *being*. Example events:
`HEALTHY_STREAK_EXTENDED`, `HEALTHY_STREAK_BROKEN`,
`LOGGING_STREAK_EXTENDED`, `LOGGING_STREAK_BROKEN`, `RECOVERY_COMPLETED`,
`RECOVERY_FAILED`, `NEW_BEST_STREAK`, `MONTH_FINISHED_UNDER_BUDGET`,
`BACK_ON_TRACK`, `CONSISTENT_LOGGER`.

**Reconciled against Steps 6-7's corrections, found during the Milestone
5 review below**: `FIRST_HEALTHY_WEEK` and `FIRST_GOAL_COMPLETED` are
removed from this list — Step 7 correctly moved both into the Milestone
system (one-time, permanent, `behaviorHistory.milestones[]`), and this
section had gone stale, still listing them as recurring events.
`BEST_STREAK` is renamed `NEW_BEST_STREAK` to match Step 7's
terminology everywhere, not just in the milestone/event split section.
`HEALTHY_STREAK_STARTED`/`LOGGING_STREAK_STARTED` are removed entirely
— the frozen Diff Rules table's `EXTENDED` row already fires on the
0→1 transition, so a separate `STARTED` event would be a second name
for the same fact the Diff Generator already emits, violating "one fact
= one event" the same way a duplicate detector would.

This reframes Phase 5's own eligibility waterfall (5.2) as genuinely
**event-driven**, not state-polling:

```
Behavior Event → Eligible? → Already notified? → Too frequent? →
Correct time? → Create notification
```

The same pattern applies uniformly to every family, not just Behavior:

```
Transaction Detected → Pending Confirmation → Transaction Notification
Health Changed        → Health Event          → Notification Engine
```

— which is exactly why the Event Catalog below is worth freezing across
*all* engines now, not just Behavior's.

---

## Event Catalog (design session — events only, no algorithms, no APIs)

Per the explicit request: list every event first, before any Phase 5
eligibility/priority/frequency logic is designed against them. An event
is something that *just happened* — a transition, never a snapshot —
and every notification in Phase 5 traces back to exactly one of these.

### Financial Events

**Reused directly from `financial_engine.py`'s existing `RecomputeReason`
vocabulary — not a new naming scheme.** These already exist as the
reason codes threaded through every `recompute()` call since Phase 1.5;
Phase 5 treats them as the event stream they already effectively are:

```
TRANSACTION_CREATED     TRANSACTION_CONFIRMED
TRANSACTION_EDITED      TRANSACTION_DELETED
BUDGET_CREATED          BUDGET_UPDATED          BUDGET_DELETED
GOAL_CREATED            GOAL_UPDATED            GOAL_DELETED
INCOME_UPDATED          MONTH_ROLLOVER
```

### Health Events

**New — these are transitions Health Engine's own output doesn't
currently expose** (Overall Health, Phase 3.1, returns the *current*
status only; detecting a *change* requires comparing against the
previous call's result, which is Behavior Engine's job to remember, per
the persistence note above):

```
HEALTH_IMPROVED          HEALTH_WORSENED
RECOVERY_BECAME_IMPOSSIBLE
CATEGORY_BECAME_EXHAUSTED   (per category)
```

### Recommendation Events

```
PRIMARY_RECOMMENDATION_CHANGED
```

**`NEW_RECOMMENDATION_GENERATED` removed here, found during the
Milestone 5 sanity check** — it had no Diff Rule of its own (the frozen
Diff Rules table only ever had one row for this field:
`recommendation.primaryRecommendation.code | any change |
PRIMARY_RECOMMENDATION_CHANGED`) and "a recommendation appeared where
there was none before" is just a `None → SOMETHING` instance of that
same "any change" rule — the identical fix already applied to
`STARTED`/`EXTENDED` above, here for the same underlying reason: two
names for one fact.

### Behavior Events

**Reconciled against Steps 6-7 (Milestone 5 review)**:
`FIRST_HEALTHY_WEEK`/`FIRST_GOAL_COMPLETED` removed (Milestones, not
Events — see 4.5.5); `BEST_STREAK` renamed `NEW_BEST_STREAK`;
`HEALTHY_STREAK_STARTED`/`LOGGING_STREAK_STARTED` removed (redundant
with `EXTENDED`'s 0→1 case, a second name for the same fact);
`LOGGING_STREAK_EXTENDED` added — always belonged here, symmetric with
`HEALTHY_STREAK_EXTENDED`, simply missing from this list before now:

```
HEALTHY_STREAK_EXTENDED      HEALTHY_STREAK_BROKEN
LOGGING_STREAK_EXTENDED      LOGGING_STREAK_BROKEN
RECOVERY_COMPLETED           RECOVERY_FAILED
MILESTONE_UNLOCKED           NEW_BEST_STREAK
BACK_ON_TRACK                CONSISTENT_LOGGER
MONTH_FINISHED_UNDER_BUDGET
```

### `MILESTONE_UNLOCKED` — a producer gap found during the Milestone 5 sanity check, carried forward to Step 9-10

**Found, not resolved here — deliberately deferred, because resolving
it well requires infrastructure design, not Behavior Engine design.**
Every other row in the Diff Rules table is detectable by comparing two
Daily Snapshots' `behavior` field — but that field is frozen (Phase
4.5A) to capture only `behaviorState`'s current counters, never
`behaviorHistory`. A new milestone unlocking is exactly a
`behaviorHistory.milestones[]` append, which the Diff Generator, as
currently designed, cannot see. `MILESTONE_UNLOCKED` therefore has no
working producer today — not "planned but unbuilt" like every other
event above, but genuinely underspecified. Two candidate fixes exist
(extend the Daily Snapshot to also capture a milestone count/latest
code from `behaviorHistory`, or let Behavior Engine emit this one event
directly as a narrow, named exception to "only the Diff Generator
emits") — deciding between them is Step 9/10's job, not Milestone 5's;
named here so it isn't rediscovered as a surprise mid-implementation.

### Not yet catalogued — named as a gap, not silently skipped

Goal Events (Family F, Phase 5.1) and System Events (Family G) were
named as families in the Phase 5.1 design but don't yet have their own
event list — `GOAL_CREATED`/`GOAL_UPDATED`/`GOAL_DELETED` exist as
*Financial* Events (raw data changes) but "goal milestone reached" and
"goal falling behind" are Behavior-Engine-shaped questions that depend
on the same `GOAL_AT_RISK` gap already named twice before (Phase 3.3's
Risk Flags design, Phase 4.0's Goal Protection deferral) — still not
built, still not fabricated here either. System Events (pending
confirmations, sync failures, bank disconnected) are infrastructure
events, not financial reasoning, and are deliberately left for whichever
phase actually owns app infrastructure concerns, not invented here to
complete the table artificially.

**Superseded by implementation — this paragraph originally described
Phase 4.5A as design-only, "implementation follows on separate
confirmation."** That confirmation happened, and Steps 1-8 below are
now built, unit-tested, and real-account-verified, not just designed.
Phase 4.5A froze the Event object shape, the "persist everything, no
ephemeral tier" decision, and the event lifecycle — then, on review,
corrected its own resolution of "who detects a transition": not a
centralized Behavior Engine watching every other engine's output, but a
generic **Daily Snapshot + Diff Generator infrastructure layer**,
neutral and owned by neither Behavior nor any other domain engine, that
diffs consecutive snapshots against a frozen Diff Rules table to produce
Events. Health and Recommendation stay exactly as stateless as already
frozen — the memory that used to be implied for Behavior Engine now
lives only in the snapshot system, not in any engine. Behavior Engine
itself is confirmed as a peer domain engine, computing only its own
streaks/milestones, never anyone else's transitions.

---

## Milestone 5 — Behavior Engine (Frozen)

**Domain reasoning complete.** All eight steps built, tested
(synthetic unit tests + scoped real-account verification against
`botbachat@gmail.com` for every step), and frozen in this spec:

```
Step 1  Behavior State Repository   ✅
Step 2  State Model                 ✅
Step 3  Logging Behavior            ✅
Step 4  Spending Behavior           ✅
Step 5  Saving Behavior             ✅
Step 6  Recovery Behavior           ✅
Step 7  Milestones                  ✅
Step 8  Behavior Summary            ✅
```

**State model frozen.** `behaviorState`/`behaviorHistory` (the third
kind of Ground Truth this spec recognizes, Section 8), narrowed to
records that aren't simple field diffs (milestones, recovery attempts)
— `dailySnapshots` and `events` live in their own neutral,
infrastructure-owned collections, not under Behavior.

**Milestone model frozen.** The "has this ever happened" test cleanly
separates 4 true milestones from 4 recurring events and 2 dropped
candidates with no backing counter (Step 7).

**Event vocabulary reconciled**, not just designed — the Milestone 5
review above found and fixed real drift between the spec's Event
Catalog and what Steps 6-7 actually settled: `FIRST_HEALTHY_WEEK`/
`FIRST_GOAL_COMPLETED` removed (they're Milestones, not Events);
`BEST_STREAK` renamed `NEW_BEST_STREAK` everywhere; the redundant
`*_STARTED` events and `NEW_RECOMMENDATION_GENERATED` removed (each was
a second name for a fact `*_EXTENDED`/`PRIMARY_RECOMMENDATION_CHANGED`
already covered); `LOGGING_STREAK_EXTENDED` added where it had simply
been missing. One genuine open item was found, not resolved here, and
carried forward rather than papered over: `MILESTONE_UNLOCKED` has no
working producer yet, because the Daily Snapshot's `behavior` field
doesn't capture `behaviorHistory` — Step 9/10's job to resolve, named
now so it isn't rediscovered as a surprise mid-build.

**No ownership conflicts** — `behavior_engine.py` imports nothing from
Financial, Metrics, Health, or Recommendation; every fact has exactly
one computing owner. **No duplicate concepts** — the Savings
Pool/Projected Savings/Actual Savings split (Step 5) and the
Milestone/Event split (Step 7) each resolved a real risk of two names
for one idea before it could ship as confusion.

**Remaining work is infrastructure and integration only**: Step 9
(Daily Snapshot Scheduler), Step 10 (Diff Generator), Step 11
(Integration — wiring the still-open call sites named in Steps 3-7),
Step 12 (Behavior API), Step 13 (Flutter UI), Step 14 (Review & Freeze),
then Phase 5 (Notification Engine). None of these introduce new
domain reasoning — per the standing principle: **infrastructure never
invents product logic; it only captures, compares, schedules, or
delivers decisions the domain engines already made.**

### Phase Transition — the guardrail for everything after Milestone 5

**Up to Milestone 5, every phase built domain knowledge. From Step 9
onward, the system shifts to historical infrastructure. No new
financial reasoning, health reasoning, recommendation reasoning, or
behavior reasoning should be introduced from here forward** — Financial,
Metrics, Health, Recommendation, and Behavior are now treated as stable
contracts, not reopened unless implementation uncovers a genuine
architectural flaw (the same standard that justified Phase 2.3a and the
`lastEvaluatedDate`/`openRecoveryEverImpossible` additions — a real gap
found while building, not a preference). Step 9 and everything after it
only captures, compares, schedules, or delivers what these five engines
already decided.

### Snapshot Invariant — frozen before Step 9's code

**A snapshot is a complete, immutable picture of every domain engine at
one moment in time.** Concretely: Financial ✓, Metrics ✓, Health ✓,
Recommendation ✓, Behavior ✓ — every one of them, every time a Daily
Snapshot is written. **No partial snapshots** — not "Behavior wasn't
ready today," not "Recommendation skipped." A snapshot with a missing
engine isn't a smaller snapshot, it's a broken one: the Diff Generator
compares yesterday's snapshot to today's field-by-field, and a missing
field reads as indistinguishable from "this engine had no output," which
would either silently suppress real events or fabricate false ones.
This is the same discipline as Financial Engine's `_load_data()` never
partially loading — a snapshot job either captures every engine's
output for that day, or it doesn't write the snapshot at all.

### `MILESTONE_UNLOCKED` — the first design question Step 9 must settle

Named in the Milestone 5 review, not resolved there on purpose — this
is genuinely Step 9's first decision, not a loose end to patch
retroactively:

- **Option A** — the Daily Snapshot's `behavior` field is extended to
  include milestone data (e.g. a count, or the latest unlocked code),
  so the Diff Generator detects `MILESTONE_UNLOCKED` the same uniform
  way it detects every other transition — comparing two snapshots,
  nothing more.
- **Option B** — Behavior Engine emits the event directly at the moment
  `_check_milestone()` appends a new entry, bypassing the Diff
  Generator for this one case.

**Leaning toward Option A, not yet frozen**: it keeps "the Diff
Generator detects every transition" as a single, universal mechanism
with zero exceptions — milestones are a transition like any other, and
letting Behavior sometimes bypass the Diff Generator would reopen
exactly the "who detects what" ambiguity Phase 4.5A's original
correction was written to close. Frozen as Step 9's opening question,
not before.

---

## Era 2 Engineering Principles — frozen before Step 9

**Era 1's design rules were product philosophy: one question per
engine, reuse over reinvention, never duplicate a calculation.** Era 2
needs its own set, because infrastructure is judged by a different
standard — not "is the business logic correct" (Era 1 already answered
that), but **"does this behave correctly when something goes wrong."**
Every domain-engine gap this project ever found and fixed
(`lastEvaluatedDate`, `openRecoveryEverImpossible`, the milestone/event
split) was caught by asking "what does this mean" one level deeper.
Era 2's gaps will be caught by asking "what happens when this fails"
one level deeper instead — the same discipline, aimed at a different
question.

**The process, extended for infrastructure — one added stage, one
renamed:**

```
Question → Philosophy → Design → Freeze → Implement →
Failure Tests → Real Account Verification → Review → Freeze
```

"Unit Tests" becomes **Failure Tests**: not "does the scheduler run,"
but does it behave correctly run twice, mid-crash, after a skipped day,
offline, or against a rejected write. A passing happy-path test proves
almost nothing for infrastructure — the failure path is the actual
spec.

**The six principles, frozen, the Era 2 equivalent of Era 1's "one
question per engine":**

1. **Infrastructure never creates business truth.** A snapshot,
   event, or scheduler run may only ever *report* a fact a domain
   engine already established — never compute, adjust, or infer one of
   its own. The moment infrastructure code contains a threshold, a
   formula, or a business rule, it has quietly become a sixth engine
   with no name and no owner.
2. **Infrastructure must be idempotent.** Running the same operation
   twice — deliberately, or because a retry fired after a crash —
   produces exactly the same end state as running it once. This is
   already frozen for the Diff Generator (Phase 4.5A's event
   idempotency guarantee via deterministic `eventId`s); every future
   infrastructure component inherits the same bar.
3. **Infrastructure must be resumable after failure.** A crash mid-run
   is not a special case requiring manual cleanup — the next run picks
   up correctly from whatever state was actually persisted, not from
   an assumption that the previous run either fully succeeded or fully
   failed.
4. **Infrastructure must be observable.** Every scheduled run, every
   snapshot, every generated event carries enough of its own metadata
   (timestamps, versions, what triggered it) to answer "why did this
   happen" without guessing — the same traceability principle that
   gave every domain engine its own decision trace, applied here to
   infrastructure runs instead of business decisions.
5. **Infrastructure failures must degrade gracefully, never corrupt
   state.** A failed scheduler run should be visibly, honestly absent
   — never a partial write masquerading as a complete one (the
   Snapshot Invariant above is this principle applied to one specific
   case). Missing data is recoverable; corrupted data that looks valid
   is not.
6. **Historical records are append-only unless an explicit migration
   is performed.** `dailySnapshots`, `events`, and `behaviorHistory` are
   never silently rewritten in place — the rebuild policy already
   frozen for snapshots (Phase 4.5A) extends to every historical
   collection Era 2 introduces.

**These six principles are the acceptance bar for Steps 9 through 14** —
each infrastructure component's Review & Freeze should check itself
against all six explicitly, the same way each domain engine's freeze
checked itself against Era 1's design rules.

---

# Era 2 — Historical Infrastructure

**Mission.** Era 1 answered "what does the system know?" Era 2 answers
"how does the system remember what it knew yesterday?" Every design
decision from here on traces back to that single question — not to a
scheduler, not to a timing concern, until the concept itself is fully
defined.

## Step 9.0 — Daily Snapshot Philosophy

**One question, and only one, for this step**: *"What is a Daily
Snapshot?"* Not when it's created, not who creates it, not how often —
those belong to whichever caller eventually invokes it (the scheduler
among others), and are deliberately deferred past this step, the same
way Era 1 always separated "what is true" from "who asked."

### Five rules, frozen

1. **A snapshot is historical fact, not current state.** It is the
   complete state of the system on one specific calendar day. Once
   written, it is a record of that day forever — never updated to
   reflect what's true *now*.
2. **A snapshot contains no reasoning.** It copies; it never
   calculates. Every value inside it already exists, computed by
   whichever domain engine owns it — `financialSummary` is copied from
   Financial Engine's output, never recomputed from raw transactions
   inside the snapshot job itself. The moment a snapshot calculates
   anything, it has quietly become an undeclared sixth engine.
3. **Complete or nothing** — the Snapshot Invariant, already frozen
   above: Financial ✓, Metrics ✓, Health ✓, Recommendation ✓,
   Behavior ✓, every one, every time, or no snapshot is written at all.
   Never a partial snapshot with one engine missing.
4. **Versioned forever.** Every snapshot carries
   `financialVersion`/`metricsVersion`/`healthVersion`/
   `recommendationVersion`/`behaviorVersion`, plus its own
   `snapshotVersion` — so any future reader knows exactly which
   formulas produced that day's numbers, never having to guess whether
   a rule changed since.
5. **Immutable.** After `dailySnapshots/{date}` is written, it is never
   merged, patched, or overwritten — only ever read, or (per the
   already-frozen rebuild policy) rebuilt as an explicitly new,
   separately labeled record, never a silent replacement of the
   original.

### Formal definition, frozen

**A Daily Snapshot is a complete, immutable, versioned record of every
domain engine's outputs for one user on one calendar day.**

Notice deliberately what this definition does *not* mention: no
scheduler, no cron, no notifications, no events. Those are consumers of
a snapshot, or callers of the function that creates one — neither
belongs in the definition of what a snapshot *is*.

### Ownership, frozen

```
Financial Engine        owns financialSummary
Metrics Engine           owns metrics
Health Engine            owns health
Recommendation Engine    owns recommendations
Behavior Engine          owns behavior
Daily Snapshot           owns nothing — it only assembles
```

This is the same single-owner discipline every domain engine collection
has followed since Section 8, extended to infrastructure: the snapshot
mechanism has no domain of its own to reason about, which is exactly
what keeps it infrastructure rather than a sixth engine in disguise.

### The open question: should a snapshot contain milestones?

**Not decided here, on purpose** — this is Step 9.1's first question,
once the schema itself is on the table, not something to force a
decision on while still defining what a snapshot conceptually is.

- **Option A** — the snapshot includes milestone data alongside
  `behavior`. One transition detector (the Diff Generator) sees
  everything, including a new milestone appearing; `MILESTONE_UNLOCKED`
  falls out of the same uniform comparison every other event already
  uses.
- **Option B** — the snapshot stays behavior-state-only; Behavior
  Engine emits milestone events directly, bypassing the Diff Generator
  for this one case. Smaller snapshot, but a second change-detection
  mechanism now exists alongside the first.

**Leaning toward Option A, still not frozen**: it preserves "one place
detects change" with zero exceptions, which is the same principle that
justified Phase 4.5A's original correction away from Behavior Engine
detecting its own cross-engine transitions. Frozen only once Step 9.1
examines the actual schema in detail — not before.

### Step 9.0 — FROZEN (philosophy only; schema deferred to Step 9.1)

Nothing implemented, nothing scheduled, no timing decided. Frozen here:
the five rules, the formal definition, the ownership table, and the
open (leaning-A) milestone question. Step 9.1 — Snapshot Schema —
builds the actual document shape on top of this philosophy, reconciling
it with the preliminary field sketch already drafted in Phase 4.5A
("Daily Snapshot — field shape, frozen," above) rather than starting
from nothing.

## Step 9.1 — Snapshot Schema

**One question**: *what must be stored so that tomorrow can understand
what happened today?* Not what the UI needs, not what Notifications
need, not what analytics might someday want — only what must survive
into history.

### Rule 6 — Snapshot fields are contracts, not convenience, frozen

Every field must satisfy exactly one of three reasons to exist:

- **Type A — Domain Output.** Produced by exactly one engine
  (`financialSummary`, `metrics`, `overallHealth`, `behaviorSummary`).
- **Type B — Metadata.** Lets the snapshot be interpreted at all
  (`snapshotVersion`, `generatedAt`, `snapshotDate`).
- **Type C — Traceability.** Lets a future reader explain *why* history
  looks the way it does (`healthEngineVersion`, `metricsEngineVersion`,
  ...).

A field belonging to none of these three doesn't go in the snapshot,
full stop.

### Rule 7 — No raw data, frozen

Snapshots never contain transactions, budgets, goals, categories, or
any queue (notification, event). Anything reconstructable from its own
source-of-truth collection stays there — a snapshot that duplicated raw
data would be a backup, not a historical observation.

### Compression Principle, frozen

**A snapshot records conclusions, not working memory.** Financial
Engine's full internal working set (income, budgets, goals,
transactions, the whole calculation) is not what gets copied — only
`financialSummary`, the conclusion. The same discipline applies to
every engine's output, not just Financial's.

### Historical Principle, frozen

For every candidate field, ask exactly one question: **if this
disappeared from Firestore tomorrow, would history lose meaning?** If
yes, keep it. If no — it's reconstructable elsewhere, and copying it
would only be duplication wearing the shape of a feature.

### Rule 8 — Snapshots do not compete with Ground Truth, frozen

**Related to Rule 7, not identical to it.** Rule 7 says don't store raw
data (transactions, budgets, goals — things that were never a
conclusion to begin with). Rule 8 is narrower and was only visible
after resolving the milestone question above: **if a Ground Truth
already exists permanently elsewhere, the snapshot references that
history indirectly, by time — it never copies it.**

```
✅ Snapshot stores Behavior Summary
   — tomorrow's summary may differ, and today's disappears the moment
     it's superseded; the snapshot is the only place today's version
     survives.

❌ Snapshot stores behaviorHistory.milestones
   — already append-only, permanent history; copying it wouldn't
     preserve anything that would otherwise be lost.
```

This is the rule the milestone resolution (Option C) was actually
applying, made explicit as its own principle now that Step 9.1 has
surfaced it: a snapshot's job is to be the *only* record of things that
would otherwise vanish (today's Behavior Summary, today's streak
counters) — never a second copy of something that already has a
permanent home of its own.

### The milestone question, resolved — not Option A, not Option B

Applying the Historical Principle directly to the candidate milestone
field settles this more precisely than either original option did.
`behaviorHistory.milestones[]` (frozen since Step 7) is already a
permanent, immutable, timestamped Ground Truth — filtering it by
`unlockedAt <= date` reconstructs "how many/which milestones existed as
of day X" *exactly*, with no drift, unlike Financial or Health data
(whose live recomputation can legitimately disagree with history once
formulas change — the rebuild policy's whole justification). A
milestone count or latest-code field in the snapshot would therefore
fail Rule 7: reconstructable from a source-of-truth collection that
already exists, contributing nothing history would actually lose.

**Decision, frozen: Option C.** The snapshot's `behavior` field carries
no milestone data at all. The Diff Generator, when detecting
`MILESTONE_UNLOCKED`, reads `behaviorHistory.milestones[]` directly
(filtered to the relevant date) as a **third input** alongside the two
snapshots it already compares — not because Behavior Engine self-reports
(that would reopen the exact mistake Phase 4.5A's original correction
fixed), but because the permanent record the Diff Generator needs
already exists, undiminished by never being copied. "One place detects
change" survives completely intact; "don't duplicate a Ground Truth"
also survives — neither Option A nor B, as originally framed, satisfied
both at once.

**The same reasoning technically extends to Recovery's
`totalResolved`/`totalFailed`** (also reconstructable, in principle, by
filtering `behaviorHistory.recoveryAttempts[]`), **noted but not
reopened here** — those fields are already implemented, tested, and
wired into a frozen Diff Rule (Step 6); revisiting them now would be
scope creep beyond a schema design session, not a response to a
demonstrated flaw. Worth a look during Step 14's Review & Freeze, not
before.

### What `behavior` actually is — the question requiring the most care, resolved

Behavior Summary and Behavior State get opposite treatment, for a
principled reason, not a preference:

- **Behavior *State* (raw counters) — included.** `logging.currentStreak`/
  `bestStreak`, `spending.currentHealthyStreak`/
  `currentOverspendingStreak`, `saving.currentProtectionStreak`,
  `recovery.currentStreak`/`totalResolved`/`totalFailed` — these have
  **no independent historical record anywhere else**.
  `streakTransitions[]` was deliberately removed from `behaviorHistory`
  during Phase 4.5A's correction ("a streak extending or breaking *is*
  an Event now"), so the Daily Snapshot is the *only* place a past
  day's streak value survives. Passes the Historical Principle
  trivially — if this disappeared, that day's streak value would be
  gone forever.
- **Behavior *Summary* (the computed interpretation) — included, same
  tier as `overallHealth`.** `compute_behavior_summary()`'s status
  depends on which `recoveryAttempts` entry was "most recent" *as of
  that day* — recomputing it later from today's full history can
  silently answer a different, wrong question for a past day, the same
  "formulas and inputs can drift" problem Financial and Health already
  have. Not reconstructable; belongs in the snapshot.
- **`behaviorHistory`'s arrays (`milestones[]`, `recoveryAttempts[]`) —
  excluded**, per the milestone resolution above; they're already their
  own permanent record, read directly by whatever needs them, never
  duplicated into a daily snapshot.

### Owner Audit — every field, frozen

| Field | Owner | Type | Keep? |
|---|---|---|---|
| `snapshotDate` | Snapshot infrastructure | B | ✓ |
| `generatedAt` | Snapshot infrastructure | B | ✓ |
| `snapshotVersion` | Snapshot infrastructure | B | ✓ |
| `versions.financial/metrics/health/recommendation/behavior` | each respective engine | C | ✓ |
| `financial.income/totalSpent/remainingBudget/savingsPool` | Financial Engine | A | ✓ |
| `metrics.spendingPaceStatus/recommendedDailySpendValue` | Metrics Engine | A | ✓ |
| `metrics.recoveryPlanPresent/recoveryPossible` | Metrics Engine | A | ✓ (needed for `RECOVERY_BECAME_IMPOSSIBLE`) |
| `health.overallHealthStatus` | Health Engine | A | ✓ |
| `health.categoryHealth[cat].status` | Health Engine | A | ✓ (needed for `CATEGORY_BECAME_EXHAUSTED`) |
| `recommendation.primaryRecommendationCode` | Recommendation Engine | A | ✓ |
| `behavior.state.logging/spending/saving/recovery` | Behavior Engine | A | ✓ |
| `behavior.summary.status/primaryReason/confidence` | Behavior Engine | A | ✓ |
| `behavior.milestones` / `behavior.milestoneCount` | *nobody — already owned by `behaviorHistory`* | — | ❌ dropped, see resolution above |
| `currentMonth` (candidate, never actually proposed here but named as the audit's own worked example) | nobody — `snapshotDate` already answers it | — | ❌ (the audit's own test case) |

### Complete snapshot schema, frozen

```
users/{uid}/dailySnapshots/{date}
├── snapshotDate
├── generatedAt
├── snapshotVersion
├── versions
│   ├── financial
│   ├── metrics
│   ├── health
│   ├── recommendation
│   └── behavior
├── financial
│   ├── income
│   ├── totalSpent
│   ├── remainingBudget
│   └── savingsPool
├── metrics
│   ├── spendingPaceStatus
│   ├── recommendedDailySpendValue
│   ├── recoveryPlanPresent
│   └── recoveryPossible        (only meaningful if recoveryPlanPresent)
├── health
│   ├── overallHealthStatus
│   └── categoryHealth[cat].status
├── recommendation
│   └── primaryRecommendationCode
└── behavior
    ├── state
    │   ├── logging     { currentStreak, bestStreak }
    │   ├── spending    { currentHealthyStreak, currentOverspendingStreak }
    │   ├── saving       { currentProtectionStreak }
    │   └── recovery     { currentStreak, totalResolved, totalFailed }
    └── summary
        ├── status
        ├── primaryReason
        └── confidence
```

### Step 9.1 — FROZEN

Rule 6, Rule 7, Rule 8, the Compression Principle, the Historical
Principle, the complete field-by-field Owner Audit, and the milestone
decision (Option C, not A or B) are all frozen above. Nothing
implemented — Step 9.2 asks how one snapshot is actually created
(`create_daily_snapshot(date)`, per the engine-owns-logic/
caller-owns-timing separation already agreed), still without mentioning
a scheduler.

## Step 9.2 — How a Snapshot Comes Into Existence

**One question**: *how does a complete snapshot come into existence?*
Not when, not how often, not by whom — `create_daily_snapshot(db, uid,
date)` is a plain function, callable by a scheduler, a manual admin
rebuild, or an integration test equally, none of them privileged. Its
responsibilities, guarantees, failure behavior, atomicity, and output —
nothing else.

### Responsibilities, frozen

In order, and only these:

1. **Gather** — call each domain engine's existing public read
   function once: Financial's `get_summary`, Metrics' `get_metrics`,
   Health's `compute_overall_health`, Recommendation's
   `compute_recommendations`, Behavior's `compute_behavior_summary` (plus
   `behavior_state_repository.load_state` for the raw counters, per
   Step 9.1's schema). **No new computation** — every value comes from a
   function that already exists and is already called elsewhere; the
   snapshot creator reuses them exactly as a route would.
2. **Stamp** — attach each engine's current version constant plus
   `SNAPSHOT_VERSION`, `snapshotDate`, `generatedAt`.
3. **Verify completeness** — the Snapshot Invariant, checked explicitly
   against the gathered dict, not assumed from "nothing raised an
   exception" (see below).
4. **Write** — exactly once, atomically, or not at all.

### Guarantees, frozen

- **Idempotent per date, per Rule 5.** If `dailySnapshots/{date}`
  already exists, `create_daily_snapshot()` is a no-op — it never
  overwrites, merges, or patches an existing snapshot. This is the same
  "check existence, skip if present" idempotency every
  `record_*_activity()` function already relies on, applied here to a
  document instead of a per-day streak field.
- **All-or-nothing.** Either the fully assembled, fully verified
  snapshot is written, or nothing is written for that date at all.
  There is no code path that produces a partial document.

### Failure behavior, frozen — a principle this step surfaced on its own

**"No exception was raised" is not the same claim as "the data is
complete," and treating them as equivalent would be the exact gap this
step exists to close.** A domain engine's read function can return
`None` or an empty result for a legitimate reason — no exception,
technically a successful call, but not something the Snapshot Invariant
can accept. Concretely: `create_daily_snapshot()` must check the
*gathered dict itself* for every required field being present and
non-`None`, never infer completeness from the absence of a thrown
error. If any required piece is missing — whether because a call
raised, or because it quietly returned nothing — the function raises
or returns a clear failure signal, and **writes nothing**. Per the Era 2
principle "failures must degrade gracefully rather than corrupt state,"
an absent snapshot is a visible, honest gap; a snapshot silently missing
one engine's data would be corruption wearing a valid-looking shape.

### Atomicity, frozen — the second thing this step surfaced

**Atomicity applies to the write, not the five reads that feed it, and
that distinction is deliberate, not an oversight.** Because the entire
snapshot is *one Firestore document*, the final `.set()` call is atomic
by Firestore's own single-document guarantee — there is no
partially-written document possible, no transaction needed to make the
write itself safe. But the five gather calls (Financial, Metrics,
Health, Recommendation, Behavior) are independent, sequential reads,
not wrapped in a cross-collection transaction — so in principle, a
transaction could land on the user's data in the few hundred
milliseconds between reading Financial's summary and reading Behavior's
state, and the snapshot would reflect two slightly different instants,
not one perfectly frozen moment. **This is accepted, not engineered
away**: a Daily Snapshot's granularity is a calendar day, not a
microsecond, and paying for cross-engine read consistency (wrapping five
independent service modules' reads in one Firestore transaction) would
be real complexity spent on a precision this system never actually
needs at daily granularity. Named explicitly so a future reader doesn't
mistake "the write is atomic" for "the whole snapshot was captured at
one exact instant" — it wasn't, and doesn't need to have been.

### Output, frozen

`create_daily_snapshot(db, uid, date)` returns the exact snapshot dict
it wrote (or `None`/raises on the no-op/failure paths above) — useful
for the caller to log, assert against in a test, or hand to whatever
invokes it next, without a second read back from Firestore.

### Rule 9 — Snapshot creation is deterministic, frozen

**Given the same engine outputs and the same date, `create_daily_snapshot()`
must produce the exact same document.** No randomness, no UUIDs, no
iteration-order dependence, and no timestamp inside the payload except
`generatedAt` itself. This is what makes the builder trivially
unit-testable (same inputs always assert to the same output), makes a
rerun before the real write harmless, and is a prerequisite for any
future replay tooling — none of which would be possible if two runs of
the same day, against the same underlying data, could produce two
different documents.

### Step 9.2 — FROZEN

Responsibilities, guarantees, failure behavior (the
exception-vs-completeness distinction), atomicity (the
write-vs-read distinction), and determinism (Rule 9) are all frozen
above. Design has reached diminishing returns — everything remaining is
implementation detail, not an open conceptual question. Moving straight
to Step 9.3 — Snapshot Builder (Implementation) — no further design
step first.

## Step 9.3 — Snapshot Builder — FROZEN

Implemented in `services/snapshot_service.py`,
`create_daily_snapshot(db, uid, date, generated_at=None)`, exactly
against the five acceptance criteria: gathers only the five domain
engines' existing public functions (`_gather`), validates completeness
against the data itself, not exception absence (`_is_complete`), builds
the snapshot as pure assembly with no calculation (`_build_snapshot`),
writes with a single `.set()` call, and returns the exact snapshot
written. `dailySnapshots/{date}` lives at
`users/{uid}/dailySnapshots/{date}`, per the path already frozen in
Phase 4.5A.

All 20 unit test scenarios pass (`tests/test_snapshot_service.py`,
synthetic gathered data — no Firestore needed for `_is_complete`/
`_build_snapshot`, since neither touches it): every required key's
absence fails completeness even with no exception involved,
`categoryHealth` having no categories yet doesn't falsely fail
completeness, the built schema matches Step 9.1's shape field-for-field,
determinism (Rule 9) holds across two builds from identical inputs, and
no milestone data appears anywhere (Option C, honored in the actual
code, not just the spec). The full end-to-end path — actually calling
all five engines against real data — was verified against
`botbachat@gmail.com`: a first call gathered and wrote a real snapshot
reflecting that account's actual financial/health/behavior state, a
second call for the same date returned the identical existing document
unchanged (idempotency, Rule 5), and the test snapshot document was
deleted afterward since it was verification pollution, not a real
historical fact worth keeping.

**Nothing beyond `create_daily_snapshot()` exists yet** — no scheduler,
no Diff Generator, no caller at all in production. Per the
engine-owns-logic/caller-owns-timing separation agreed before this
step, that's by design: this function is now a stable, independently
callable, independently tested artifact, ready for whatever invokes it
next (Step 10's Diff Generator needs two of its outputs; a future
scheduler needs to call it once daily; a future admin rebuild tool needs
to call it on demand) — none of which required touching this file to
enable.

## Step 10.0 — Diff Generator Philosophy

**One question, frozen**: *"What meaningful changes occurred between
two historical snapshots?"* Not what notifications should be sent, not
what changed in the database, not what the UI should display, not what
action the user should take — those are all consumers, downstream of
this component, and belong to Phase 5 or later. The Diff Generator only
identifies historical transitions.

### Five rules, frozen

1. **Compare history, never recompute.** The Diff Generator never
   calls Financial, Metrics, Health, Recommendation, or Behavior Engine
   directly. Its only inputs are historical records already written:
   yesterday's snapshot, today's snapshot, and (per Step 9.1's Option C
   resolution) `behaviorHistory.milestones[]`. Every event comes from
   comparing records that already exist — never a fresh computation.
2. **Events represent transitions, not states.** `HEALTH_CHANGED` is a
   valid event; `HEALTH_IS_RED` is not an event at all — it's a
   snapshot field. If a candidate event describes what something *is*
   rather than what just *changed*, it belongs in the snapshot schema,
   not the event stream.
3. **No transition, no event.** If yesterday's and today's relevant
   fields are identical, zero events are produced for that field. The
   Diff Generator never emits a "heartbeat" or "still healthy" event —
   silence is the correct output when nothing changed.
4. **One transition produces exactly one event.** The same "one fact =
   one event" discipline already learned the hard way twice — once
   correcting `NEW_RECOMMENDATION_GENERATED`/
   `PRIMARY_RECOMMENDATION_CHANGED` into a single event, once correcting
   `*_STARTED`/`*_EXTENDED` into a single event (Milestone 5's review) —
   is made an explicit rule here rather than something re-discovered a
   third time.
5. **The Diff Generator classifies; it never decides importance.** Its
   output is a flat list of events — nothing more. It never asks "should
   the user be notified," "is this urgent," or "should this wait until
   morning." Event ordering, notification priority, batching,
   suppression, and cooldowns all belong to the Notification Engine
   (Phase 5) — if the Diff Generator starts reasoning about which event
   matters most, it has already drifted into that layer's job.

### Acceptance test, frozen, to be kept in mind throughout Step 10

**If the Notification Engine didn't exist, would the Diff Generator
still be valuable?** The answer must be yes — the same event stream
could drive analytics, an achievement timeline, an activity history,
monthly reports, exports, or debugging, with no notification system
involved at all. That independence is the same architectural property
every domain engine and Snapshot Builder have already maintained;
Step 10 extends it one layer further.

### Step 10.0 — FROZEN

The one question, the five rules, and the acceptance test are frozen
above. Nothing about comparison logic, event schemas, or field-by-field
diff rules has been decided yet — those are Step 10.1's job.

**Step 10's own sub-structure, frozen, mirroring Phase 4's
Philosophy/Matrix separation**:

```
10.0 Philosophy         (done — the one question, five rules, acceptance test)
10.1 Difference Rules    (what qualifies as a change, before which ones matter)
10.2 Diff Matrix         (the frozen field -> transition -> event table)
10.3 Generator Pipeline  (the actual comparison function)
10.4 Review
Implementation
```

The Diff Matrix (10.2) is this step's equivalent of the Recommendation
Matrix (Phase 4) — a frozen source of truth implementation simply
executes, never a place where philosophy and code get mixed together.

## Step 10.1 — What is a Difference?

**Deliberately not "Diff Rules" yet** — before deciding *which* changes
matter, this step defines what qualifies as a change *at all*.

### Rule 6 — Compare only owned fields, frozen

The Diff Generator compares only the fields each engine actually owns:
`financial`, `metrics`, `health`, `recommendation`, `behavior`. It never
compares `generatedAt`, `snapshotVersion`, any engine version, or any
other metadata field — those changing, by construction, every single
day, must never produce an event.

### Rule 7 — Equality is structural, frozen

Two values are equal if they are structurally identical, regardless of
Firestore's key ordering. `{"status": "green", "confidence": "high"}`
equals `{"confidence": "high", "status": "green"}` — comparison is
never sensitive to serialization order, only to actual content.

### Rule 8 — Compare values, not documents, frozen

The Diff Generator never says "the snapshot changed" — it says
"`health.overallHealthStatus` changed." Comparison happens at the
individual field level, never at the whole-document level, so adding
an unrelated field to the snapshot in the future can never be mistaken
for every field having changed.

### Rule 9 — Every event maps to exactly one field transition, frozen

Never many fields collapsing into one ambiguous event. Always:
`field → transition → event` — for example,
`health.overallHealthStatus: green → amber → HEALTH_WORSENED`. Fully
traceable, in both directions: given an event, its triggering field and
transition are always identifiable; given a field's transition, its
resulting event (if any) is always identifiable.

### Rule 10 — Unknown changes produce nothing, frozen

**If a field changes and no Diff Rule owns it, the Diff Generator emits
nothing — never guesses, never infers, never invents a plausible-sounding
event.** This is what makes adding a new snapshot field completely safe:
`financial.xyz` can be added tomorrow, and until a Diff Rule explicitly
claims it, its changing produces silence, never a fabricated event.

### Step 10.1 — FROZEN

Rules 6-10 are frozen above — what qualifies as a comparable field, what
counts as equal, what granularity comparison happens at, the one-field-
one-event mapping, and the "unknown means silence" safety net. No
specific field has been assigned an event yet; that's Step 10.2's job,
and per Rule 10, it now has a genuine safety net to fall back on if it
misses one.

## Step 10.2 — Diff Matrix

**This step's equivalent of the Recommendation Matrix (Phase 4) — the
frozen source of truth implementation simply executes.** Every row
answers five questions: which engine owns the field, which field,
which transition, which event, and which input actually detects it
(`Producer`) — so "why isn't this event firing" always has an immediate,
traceable answer.

### Financial — zero rows, on principle, not by omission

Financial's events already exist through a completely different
mechanism — the `RecomputeReason` vocabulary (Financial Events, Event
Catalog), triggered live by user actions the instant they happen, never
detected by comparing two snapshots. There is nothing left for the Diff
Matrix to add here; a row would be a second detector for a fact that
already has one.

### Metrics — two rows, deliberately few

Metrics are measurements, not milestones — a `recommendedDailySpend`
value moving from 82 to 83 is not an event, and `spendingPaceStatus`
changing isn't diffed here either, since Health's own status transition
already reflects its meaningfulness downstream; a separate Metrics-level
event would be a second detector for the same underlying signal.

| Owner | Field | Transition | Event | Producer |
|---|---|---|---|---|
| Metrics | `recoveryPlanPresent` | `false → true` | `RECOVERY_STARTED` | Snapshot |
| Metrics | `recoveryPossible` | `true → false` | `RECOVERY_BECAME_IMPOSSIBLE` | Snapshot |

### Health — the largest source of genuine transitions

| Owner | Field | Transition | Event | Producer |
|---|---|---|---|---|
| Health | `overallHealthStatus` | moves to a worse status (`green→amber`, `green→red`, `amber→red`) | `HEALTH_WORSENED` | Snapshot |
| Health | `overallHealthStatus` | moves to a better status (`amber→green`, `red→green`, `red→amber`) | `HEALTH_IMPROVED` | Snapshot |
| Health | `categoryHealth[cat]` | `→ red` | `CATEGORY_BECAME_EXHAUSTED` | Snapshot |

### Recommendation — one field matters

| Owner | Field | Transition | Event | Producer |
|---|---|---|---|---|
| Recommendation | `primaryRecommendationCode` | any change | `PRIMARY_RECOMMENDATION_CHANGED` | Snapshot |

### Behavior — the richest section

| Owner | Field | Transition | Event | Producer |
|---|---|---|---|---|
| Behavior | `logging.currentStreak` | `N → N+1` (covers `0→1`, no separate `STARTED`) | `LOGGING_STREAK_EXTENDED` | Snapshot |
| Behavior | `logging.currentStreak` | `N>0 → 0` | `LOGGING_STREAK_BROKEN` | Snapshot |
| Behavior | `spending.currentHealthyStreak` | `N → N+1` | `HEALTHY_STREAK_EXTENDED` | Snapshot |
| Behavior | `spending.currentHealthyStreak` | `N>0 → 0` | `HEALTHY_STREAK_BROKEN` | Snapshot |
| Behavior | `saving.currentProtectionStreak` | `N → N+1` | `SAVING_STREAK_EXTENDED` | Snapshot |
| Behavior | `saving.currentProtectionStreak` | `N>0 → 0` | `SAVING_STREAK_BROKEN` | Snapshot |
| Behavior | `recovery.totalResolved` | `N → N+1` | `RECOVERY_COMPLETED` | Snapshot |
| Behavior | `recovery.totalFailed` | `N → N+1` | `RECOVERY_FAILED` | Snapshot |

**`SAVING_STREAK_EXTENDED`/`BROKEN` are new, found while building this
table** — Saving Behavior (Step 5) never had a diff-detectable event at
all before now, an oversight in the original Phase 4.5A sketch, not a
deliberate omission; added here for the same reason Logging and
Spending already have theirs.

### Milestones — the one row with a non-snapshot producer

| Owner | Field | Transition | Event | Producer |
|---|---|---|---|---|
| *(none — `behaviorHistory`, not a snapshot field)* | `milestones[]` | a new entry appears since yesterday | `MILESTONE_UNLOCKED` | Milestone History |

This is the one place Option C (Step 9.1) actually shows up in the
matrix: the Producer column, not the Owner column, is where "milestone
history is a third input" becomes concrete.

**Resolved explicitly, since it's easy to get backwards**: a healthy
streak crossing from 6 to 7 fires `HEALTHY_STREAK_EXTENDED` (Snapshot,
same as every other extension) *and*, independently, `FIRST_HEALTHY_WEEK`
may unlock the same day (Milestone History) — these are not duplicates
of one another. They answer different questions (a routine extension
vs. a permanent one-time achievement) that happen to share a threshold;
neither suppresses the other.

### Rule 11 — Every event has exactly one row, frozen

Never `Green→Amber` mapped to both `HEALTH_CHANGED` and
`HEALTH_DEGRADED` in two separate rows. One transition, one row, one
event — the same discipline as Rule 4/Rule 9, restated here as a
structural property of the table itself: every row above is checked to
have a transition no other row also claims.

### Step 10.2 — FROZEN

The complete Diff Matrix — 0 Financial rows, 2 Metrics rows, 3 Health
rows, 1 Recommendation row, 8 Behavior rows, 1 Milestone row — is frozen
above, each row traceable to exactly one owner, one field, one
transition, and one producer. Step 10.3 — Generator Pipeline — builds
the actual comparison function that executes this table; nothing about
*how* the comparison runs has been decided yet.

## Step 10.3 — Generator Pipeline

**One question**: *given two snapshots and the frozen Diff Matrix,
which events should be produced?* Not "which events should exist" —
Step 10.2 already answered that. The generator only evaluates the
matrix; it never decides what belongs in it.

### Rule 12 — The generator iterates over the Diff Matrix, not over the snapshots, frozen

**Bad**: for every snapshot field, figure out what event it implies.
**Good**: for every Diff Matrix row, ask whether its transition
occurred; if yes, emit its event. This makes adding a new event a
one-row addition to the matrix, never a rewrite of comparison logic —
the same property that made the Recommendation Matrix maintainable.

### No ordering inside the generator, frozen

Events are returned in Diff Matrix row order, exactly as frozen — no
sorting, no severity, no priority, no timestamp beyond what an event
already carries. Whether event C matters more than event A is
Notification Engine's decision (Phase 5), never the generator's.

### Pipeline, frozen — seven stages, mirroring Overall Health's architecture

```
generate_events(uid, yesterday_snapshot, today_snapshot, milestones_today)
        |
        v
_load_inputs()        -- exactly three things: yesterday snapshot,
                          today snapshot, behaviorHistory.milestones
                          (already filtered to today by the caller)
        |
        v
_validate_inputs()     -- infrastructure concerns only: both snapshots
                          exist, today's date is strictly after
                          yesterday's, snapshotVersion is supported
        |
        v
_compare_fields()      -- (field, yesterday_value, today_value) tuples
                          for every Diff Matrix row -- differences only,
                          no events yet
        |
        v
_match_matrix_rows()   -- keep only the tuples whose row's transition
                          condition is actually met; Rule 10 discards
                          the rest silently
        |
        v
_build_events()        -- structured events only: diffRuleId, event
                          code, payload -- no wording, no priority,
                          no cooldowns
        |
        v
_assign_ids()          -- deterministic eventId per Phase 4.5A's
                          idempotency guarantee: (uid, snapshotDate,
                          diffRuleId), same every run
        |
        v
return events          -- persistence is someone else's job
```

**One refinement to the idempotency guarantee's original wording,
found while implementing**: `(uid, snapshotDate, diffRuleId)` alone
collides for the two rows that can fire more than once per day —
`CATEGORY_BECAME_EXHAUSTED` (one per category) and `MILESTONE_UNLOCKED`
(one per milestone). Both need a fourth component (the category name,
or the milestone code) appended to stay unique. Every other row is a
single scalar field, so `diffRuleId` alone is already sufficient there.

### Validation scope, frozen — narrower than "consecutive dates"

**"Consecutive dates" was named as a validation concern, but strict
adjacency is not actually enforced** — only strict *ordering*
(`today.snapshotDate > yesterday.snapshotDate`) is. A multi-day gap
(a missed snapshot) is not a caller error; it's the same accepted,
bounded imprecision already frozen for Step 9.2's read-consistency
decision. The generator still produces whatever the matrix matches
across that gap — an increase-based transition like
`LOGGING_STREAK_EXTENDED` still fires correctly even if it silently
undercounts how many days passed, which is consistent with "coarse
historical observation, not audit log." Rejecting *equal or reversed*
dates catches a genuine caller bug (the same snapshot passed twice, or
passed in the wrong order); rejecting a *gap* would be inventing a
business judgment the generator has no business making.

**"Same user" cannot actually be independently verified from the
inputs given** — both snapshot dicts carry no `uid` field of their own
(per the frozen schema, the user is implicit in the Firestore path they
were read from). This is satisfied by construction: whoever fetches
both snapshots is responsible for fetching them from one user's
subcollection. Named honestly rather than pretending to validate
something the function's actual inputs make unvalidatable.

### Step 10.3 — FROZEN

The seven-stage pipeline, Rule 12, the no-ordering rule, the eventId
refinement, and the narrowed validation scope are frozen above. Nothing
about persistence, storage collection, or a caller has been decided —
per the caller-owns-storage separation, `generate_events()` returns its
list and stops.

**Implemented** in `services/diff_generator.py`,
`generate_events(uid, yesterday_snapshot, today_snapshot,
milestones_today=None)` — the Diff Matrix encoded as data (a list of
row dicts with `id`/`field`/`transition`/`event`), with the generator
iterating over that table exactly per Rule 12, never over the
snapshots' own fields. All 21 unit test scenarios pass
(`tests/test_diff_generator.py`, synthetic snapshots — every matrix
row's transition fires correctly and only on its own condition, the
6→7 healthy-streak-vs-milestone coexistence case, two milestones
unlocking the same day producing two distinct events with distinct
`eventId`s, determinism across two identical calls, an unmapped field
producing silence per Rule 10, and validation correctly rejecting equal
or reversed dates while explicitly *not* rejecting a multi-day gap).

Verified end-to-end against the real account: two real snapshots were
created via `create_daily_snapshot()` a day apart, with one genuine
logging activity in between causing `logging.currentStreak` to move
0→1, and `generate_events()` correctly detected exactly one
`LOGGING_STREAK_EXTENDED` event from the real data — both test
snapshots and the modified `behaviorState` were cleaned up afterward.

Nothing calls `generate_events()` in production yet — no scheduler, no
persistence of its output to an `events` collection. Both remain
Step 11's job.

## Step 11.0 — Scheduler Philosophy

**One question, frozen**: *"When and how should the historical
infrastructure run safely?"* Not "what changed" (Step 10 already
answered that), not "which notification should be sent" (Phase 5's
question), not "how healthy is the user" (Health's question, answered
long ago). The scheduler owns orchestration only —
**engines answer questions; infrastructure moves information**, and
this is the purest expression of that rule in the whole project: the
scheduler itself answers nothing.

### Responsibilities, frozen

```
Start
  |
  v
Find users needing today's snapshot
  |
  v
create_daily_snapshot()      -- already built, Step 9.3
  |
  v
Load yesterday's snapshot
  |
  v
generate_events()            -- already built, Step 10.3
  |
  v
Persist events
  |
  v
Done
```

Every box above is a function that already exists. The scheduler adds
exactly one new capability: persisting the Diff Generator's returned
list to the `events` collection — everything else is a call to
already-frozen code.

**It must never**: calculate Health, Metrics, Recommendations, or
Behavior; compare snapshots itself; classify events itself; decide
which events matter or send a notification. Any of those would mean
the scheduler quietly became a sixth engine.

### Inputs and outputs, frozen

**Inputs**: a date, and a database handle. Nothing else — no business
objects, no engine outputs passed in directly.

**Outputs**: none, as a return value. Its only effect on the world is
writing to `dailySnapshots/` and `events/` — the same two collections
Steps 9 and 10 already own.

### Six rules, frozen

1. **Scheduler owns timing, not logic.** Swapping APScheduler for Cloud
   Scheduler, Firebase Scheduled Functions, cron, or a Kubernetes
   CronJob changes only the caller — nothing inside the pipeline
   changes, because the pipeline never depended on *how* it was
   invoked to begin with.
2. **One user failing never stops everyone else.** Each user is
   processed inside its own isolation boundary; a failure for user 417
   is logged and skipped, never allowed to prevent user 418 from being
   processed.
3. **Idempotent.** Running the job twice for the same date produces
   the same result as running it once — `create_daily_snapshot()`
   already returns the existing document on a repeat call (Rule 5), and
   `generate_events()`'s deterministic `eventId`s make persisting them
   twice an upsert, never a duplicate.
4. **No partial completion treated as done.** A snapshot existing does
   not, by itself, mean that day's job is complete — events for that
   day's transition may still be missing (a crash between the two
   steps). "Snapshot exists" and "events exist for this transition" are
   two independent facts, both checked, never one inferred from the
   other.
5. **Observable.** Every run logs a summary: users found, successes,
   failures, events generated, start and finish. Infrastructure must
   always be able to explain itself after the fact, the same
   traceability principle already frozen for every domain engine's
   decision trace, applied here to orchestration runs instead of
   business decisions.
6. **No assumption about midnight.** The job doesn't run "at exactly
   00:00" — it processes "yesterday" (calendar day, per whichever
   timezone the day boundary already uses — see Step 11.2). Whether the
   actual invocation happens at 00:05, 00:20, or 01:00, it produces the
   same result for the same calendar day.

### Step 11.0 — FROZEN

The one question, the responsibilities diagram, the inputs/outputs, and
the six rules are frozen above. Nothing about the actual orchestration
flow's code shape, failure recovery, or catch-up behavior has been
decided yet — Step 11.1 and 11.2 are next.

## Step 11.1 — Scheduler Pipeline

```
run_daily_snapshot_job(db, date)
        |
        v
get_active_users(db)                     -- who to process
        |
        v
for each user, isolated:
        |
        v
    determine_catch_up_range(db, uid, date)   -- Step 11.2's job
        |
        v
    for each date in that range, isolated:
        |
        v
        create_daily_snapshot(db, uid, that_date)
        |
        v
        load snapshot for (that_date - 1)
        |
        v
        if it exists:
            generate_events(uid, yesterday, today)
                |
                v
            persist_events(db, uid, events)   -- upsert by eventId
        |
        v
    log per-user outcome
        |
        v
log run summary (Rule 5)
```

**Isolation happens at two levels, not one**: per-user (Rule 2) and,
within a single user's catch-up range, per-day — a transient failure on
one historical day must not block that same user from attempting the
next day, since every step is independently idempotent and safe to
retry on the following run.

### Step 11.1 — FROZEN

The orchestration flow above is frozen — every box is either an
already-built function (Steps 9 and 10) or a new, narrowly-scoped
orchestration helper (`get_active_users`, `determine_catch_up_range`,
`persist_events`). Failure and catch-up semantics are Step 11.2's job,
referenced here but not yet defined.

## Step 11.2 — Failure & Recovery Policy

### The central decision: Option A or Option B?

**Given a multi-day outage (scheduler offline July 1-4, returns July
5), should the job process only July 5 (Option A), or replay every
missed day in order until history is complete (Option B)?**

**Decision, frozen: Option B, bounded.** Given everything already built
around immutable, versioned snapshots and the Historical Principle
("if this disappeared, would history lose meaning"), leaving permanent
gaps after an ordinary outage would contradict the whole premise of
Era 2 — a snapshot system that silently tolerates missing days isn't
preserving history, it's preserving *most* of it. Each user catches up
independently, from wherever their own history actually left off.

### How catch-up range is determined — no separate progress tracker needed

**Refinement found while designing this policy, not requiring new
state**: Rule 4 already means "snapshot exists" can't be trusted alone
as "day complete" — but rather than building a separate job-progress
record to track this, the same idempotency already guaranteed by
`create_daily_snapshot()` and `generate_events()` makes tracking
unnecessary. For every day in a user's catch-up range: attempt the
snapshot (a no-op if it already exists); attempt the events for that
day's transition (a no-op upsert if already persisted, and a genuine
fill-in if the previous run crashed between the two steps). Redoing a
completed step is cheap and harmless, so there is nothing to separately
remember — the range itself is simply **`last existing snapshot's date`
through `date` (today, inclusive)**; if a user has never had a snapshot
at all, the range collapses to just `date` itself — no attempt to
reconstruct arbitrarily deep history for a brand-new user, since there
is no established baseline to catch up *to*.

**Corrected from an earlier draft of this range, found while designing
Step 11.3**: starting from `(last existing snapshot's date) + 1` would
silently skip re-verifying the last existing day itself — if that day's
snapshot was written but its events were lost (a crash between the two
steps), starting *after* it would mean that day's missing events are
never regenerated by any future run. Starting the range from the last
snapshot's own date, not the day after it, gives that day exactly one
more chance each run to have its events filled in, at the cost of
re-attempting one already-complete day (a safe, cheap no-op) every
time the job runs.

### Bounded, not unbounded

**A maximum catch-up window, frozen as a first cut, same tuning caveat
every threshold in this spec carries**: `MAX_CATCHUP_DAYS = 30`. An
outage longer than that is treated as an operational incident requiring
manual attention, not something the scheduler silently absorbs one user
at a time — an unbounded catch-up risks one very-stale account making a
single run arbitrarily slow or expensive, at the cost of one very rare
scenario (month-plus downtime) versus the common one (an outage of
hours to a few weeks) this bound already handles correctly.

### Which timezone decides "what day is it"

**Not previously decided — resolved here, reusing an existing
constant rather than inventing a new one.** `LOGGING_TIMEZONE`
(`behavior_engine.py`, Asia/Kathmandu, UTC+5:45, frozen in Phase 4.5.1)
is reused as the day-boundary reference for "what is yesterday" from
the scheduler's perspective — not server UTC. This keeps the Daily
Snapshot's own notion of "which calendar day" aligned with the same
clock Logging and Spending Behavior already use to decide the same
question, rather than introducing a second, silently different
definition of "today" alongside it.

### Failure scenarios, frozen with explicit answers

| Scenario | Expected behavior |
|---|---|
| Scheduler runs twice for the same date | No duplicate snapshots or events (Rule 3/idempotency) |
| Crash after snapshot, before events | Events regenerated on the next run (Rule 4) |
| Crash after events | Safe rerun — both steps are no-ops the second time |
| One user fails | Logged, skipped; remaining users unaffected (Rule 2) |
| One day fails mid-catch-up for a user | Logged, skipped; later days for that same user still attempted; that day retried on the next run |
| No prior snapshot for a user | Catch-up range collapses to just today — no deep backfill attempted |
| No active users | Successful no-op, logged as such |
| Multi-day downtime (≤ `MAX_CATCHUP_DAYS`) | Full catch-up, oldest missing day first (Option B) |
| Downtime exceeding `MAX_CATCHUP_DAYS` | **The entire user is skipped this run, with a logged warning naming the gap size** — never a partial catch-up of only the most recent `MAX_CATCHUP_DAYS`. Partial catch-up would itself be a silent truncation of history (exactly what this policy exists to avoid); an explicit skip-and-warn makes the gap visible and actionable instead. |

### Step 11.2 — FROZEN

Option B (bounded catch-up) is the frozen decision, along with the
no-separate-tracker refinement, the `MAX_CATCHUP_DAYS` bound, the
timezone reuse, and the complete failure-scenario table. Step 11.3 —
Scheduler Implementation — builds the actual orchestration code against
this policy; nothing about code shape has been written yet.

## Step 11.3/11.4 — Scheduler Implementation, Testing & Real-Account Verification — FROZEN

Implemented in `services/scheduler_service.py`: `run_daily_snapshot_job(db,
today=None, dry_run=False)` as the sole public entry point, with
`process_user()`/`process_day()`/`persist_events()`/`get_active_users()`
as the internal orchestration helpers exactly per Step 11.1's pipeline —
none of them compute a domain engine, compare a snapshot, or classify an
event.

**One correction made to the design during implementation, already
folded into Step 11.2 above**: the catch-up range starts from the last
existing snapshot's own date, not the day after it — otherwise a day
whose events were lost to a crash would never get a second chance.

**One correction to the `MAX_CATCHUP_DAYS` policy, also folded in
above**: exceeding it skips the entire user with a logged warning,
never a partial catch-up of only the most recent window — a partial
catch-up would itself be the silent truncation this policy exists to
prevent.

`month_key_for()` was extracted from `snapshot_service.py` as a shared
helper, used by both the real snapshot-creation path and the
scheduler's dry-run preview path (which reuses `snapshot_service`'s own
`_gather`/`_is_complete`/`_build_snapshot` to compute what a snapshot
*would* contain without writing it) — one definition of "which month a
date belongs to," not two.

All 11 unit test scenarios pass (`tests/test_scheduler_service.py` —
a fake Firestore supporting `order_by`/`limit`/`stream` for the
catch-up-range query, with `process_day`/`process_user` monkeypatched
where appropriate to isolate orchestration behavior from the full
five-engine gather path): no-prior-snapshot collapsing to just today,
the corrected catch-up start date, the gap-exceeds-bound skip (not
truncate), per-day isolation within one user (a failing day doesn't
block later days for that same user), per-user isolation within one run
(one user's total failure doesn't stop another user), and
`persist_events`'s upsert-not-duplicate behavior.

**Verified end-to-end against the real account, scoped deliberately to
`process_user()` rather than the full `run_daily_snapshot_job()`** —
the full job iterates every user in the `users` collection, and running
it against the live project risked touching real accounts beyond the
one test account this whole spec has verified against throughout.
`process_user()` exercises the identical pipeline for one uid: a
single-day case (no prior snapshot, collapsing to just today) and a
three-day catch-up case (a seeded snapshot two days prior, one genuine
logging action causing a real streak extension *and* a real
`FIRST_EXPENSE_LOGGED` milestone unlock the same day) both produced
correct, correctly-persisted events with distinct `eventId`s. All
created snapshots, events, and the modified `behaviorState`/
`behaviorHistory` were cleaned up afterward.

**Not yet done, named rather than silently skipped**: nothing calls
`run_daily_snapshot_job()` in production — no APScheduler job
registered in `main.py`. Wiring that in is a small, separate,
deliberately deferred step — registering the actual cron trigger is a
caller decision, not something this implementation needed to settle to
be complete on its own terms.

## Step 12 — Integration — FROZEN

Every previously-named "not yet wired" gap from Steps 3-6, 9, and 11 is
now connected. No new domain reasoning was introduced anywhere in this
step — every change below is a call to a function that already existed
and was already tested.

**12.2 — Logging.** `record_logging_activity()` is now called from
every route that already calls `engine_recompute()` with
`TRANSACTION_CREATED` or `TRANSACTION_CONFIRMED`:
`routes/transactions.py` (manual expense, generic transaction create),
`routes/confirm.py` (single confirm and the bulk-confirm loop — one
call per batch, not one per month, since Logging is a per-day, not
per-transaction, fact), `routes/chat.py` (chat-created transaction, two
chat-confirm paths). **`TRANSACTION_EDITED`/`TRANSACTION_DELETED` call
sites were deliberately left untouched** — per 4.5.1's own frozen
trigger table, neither reason counts as logging activity, so wiring
them would only add a call that always no-ops. Each new call is wrapped
in its own try/except, mirroring the existing pattern already used for
`engine_recompute()` at every site — a Behavior Engine hiccup must
never break the underlying transaction request.

**12.3 — Saving.** `record_saving_activity()` is called at the end of
`perform_month_rollover_for_user()` in `services/budget_service.py`,
using that function's own already-computed `prev_month_key` and reading
`income`/`totalSpent` from `financial_engine.get_summary()` for the
month that just closed — never recomputed, exactly Actual Savings'
frozen definition (spec 4.5.3).

**12.5 — Spending & Recovery, plus a genuine ordering correction found
while wiring it.** The original Step 12.5 sketch read "snapshot exists
→ then evaluate behavior" — but since a snapshot is immutable once
written (Rule 5), evaluating *after* creating the snapshot would mean
today's own evaluation could never be reflected in today's own
snapshot, only tomorrow's. `process_day()` now evaluates Spending and
Recovery Behavior **before** creating the snapshot: it reads that
day's Health status and Recovery Plan directly (`health_engine.compute_overall_health`,
`metrics_engine.get_metrics`), calls `record_spending_activity()`/
`record_recovery_activity()`, and only then calls
`create_daily_snapshot()` — which re-reads Health/Metrics a second time
internally. This duplicate read is accepted deliberately, the same
"bounded imprecision" tradeoff already frozen in Step 9.2, in exchange
for each day's snapshot being internally consistent with its own
Behavior evaluation.

**12.4 — Scheduler registration, with a second bug found before it ever
ran.** `run_daily_snapshot_job()` originally defaulted its `today`
argument to *today* in `LOGGING_TIMEZONE` when called with no explicit
date — but a job firing shortly after midnight needs to process
*yesterday*, the day that just fully elapsed, not the barely-started
current day. Fixed to default to `yesterday`, which is what actually
makes Rule 6 ("no assumption about midnight") true rather than merely
stated. Registered in `main.py` as a third APScheduler job, at 00:30
daily, alongside the existing monthly-rollover and pre-month-end-reminder
jobs.

**12.6 — Real-account, end-to-end walkthrough**, run once as a single
continuous script against `botbachat@gmail.com`, not as separate
per-component checks: a confirmed manual transaction correctly extended
`behaviorState.logging`'s streak to 1; `process_user()` for that same
day correctly created a snapshot showing Spending Behavior *already*
evaluated (`currentHealthyStreak: 1`) before the snapshot was written,
with `behaviorSummary.status: "building"`; a simulated month rollover
for that user correctly updated `behaviorState.saving` to
`currentProtectionStreak: 1` for the month that had just closed. One
transient network error surfaced during the first attempt (a genuine
`503`/connectivity failure from Firestore, not a code defect) —
`process_day()`'s per-day error isolation caught it correctly and
reported failure rather than crashing, confirming that isolation
guarantee under a real, not simulated, failure. The walkthrough was
re-run successfully afterward; every transaction, snapshot, budget
document, and legacy rollover event created during it was deleted, and
`financialSummary` was recomputed once more to clear the value the
deleted test transaction had left behind.

**Architecture status**: every box from Financial Engine through the
Daily Snapshot Scheduler is now not only implemented but connected.
Notification Engine (Phase 5) is the only remaining piece, and it
starts as a pure consumer of an already-working, already-verified event
stream — never having to infer a change itself.

---

## Backend Platform — FROZEN

**The full pipeline now has real code behind every arrow, not just a
design**:

```
Financial Engine → Metrics Engine → Health Engine → Recommendation Engine
   → Behavior Engine → Daily Snapshot → Diff Generator → Events
   → Eligibility Waterfall → Notification Generator → Notification Repository
   → Delivery (FCM) → User
```

Five domain engines (Financial, Metrics, Health, Recommendation,
Behavior), one historical-infrastructure layer (Snapshot Builder, Diff
Generator, Scheduler), and one complete Notification Engine
(Eligibility, Generator, Repository, Delivery) — every component
implemented, unit-tested, integration-tested through the scheduler, and
verified against a real Firestore account where applicable. That third
layer of verification (real infrastructure, not just mocks) is what
this freeze actually rests on — every phase since Era 1 has gone
through the same three-layer discipline, not a rubber-stamped design
sketch.

**One named, deliberately unresolved exception**: `NEW_BEST_STREAK` has
Eligibility (5.2A) and Priority (5.3) rows but no Frequency, Timing, or
Template row, and no Diff Matrix producer at all — the same
unreachable-event status already flagged for `BACK_ON_TRACK`,
`CONSISTENT_LOGGER`, and `MONTH_FINISHED_UNDER_BUDGET` in the Event
Catalog. A phantom event with partial downstream policy but no upstream
producer can never actually violate any frozen rule in practice (it
never fires), so it does not block this freeze — but it is a genuine,
open design decision (give it a producer, or remove it), not something
this freeze resolves by omission.

**From here, backend work is maintenance, bug fixes, and feature
additions — not core architectural development.** The next
transformation for BachatBot is giving users a clear, engaging way to
experience the intelligence already built: the Flutter frontend
(Behavior Dashboard, Milestones, Notification Center, push
registration, health/recommendation UI, navigation, and the UX work
already discussed) is where effort goes next.

---

## Phase 13.1 — Notification Center (Frontend) — FROZEN

**Scope, decided before code**: the list is read directly from
Firestore (`users/{uid}/generatedNotifications`, a real-time listener —
the same working pattern the legacy alert-popup system already used),
since a read-only fan-out has no business logic to own. Mutating
status, however, goes through two new thin REST endpoints —
`POST /notifications/{eventId}/read` and `/dismiss` — rather than a
direct client write, so the Repository's idempotency guarantees
(`mark_read`/`mark_dismissed` never move status backward) stay the
single, server-owned source of truth instead of being re-implemented
in Flutter. The existing bell/badge was repointed from the legacy
`/alerts`-backed `NotificationScreen` to the new
`NotificationCenterScreen` and `NotificationCenterService.unreadCount`
— found mid-implementation that `NotificationScreen` is *also* used
directly (not via the bell) for pending-transaction review
(`_checkPendingTransactionsAndNavigate`), which was left untouched;
only the bell's target and badge source moved.

**Built**:
- Backend: `routes/notifications.py` gained `mark_notification_read`/
  `dismiss_notification`, thin pass-throughs to
  `notification_repository.mark_read()`/`mark_dismissed()`. Verified by
  calling the route functions directly against real Firestore (status
  transitions, idempotent re-dismiss, 404 on an unknown id) — cleaned
  up afterward.
- Frontend (first FCM integration in this codebase — `firebase_messaging`
  did not exist here before this phase): `PushNotificationService`
  (permission request, token fetch + registration, `onTokenRefresh`
  re-registration, foreground/background/terminated message handling),
  `NotificationCenterService` (the Firestore listener + unread-count
  singleton, same pattern as the existing `AlertPopupService`/
  `MonthEventService`), and `NotificationCenterScreen` (priority-colored
  list, unread dot, swipe-to-dismiss, tap-to-read).
- `flutter analyze` clean across every file touched.

**Real, unprompted, full-stack verification** — better than anything
staged: a real transaction on a real device produced a real
`FIRST_EXPENSE_LOGGED` milestone, which the real pipeline (Behavior →
Diff Generator → Eligibility → Generator → Repository) turned into a
notification; `deliveredAt` confirms a real successful FCM hand-off
(the device's `fcmToken` was registered by `PushNotificationService`
exactly as designed); the user tapped it in the live Notification
Center, which correctly called the new `/read` endpoint — `status:
Read`, `readAt` stamped, confirmed by reading the real document
afterward. This is the first time the full chain — user action through
Financial/Behavior engines, Snapshot, Diff, Eligibility, Generator,
Repository, Delivery, FCM, and back into rendered UI — was exercised
by genuine use rather than a script.

**One honest, named limitation surfaced by this same real test**:
`MILESTONE_UNLOCKED`'s `cta` ("View milestone") currently has nowhere
to send the user — `deepLink` is `null` by design (`notification_generator.py`'s
own note: Flutter route names don't exist yet), and there is no
Milestones screen at all yet. Tapping the notification correctly shows
its title/body and marks it Read; the `cta` button currently just
closes the dialog. Closing this gap is exactly the next planned phase
(Behavior UI / Milestones), not a defect in the Notification Center
itself.

---

## Phase 13.2 — Behavior UI — FROZEN

**Scope, decided before code**: the Behavior Engine had no REST surface
at all before this phase — `compute_behavior_summary()` and
`behavior_state_repository`'s `load_state()`/`load_history()` existed
only as internal calls from the scheduler. Added `GET /behavior`,
matching `routes/financial_health.py`'s existing convention exactly
(computed fresh on request, `{success, data}`), rather than reading a
possibly-stale snapshot field from Firestore directly — consistent with
how Health is already exposed, distinct from the Notification Center's
list (which is read-only and has no business logic, so a direct
Firestore listener was the right call there instead). Placement in the
app: a "Your Progress" entry point on the Home screen (same "See All"
card pattern already used for Categories/Reports), not a new bottom-nav
tab — one dedicated `BehaviorScreen` holds the full summary/streaks/
milestones view.

**The milestone catalog (title/description per code) lives in
`routes/behavior.py`, not `behavior_engine.py`** — presentation copy is
kept out of the engine, the same separation `notification_generator.py`'s
Template Matrix already draws between "what happened" and "how it's
worded." The route merges `behaviorHistory.milestones[]` against this
catalog so all 4 known milestones are always returned, locked or
unlocked — an achievement-badge UX, not just a growing unlocked-only
list.

**Built**:
- Backend: `routes/behavior.py` (`GET /behavior` →
  `{summary, state, milestones}`), registered in `main.py`.
- Frontend: `BehaviorScreen` (status card, streak rows for
  Logging/Spending/Saving/Recovery, a 4-tile milestone grid with
  locked/unlocked states), plus a compact preview card on `HomeScreen`
  ("N-day logging streak" + "M/4 milestones").

**Real-account verification**: called the route function directly
against the same real device/account from the Notification Center's
own real walkthrough (`uid=BDpx6it7MeSZSrUJEBu9Bbwfp8l1`) — returned the
correct live state: `status: "building"`, `logging.currentStreak: 1`,
and `FIRST_EXPENSE_LOGGED` correctly shown `unlocked: true` with its
real `unlockedAt` date, the other three milestones correctly `unlocked:
false`. `flutter analyze` clean across every file touched. This also
closes the exact gap the Notification Center's own freeze named: a
`MILESTONE_UNLOCKED` notification's "View milestone" cta now has a real
screen to lead to, once Phase 13's deep-link wiring catches up.

---

## Phase 13.2b — Activity Feed — FROZEN

**Reframed from real user feedback, not a pre-planned phase**: after
using the app for real, the question came back "a notification came
but nothing showed in the Notification Center" — the notification in
question turned out to be the legacy alert system's own budget-threshold
popup, a completely different mechanism than the new engine. Digging
into *why* that felt wrong surfaced a genuinely reasonable ask: every
transaction should be visibly logged somewhere the user can check. That
ask was **not** implemented by making transactions "eligible" in the
Notification Engine's own sense (a live per-transaction ping would
directly violate 5.0's Rule 1 — "never notify because something
changed, notify because the user should care" — and would flood the
new engine with exactly the noise the Eligibility Waterfall exists to
prevent). Instead it revealed that the legacy `alerts` collection
*already* logs every transaction (`routes/chat.py`'s "Rs X `<cat>`
expense saved" entries) — its old screen was even already titled
"Activity." The real gap was that the bell only pointed at ONE of the
two systems at a time, never both.

**Decision: one unified `ActivityFeedScreen`, replacing the bell/badge
target everywhere it appeared** (`MainScreen`'s AppBar,
`CategoriesScreen`'s own separate AppBar bell, and the pending-transaction
auto-navigate-on-launch check) — merging `users/{uid}/alerts` (legacy:
transactions, budget alerts, pending-transaction confirmations) and
`users/{uid}/generatedNotifications` (the new engine) by timestamp, with
an All / Transactions & Alerts / Notifications filter. No new backend
endpoint — both sources are read-only fan-outs with no business logic
of their own, matching the same reasoning that already justified a
direct Firestore listener for the Notification Center's own list.
Mutating an item still goes through each system's own existing,
already-tested write path (`PATCH /alerts/{id}/read`, `POST
/notifications/{id}/read|dismiss`) — merging the display never merges
the two systems' actual state.

**A real bug caught before shipping, not after**: the first draft
scoped both Firestore listeners to `ActivityFeedScreen`'s own
`initState`/`dispose` — meaning the bell's unread badge would only
stay accurate while that screen happened to be open, silently going
stale the rest of the time. Fixed by extracting `ActivityFeedService`,
a persistent app-lifetime singleton (the same pattern already used by
`AlertPopupService`/`MonthEventService`), initialized once in
`MainScreen.initState()` alongside the other singletons; the screen
itself now only reads the service's `ValueNotifier`s, owning no
subscription of its own.

**Superseded and removed**: `NotificationCenterScreen` and
`NotificationCenterService` (both introduced earlier this same phase,
Phase 13.1) are now fully replaced by `ActivityFeedScreen`/
`ActivityFeedService` and were deleted rather than left as dead code.
The **pre-existing** `NotificationScreen` (the old filtered
transaction-history browser used from Home/Categories/Income/Profile
for "view all Food transactions," "view today's transactions," etc.)
was deliberately left untouched — it serves a genuinely different,
still-needed purpose from the bell/badge, and nothing about this phase
required touching it.

**Verification**: `flutter analyze` on the full project — zero errors,
only 18 pre-existing lint infos in files this phase never touched.

---

## Phase 13.2c — Activity Feed Redesign — FROZEN

**Driven entirely by real usage feedback, not a pre-planned pass**:
after actually using the app, three things came back —
(1) the "double notification" feeling (system push + an in-app banner,
both firing for the same budget alert), (2) the feed's cards read as
alarming (saturated red/orange full-card backgrounds) rather than
routine, and (3) `Your Progress` sat at the very bottom of Home, easy
to miss. All three were product/UX decisions, not bugs — confirmed
first against real Firestore data that nothing was actually missing.

**Decisions made, each confirmed before building**:
- **Dropped the in-app popup banner** (`AlertPopupService._showBanner`)
  entirely — the system push already reaches the user reliably, even
  backgrounded; the banner was the actual redundant half of the
  "double" feeling, not the push. `_showBanner`/`AlertBanner` left in
  place, unused, rather than deleted — reversible if this needs
  revisiting.
- **Facebook-style redesign of `ActivityFeedScreen`**: plain white rows
  by default; unread items get a light green tint (`0xFFEAF7F0`) plus a
  small solid dot, both of which disappear the moment the item is read
  — never a saturated full-row color. Icons are small, tinted circular
  avatars per item kind (receipt for transactions, warning for budget
  alerts, swap for rebalances, bell for engine notifications) instead of
  color-coding the whole card.
- **Type filter split three ways** (Transactions / Alerts / Notifications
  / All) instead of one combined "Transactions & Alerts" bucket, plus
  independent Category and Date Range filters — all three collapsed
  into a single filter-icon-triggered bottom sheet (three dropdowns +
  Apply/Reset) rather than an always-visible row of chips, to keep the
  main view uncluttered. A small dot on the filter icon itself shows
  when any filter is active.
- **Added a search bar** (title/body/message/category substring match)
  pinned under the AppBar.
- **`Your Progress` moved from the bottom of Home to a slim, single-line
  strip** directly under the Overall Health badge near the top —
  deliberately neutral-toned (same background as the health badge, no
  bright color) so it earns visibility without competing with the
  balance numbers above it. Tapping it still opens the full
  `BehaviorScreen`, unchanged.

**Verification**: `flutter analyze` on the full project — zero errors;
one expected, deliberately-left `unused_element` warning on
`_showBanner` (documented in its own comment, not accidental dead
code).

---

## Phase 13.3 — Streak Screen Redesign & Budget Pop-up — FROZEN

**Two more real-usage findings, resolved the same way — verify first,
then design, then confirm before building:**

- **"The notification came but nothing showed"** turned out, again, to
  be expected behavior, not a bug: the `alerts` collection's entries
  were correctly present and correctly rendering in the Activity Feed —
  the confusion was between the "Notifications" filter tab (new engine
  only) and "Transactions & Alerts" (legacy system), same distinction
  as Phase 13.2b, now doubly confirmed as a real, recurring UX question
  rather than a defect.
- **"Only a push notification, no in-app confirmation"** for budget
  overspend, after Phase 13.2c dropped the banner — this one *was* a
  real gap: a system push alone is too easy to dismiss without
  registering. Fixed with a **center pop-up dialog requiring
  acknowledgment** ("Got it"), queued so multiple near-simultaneous
  alerts (a common case: an expense threshold + a rebalance transfer)
  never stack dialogs — `AlertPopupService._enqueueCenterAlert()`/
  `_processCenterAlertQueue()`. Scoped deliberately narrow: only the
  budget alerts that already exist today, not the bigger, separately-
  designed Pattern Spending Alerts feature (still paused, unchanged).

**Streak screen, redesigned from a Duolingo reference, in our own
colors**: `BehaviorScreen` now opens as a full "Streak" page (bottom
sheet-style, sliding up from the bottom via the new `slideUpRoute()`
helper) reached from a flame + streak-number badge that moved from a
scrollable Home card into `MainScreen`'s AppBar itself — permanently
visible, not scrollable away, per the direct ask to have it "above."
Backed by a new tiny app-lifetime holder, `BehaviorPreviewService`
(two `ValueNotifier`s, refreshed at app start and after every Home
fetch), since the badge now needs to be readable from the AppBar,
outside `HomeScreen`'s own widget tree.

**A real streak calendar, not just a number**: the old design only
showed the current streak count. The new one queries
`users/{uid}/transactions` directly (read-only, monthKey-filtered, no
business logic — the same reasoning already used for Activity Feed's
list reads) to find which exact calendar days had a logged transaction,
and renders a real month grid with those days highlighted — closer to
what "streak" actually means to a user than an abstract counter.

**Less permanent text, not more explanation removed**: every card
(status, other streaks, milestones, the streak-goal bar) now shows only
a short label/number by default. The fuller "what this means / how to
grow it" explanation moved into `HoldTooltip` — a new, reusable
press-and-hold-to-reveal widget (the mobile equivalent of the "hover to
see a word's meaning" pattern asked for), rather than sitting on-screen
permanently. Nothing was deleted — the same information is still
available, just on demand instead of as a wall of text.

**Verification**: `flutter analyze` on the full project — zero errors,
same one deliberate `_showBanner` warning as before.

---

## Phase 13.5 — Health Theme System, Foundation — FROZEN

**The idea, precisely**: the Health Engine's status shouldn't just show
a dot — it should become a consistent visual language ("financial
mood") the whole app reflects: accent color, card tint, progress color,
ambient background wash. Scoped deliberately into a foundation pass
first (this phase) before spreading to Categories/Reports/Chatbot
tone/Notifications (separate, later phases, chatbot tone explicitly
deferred since it's backend wording work, not Flutter theming).

**A real duplicate-signal problem found before building on top of it,
not after**: the app already had a working "financial mood" mechanism
— `FinancialStatusService` + `AmbientStatusOverlay`, wrapped around the
entire app in `main.dart`'s `MaterialApp.builder`. But it computed its
own crude client-side proxy (`spent > budget limit?` in
`home_screen.dart`), completely independent of the real, multi-factor
Health Engine status (category pressure, projected deficit, recovery
state) already computed server-side and already driving the Home badge
and `HealthScreen`. Two "health" signals could disagree. Building a new
theme system on top of *either* signal without reconciling this first
would have made the disagreement worse, not better.

**Fixed by retiring `FinancialStatusService` entirely** — deleted, not
deprecated-in-place. `AmbientStatusOverlay` now reads
`HealthThemeService.status` instead.

**Built**:
- `lib/theme/health_theme.dart` — the frozen 3-row lookup (green/amber/
  red → accent/statusColor/progressColor/cardTint/backgroundTint),
  reusing the exact brand colors already used elsewhere (Streak's
  flame, Notification priority colors) rather than inventing a new
  palette. `iconStyle`/`animationStyle` from the original design are
  named in the class's own doc comment as deliberately not built yet —
  a later phase, not faked with a placeholder now.
- `lib/services/health_theme_service.dart` — a plain `ValueNotifier`
  holder, deliberately **not** a self-fetching singleton like
  `ActivityFeedService`/`BehaviorPreviewService`: `HomeScreen` already
  calls `GET /financial-health` every refresh for its own badge, so
  `_fetchOverallHealth()` just pushes the real result here instead of
  firing a second, redundant fetch of the same endpoint.
- `AmbientStatusOverlay` rebuilt on the new service/theme. Green now
  means *no overlay at all* (calm reads better as the absence of a mood
  layer than as a green wash — matches the design's own caution against
  overdoing it); amber/red keep the exact same smoky, desaturated haze
  treatment that already existed, just correctly sourced now.
- Home's Health badge now themed: card tint, border, and status-text
  color all come from `HealthTheme.forStatus()` instead of a fixed grey
  background and black text.

**Deliberately out of scope for this pass**: `BalanceCard`'s own
`spendingPaceStatus` gradient was left untouched — that's a different
Metrics Engine signal (pace vs. overall Health), and conflating the two
without being asked risked exactly the kind of signal confusion this
phase just finished untangling. Categories, Reports, Chatbot tone, and
Notifications are unchanged, per the agreed phasing.

**Verification**: `flutter analyze` on the full project — zero errors,
same pre-existing infos, same one deliberate `_showBanner` warning.

---

## Phase 13.6 — Deep Linking — FROZEN

**Closes the one real gap the Notification Center's own freeze named**:
`deepLink` was reserved in the frozen 5.6B shape since Phase 5, but
always `None` — its own comment said the reason was "Flutter's actual
route names don't exist yet." They do now.

**Backend — a Deep Link Matrix**, the same shape as the existing
Priority/Frequency/Timing/Template matrices: event code -> a semantic
destination key (`"health"`, `"category_detail"`, `"streak"`,
`"activity"`), never a Flutter class name — `notification_generator.py`
has no business knowing Flutter internals, the frontend owns the
key -> screen mapping. `CATEGORY_BECAME_EXHAUSTED` deliberately gets
its own `"category_detail"` key rather than the generic `"health"`
bucket, since its payload already carries the specific category —
routing straight to `CategoryDetailPage(category)` is more useful than
dropping the user on a generic Health screen. `TRANSACTION_CREATED`/
`TRANSACTION_CONFIRMED` (still phantom — no Diff Matrix producer,
per the 5.9 audit) got a row anyway, the same "complete the matrix even
for unreachable codes" discipline already applied to `NEW_BEST_STREAK`.
Rule 8 (fail fast) now includes the Deep Link Matrix in its missing-
policy check, same as the other three tables.

**Frontend — resolution only, no new navigation logic invented**: a
plain `deepLink -> Widget` switch in `ActivityFeedScreen`. Tap behavior
unchanged (mark read, show the detail dialog) — the dialog's CTA button
now actually navigates instead of just closing, closing the dialog
first so there's never a screen stacked behind the destination.

**Verification**: `test_notification_generator.py` extended with 2 new
scenarios (`MILESTONE_UNLOCKED` resolves to `"streak"` regardless of
milestone code; `CATEGORY_BECAME_EXHAUSTED` resolves to
`"category_detail"`, not the generic bucket) — all 19 scenarios in that
file pass, full backend suite (14 files) has zero regressions. Manually
re-verified 5 event codes end-to-end (`HEALTH_WORSENED` ->
`"health"`, `RECOVERY_STARTED` -> `"health"`,
`CATEGORY_BECAME_EXHAUSTED` -> `"category_detail"`,
`MILESTONE_UNLOCKED` -> `"streak"`, `LOGGING_STREAK_EXTENDED` ->
`"streak"`). `flutter analyze` on the full project — zero errors, same
pre-existing infos.

---

## Phase 13.7 — Health Theme, Categories — FROZEN

**Triggered by real usage feedback, same shape as before**: every
category card was rendering nearly identical saturated red — real
complaint was "too much red," "why not amber at 80%," and the cards
felt visually heavy. Root-caused before touching any styling: the
card's dominant coloring came from a local, client-only check
(`percent >= 100%?`), completely separate from the real backend
Category Health signal (`healthStatus`) that was *already being
fetched* — it just only powered a small secondary chip, never the
card's own background/border/badge. Two signals for the same fact,
exactly the same class of problem Phase 13.5 found and fixed for the
ambient overlay, now found a second time in the same screen family.

**Fixed the same way**: retired the local percent-only coloring
entirely; the whole card (background tint, border, percent badge,
category-name color, status label, progress bar color) now comes from
`HealthTheme.forStatus(healthStatus)` — the identical lookup table
built for Phase 13.5, reused rather than re-invented.

**Real-account verification confirmed the fix does what was asked**:
called `compute_category_health()` directly against the real account —
of five categories all sitting at/near 100% of raw budget, only one
(`Food`, `CATEGORY_RECOVERABLE`) is genuinely `amber`; the other four
are `green`, because Category Pressure is time-adjusted (spending pace
vs. how far into the month it actually is), not a flat percent-of-
budget check. The "wall of red" was entirely an artifact of the old
logic, not a true reflection of the account's real state — confirms
the fix addresses the actual complaint, not just its symptom.

**A second, independent bug found and fixed in the same pass** (not
part of the original ask, surfaced while investigating): the "2-column
grid" of category cards was never a real grid — a manual `Row` per
pair with no `crossAxisAlignment: CrossAxisAlignment.stretch`, so two
cards in the same row rendered at their own intrinsic height. A
flagged category (extra status-label row) was visibly taller than an
unflagged pair-partner. Fixed by stretching the row.

**A third, related hardening**: `CategoryDetailPage`'s budget-fetch had
an empty `catch (_) {}` — a transient failure there would silently and
permanently strand the screen on "no budget set," even with a real
budget existing server-side (confirmed via direct Firestore/API checks
against the real account during this investigation — the account's own
budget data was correct throughout). Now logged rather than swallowed;
pull-to-refresh already gives a retry path once noticed.

**Also addressed**: the ambient overlay's amber/red opacity was bumped
up slightly (0.16/0.22 → 0.22/0.30 top, 0.22/0.30 → 0.30/0.40 bottom)
per feedback that it was "barely noticeable."

**Verification**: `flutter analyze` on the full project — zero errors,
same pre-existing infos.

---

**Follow-up, same phase**: Goals summary and Projected Savings cards
redesigned to be more visually prominent (bigger icons/numbers,
circular icon badges matching the rest of the app) and their copy
simplified (shorter sentences, no em dashes). Projected Savings also
became sign-aware — a negative projection now shows in red via
`HealthTheme`, rather than always rendering in the same green
regardless of whether the forecast was actually good news.

---

## Phase 13.8 — Health Theme, Reports — FROZEN

**The third occurrence of the same duplicate-signal problem**, found
before implementing rather than after: Reports' "Overall Status" card
had its own local `low`/`ok`/`high`/`overspent` proxy, read from
`/monthly-report`'s `insights.overallStatus` — a third, independent
status signal alongside the real Health Engine status, after the same
class of bug was already found and fixed for the ambient overlay
(Phase 13.5) and Categories cards (Phase 13.7).

**Fixed the same way, a third time**: `_buildOverallStatusCard()` now
reads `_overallHealthStatus` (from `/financial-health`, fetched
alongside the existing `/monthly-report`/`/goals`/`/financial-metrics`
calls) through `HealthTheme.forStatus()` — the local proxy field and
its 4-way switch were removed entirely, not left dormant.

**Today chart's category bars now colored by real Category Health**
(`AdaptiveReportChart` gained a `categoryHealth` map parameter) instead
of uniform green — directly surfacing "the categories driving the
problem" per the original design idea, reusing the same
`HealthTheme.forStatus()` lookup rather than inventing new color logic.

**Week/Month day-bars deliberately left unchanged** — Category Health
is per-category or overall, not per-day; recoloring individual days
would mean fabricating a "risky day" concept the backend doesn't
produce. Named as a boundary, confirmed with the user before
implementing, not silently skipped.

**Verification**: real-account call to `compute_overall_health()`
confirms `amber` status flows correctly end-to-end. `flutter analyze`
on the full project — zero errors, same pre-existing infos.

---

## Phase 13.9 — Reports UI Cleanup — FROZEN

**Real usage feedback, UI-only — no backend logic touched, per explicit
instruction.**

**Found and fixed a genuine duplicate-header bug**: `ReportsScreen`
always rendered its own `AppBar` saying "Reports," with no
context-awareness — but it's used as a `MainScreen` tab too, which
already has its own AppBar showing "Reports." `CategoriesScreen` had
already solved exactly this with a `showAppBar` flag (`false` when
embedded as a tab, `true` when pushed standalone); `ReportsScreen`
never got the same treatment. Fixed identically: `showAppBar` added,
defaulting to `false`; the two standalone pushes from `HomeScreen` now
pass `showAppBar: true`.

**Filter redesign**: Today/Week/Month tabs kept visible as asked
(default view changed from `week` to `today`); the category filter (9
always-visible chips) moved behind a filter icon opening a clean
bottom sheet, the same interaction pattern the Activity Feed already
established — an active category filter now shows as a small dismissible
chip instead of a permanently-visible row.

**One new insight, deliberately minimal**: "X is your biggest spend
this period — Rs Y," a plain client-side `max()` over
`_categoryBreakdown`, already fetched — no new backend call, no new
logic invented, hidden entirely once a specific category is already
selected (a "top category" fact is meaningless once you're already
looking at just one).

**Verification**: `flutter analyze` on the full project — zero errors,
same pre-existing infos.

---

## Phase 13.10 — Health Theme, Chatbot Tone — FROZEN

**A different kind of "theme" than the others** — backend prompt
wording, not Flutter colors, since chat replies come from
`gemini.py`/`routes/chat.py`, not the frontend. Scoped to general
conversation only (Gemini's own natural reply), not the deterministic
one-line transaction confirmations ("Rs 250 Food ma kharcha gareko"),
per explicit confirmation — those stay factual acknowledgments,
unaffected.

**Reused an existing extension point rather than inventing a new
mechanism**: `process_chat_message()` already injected a "USER
CONTEXT" block into Gemini's system instruction (FirstName,
FirstMessage, MissingBudgetCategories). Added `HealthStatus`
(green/amber/red/unknown, the real Health Engine status) to that same
block, plus an explicit instruction in `SYSTEM_PROMPT`: tone only,
never a new fact — "never state a specific number, category, or amount
because of HealthStatus alone."

**Wired into both chat entry points** (`chat()` and `chat_sync()` in
`routes/chat.py`), each fetching `compute_overall_health()` the same
best-effort way the existing `missing_budget_categories` lookup already
does — a failure falls back to Gemini's normal neutral tone, never
blocks the chat response itself.

**Verification, against real Gemini, not simulated**: called
`process_chat_message()` three times with identical input, varying only
`overall_health_status` — green produced a warm, positive reply, amber
a gently attentive one ("something to check"), red a measured,
action-focused one ("let's take a look"). Confirms the tone genuinely
shifts, not just that the prompt text changed. Full backend suite (14
files): zero regressions.

---

## Phase 13.11 — Health Screen Refinement — FROZEN

**Closes the last gap in the Health Theme sequence**: `HealthScreen`
predates `HealthTheme` (built in Phase 13.4, before 13.5 created the
shared class) and still had its own separate, duplicate color
functions — the same "one signal, one place" issue already found and
fixed three times elsewhere. Removed entirely; every color on this
screen now comes from `HealthTheme.forStatus()`.

**A real accessibility gap found and fixed, not just a redesign**: the
category breakdown previously showed color only, with the plain-English
status hidden behind a press-and-hold tooltip — violating the project's
own frozen principle that "color is never the only signal." Now a real
list: category name, an always-visible status label ("Over budget" /
"Near limit" / "On track"), color, *and* the fuller explanation still
available on hold — all four together, not color alone.

**The hero card now explains, not just labels**: added a plain-English
"why" sentence under the status label, mapped from
`overallHealth.primaryReason` (the Health Engine's own single most
important true fact, by its existing priority order) — e.g. "You're
behind pace, but a recovery plan is already helping" for
`RECOVERY_NEEDED`. Previously the hero only showed an emoji and a
3-word label with no explanation at all.

**Recommendation card gained a scannable headline** above its detail
sentence (e.g. "Ease up on Shopping" / "Try keeping it around Rs
X/day..."), rather than one plain paragraph.

**Section order changed to match the intended reading flow**: What's
affecting it → What to do next → How to recover → Risks to watch,
mirroring "why am I here, what's causing it, what should I do, how do
I recover" rather than the original Recommendation-first ordering.

**Verification**: real-account call to `compute_overall_health()`/
`compute_category_health()` confirms the account's real current
state (`amber`, `RECOVERY_NEEDED`; Shopping `red`, three categories
`amber`, one `green`) flows correctly into the new hero explanation and
category list. `flutter analyze` on the full project — zero errors,
same pre-existing infos.

---

**Home follow-up, same phase**: found via real feedback ("badge is red
but the greeting still says steady") — the Home greeting's subtitle
("Your financial health looks steady.") was a hardcoded, never-computed
literal string, not even a stale duplicate signal this time, just plain
dead text sitting under a real, correctly-themed badge right above it.
Replaced with `_greetingSubtitle`, driven by the same
`_overallHealthStatus` the badge already uses. Also switched Home's
own chart from `view=week` to `view=today` (renamed "Weekly Report" to
"Today's Spending") per direct request — `ReportChart` itself needed no
changes, since it was always a category-breakdown chart regardless of
which time window fed it.

---

## Phase 13.12 — Home/Reports Chart Consistency — FROZEN

**Real feedback: "the Today chart in Reports and the Dashboard are
different."** Correct — they were two genuinely separate widgets.
`ReportsScreen` used `AdaptiveReportChart` (health-colored bars, sorted
by value, tooltips); `HomeScreen` used an older, separate `ReportChart`
widget (`widgets/report_chart.dart`) — always plain green bars, no
Category Health coloring, no sorting, different styling entirely. Both
fed from the same `/monthly-report` category breakdown, but rendered
by two independent implementations that had quietly drifted apart —
the same "one signal, one place" lesson from Phases 13.5/13.7/13.8/13.11,
this time as a duplicated widget rather than a duplicated color
function.

**Fixed by deleting the duplicate, not patching it to look similar**:
`HomeScreen` now uses the exact same `AdaptiveReportChart` widget
Reports does (`mode: 'today'`), fed the same `categoryHealth` map
(fetched alongside the existing `/financial-health` call, the same
approach already used in Reports). `widgets/report_chart.dart` deleted
— confirmed unused anywhere else first.

**Verification**: `flutter analyze` on the full project — zero errors,
same pre-existing infos.

---

## Phase 13.13 — Existing Screen Integration: Goals & Income — FROZEN

**Income → app-wide**: `HomeScreen`'s `onIncomeTap` had no refresh
callback at all after returning from `IncomePage` — unlike
`CategoriesScreen`'s equivalent push, which already did
`.then((_) => _fetchFinancialSummary())`. An income edit updated
`IncomePage`'s own state fine, but the balance card, health badge, and
chart on Home stayed stale until the next pull-to-refresh or app
reopen. Fixed the same way (`.then((_) => _fetchAll())`);
`ProfileScreen`'s "My Income" stat card had the identical gap, fixed
with its own existing `loadProfile()`.

**Goals gained real Behavior Engine data**: a saving-streak and
`FIRST_GOAL_COMPLETED`-milestone banner, read from `GET /behavior` (the
same endpoint already powering the Streak screen) — pure surfacing of
already-computed facts, no new logic. Goals previously had zero tie to
the Behavior Engine at all.

**A real dead-code bug found and fixed**: the goal progress bar's color
was `isCompleted ? _primary : _primary` — a ternary that always
evaluated to the same value, so completed and in-progress goals were
visually identical. Fixed using `status` (a real backend field, not
invented pace logic) to give completed goals a distinct celebratory
color.

**Deliberately deferred, confirmed before starting**: coloring a goal
amber for falling behind its monthly saving pace — that would mean
inventing a new domain rule ("what counts as behind pace?") with no
backend equivalent, the same category of new reasoning named as
deserving its own dedicated design pass, same as Pattern Spending
Alerts.

**Verification**: real-account check confirms both Goals conditions
(`saving.currentProtectionStreak == 0`, `FIRST_GOAL_COMPLETED` not yet
unlocked) — banner correctly stays hidden rather than showing a false
positive. `flutter analyze` on the full project — zero errors, same
pre-existing infos.

---

## Phase 13.14 — Two Real Bugs Found via Real Usage — FROZEN

**Bug 1: `check_goal_milestones()` was designed, unit-tested, and never
called anywhere in the live app** — the exact same "designed, never
wired" gap already found once for the Eligibility Waterfall (spec
5.9's own review). A real goal reached 100% funding on the real
account and correctly computed `status: "completed"` via the real
`/goals` API — but `FIRST_GOAL_COMPLETED` never had a chance to unlock,
because nothing ever evaluated it. Fixed by wiring it into
`scheduler_service.process_day()`, the same per-day evaluation spot
`record_spending_activity`/`record_recovery_activity` already use,
fed by `financial_engine.get_summary()`'s own `goalProgress` — the
identical computation the real `/goals` endpoint already returns, not
a re-derivation.

**Bug 2, more serious, found while verifying Bug 1's fix**: even after
wiring the check, the real notification still didn't fire. Root cause:
`eligibility_engine._frequency_allows()`'s "ONCE" policy for
`MILESTONE_UNLOCKED` matched notifications by `eventCode` alone — but
every distinct milestone (`FIRST_EXPENSE_LOGGED`, `FIRST_HEALTHY_WEEK`,
`FIRST_GOAL_COMPLETED`, ...) shares that same eventCode. This meant the
very first milestone any user ever unlocked would silently and
permanently block every subsequent, genuinely different milestone
notification, forever — a bug affecting every user, not just this
account, discovered only because a real completed goal produced zero
notification where one was clearly warranted.

**Fixed**: `_most_recent_notification_for_code()` now accepts an
optional `milestone_code`, narrowing the match to `payload.code` when
the event is `MILESTONE_UNLOCKED` — "ONCE" now means once per specific
milestone, not once ever for the whole shared event code.

**Verification, both bugs**: `test_eligibility_engine.py` extended with
a direct regression test (a second, genuinely different milestone is
eligible despite the shared eventCode; the same milestone twice is
still correctly blocked) — 14/14 scenarios pass. Full backend suite (14
files): zero regressions. Real-account confirmation, twice: first
`check_goal_milestones()` was called directly to confirm
`FIRST_GOAL_COMPLETED` unlocks in `behaviorHistory`; then
`process_user()` was re-run for real and produced a genuine "First
goal completed!" notification, delivered to the real device (confirmed
`deliveredAt` set, status `Read` on the real account).

**UI follow-up, same phase**: a completed goal previously reused the
exact same plain white card as an in-progress one, just with a tiny
"DONE" chip — real feedback: "doesn't look supportive at all." Now a
genuinely distinct treatment (`_completedGoalCard`): a gold gradient
hero, a trophy icon, and a real congratulatory line ("You saved Rs X.
Nice work!"), not a small badge bolted onto the same layout. In-progress
goals are visually unchanged. `flutter analyze`: zero errors, same
pre-existing infos.

## Phase 16 — Notification Preference Philosophy — FROZEN

**The core distinction this phase draws**: user preferences answer
"what types of information do I want to receive?" — the Notification
Engine (Eligibility → Frequency → Timing → Priority → Interruption
Level) still answers "should this particular event be delivered right
now?" A preference is one additional input to the existing waterfall,
never a second notification engine sitting beside it. Concretely: a
preference toggle is a bool an event's category is checked against;
it never touches Frequency windows, Timing, or Priority computation.

**Six user-facing categories** (invented here — no such grouping
existed anywhere in the codebase before this phase), each mapped to
the existing event codes, never exposing event-code names to the user:

| Category | Event codes | User sees |
|---|---|---|
| `transactions` | TRANSACTION_CREATED, TRANSACTION_CONFIRMED | "Transactions" |
| `budgetAlerts` | CATEGORY_BECAME_EXHAUSTED | "Budget Alerts" |
| `financialHealth` | HEALTH_WORSENED, HEALTH_IMPROVED, PRIMARY_RECOMMENDATION_CHANGED | "Financial Health" |
| `recovery` | RECOVERY_STARTED, RECOVERY_BECAME_IMPOSSIBLE, RECOVERY_COMPLETED, RECOVERY_FAILED | "Recovery" |
| `streaks` | all 6 *_STREAK_EXTENDED/_BROKEN codes | "Streaks & Progress" |
| `milestones` | MILESTONE_UNLOCKED | "Milestones" |

Transactions and Budget Alerts are deliberately split rather than
merged into one "Spending & Budgets" bucket, per real design feedback:
"Your transaction of Rs. 500 was confirmed" and "You've used 90% of
your Food budget" are psychologically different kinds of information,
and a user may reasonably want one without the other.

**Critical bypass**: `RECOVERY_BECAME_IMPOSSIBLE` is the only
Critical-priority event in the whole Priority Matrix (spec 5.3). It
always bypasses the Preference Gate regardless of the `recovery`
toggle — user preferences can control attention, but they cannot
suppress critical financial information. This is priority-specific,
not a blanket exemption for the "recovery" category: `RECOVERY_STARTED`
(Normal priority) is muted normally when `recovery` is off.

**No user-facing Frequency control**: the existing Frequency Matrix
(DAILY/WEEKLY/MONTHLY/ONCE/UNTIL_RESOLVED per event code) stays
entirely internal. Exposing it (e.g. "Health Worsened → Daily/Weekly/
Never") would leak internal architecture into the Settings screen for
no real user benefit — the six category toggles are a high-level
opt-in/opt-out signal only.

**Storage**: `users/{uid}.preferences.notifications`, a new
`NotificationPreferencesData` sub-model (`schemas/profile.py`) sitting
beside the existing `PreferencesData` (language/currency/
alertThreshold) — reuses the existing `/profile` GET/PATCH routes and
their dot-notation merge rather than a new router. Every field
defaults `True`; a missing category (including a user document that
predates this phase entirely) is treated as `True` — opt-out only, so
no migration is needed for existing accounts.

**Gate placement**: a new "User Preferences" gate in
`eligibility_engine.check_eligibility()`, between Gate 2 (Context) and
Gate 4 (Already Informed) — before Already Informed/Frequency are
even consulted, since a muted category should never reach the state
that would otherwise let it through. Implemented as
`_preferences_allow(db, uid, code)`: Critical bypass first, then
`_PREFERENCE_CATEGORY` lookup, then a live read of
`users/{uid}.preferences.notifications`. A code with no category
mapping (there are none today — all 17 event codes are covered) is a
pass-through, not a silent reject.

**Full waterfall, current state**:
```
EVENT
  ↓
Gate 1/3: Justification + Notification-Eligible (Eligibility Matrix)
  ↓
Gate 2: Context (pass-through, no real signal exists)
  ↓
Gate: User Preferences (Phase 16 — this phase)
  ↓
Gate 4: Already Informed
  ↓
Gate 5: Frequency
  ↓
Timing / Interruption Level (inform delivery, never reject)
  ↓
Notification Generator → Repository → Delivery
```

**Verification**: `test_eligibility_engine.py` extended with four
scenarios (7d–7g): a muted category blocks an otherwise-eligible
event with a named reason; a user with no profile document at all
still receives notifications (default-on, no migration); Critical
`RECOVERY_BECAME_IMPOSSIBLE` still delivers with `recovery` muted;
Normal-priority `RECOVERY_STARTED` IS muted by the same toggle,
proving the bypass is priority-specific. Full backend suite (13
files): zero regressions. Real-account verification against the real
account's live Firestore document (`_preferences_allow()` called
directly, isolated from Already Informed/Frequency history so the
result reflects the Preference Gate alone): muting `streaks` blocked
`LOGGING_STREAK_EXTENDED`, muting `recovery` blocked `RECOVERY_STARTED`
but not `RECOVERY_BECAME_IMPOSSIBLE` (Critical bypass), an untouched
category (`milestones`) still defaulted to allowed — account restored
to its original preference state (no `notifications` sub-map) exactly
afterward.

**Frontend**: `frontend/lib/screens/notification_preferences_screen.dart`
— 6 `SwitchListTile`s (Transactions/Budget Alerts/Financial Health/
Recovery/Streaks & Progress/Milestones), each defaulting on, backed by
`GET`/`PATCH /profile`'s existing `preferences` sub-map (sends the full
current `preferences` object with only `notifications` changed, to
avoid clobbering `language`/`currency`/`alertThreshold` on a partial
update — the same whole-object PATCH semantics the rest of `/profile`
already has). A highlighted amber callout states the Critical bypass
plainly ("Some critical financial alerts will still be delivered...").
Reachable from Profile → "Notification Preferences", between Goals and
the dev-only mock notification tile. `flutter analyze`: zero issues.

## Phase 16 follow-up — 5th "Duplicate Signal" Bug, Found via Real Usage

While asked to sanity-check the new Settings screen on-device, real
feedback surfaced a genuine, unrelated bug: a real account with income
Rs 24,500 and all 5 budget categories fully exhausted (Rs 14,500
total spent against Rs 14,500 total limit) correctly computes
`overallHealth.status: "red"` (`RECOVERY_IMPOSSIBLE`) on the backend —
confirmed directly via `compute_overall_health()` against the real
account's live data — yet the user reported the app visually looking
"fine" (green) after raising their income, even though no category
budget changed.

Root cause: `home_screen.dart`'s `_buildSnapshot()` ("Latest Activity"
card) computed its own `isOnTrack = totalExpense <= income` and used
that to color its own "ON TRACK"/"OVER" badge — entirely independent of
`_overallHealthStatus`, which this same screen already reads correctly
for its Health badge and greeting subtitle. Because `savingsPool`
(unallocated income) was never part of that local comparison, raising
income only widened the gap between `totalExpense` and `income`,
making the false-green badge look more confident, not less — exactly
matching "after I added the income it changed to green."

This is the same "duplicate signal" architectural flaw already found
and fixed 4 times earlier this session (ambient overlay, Categories
cards, Reports' Overall Status card, Health screen's own local color
functions) — a 5th instance, in a spot none of those passes touched.
Fixed the same way each time: deleted the local computation, consolidated
onto `HealthTheme.forStatus(_overallHealthStatus)` — badge label now
`OVER`/`WATCH`/`ON TRACK` for red/amber/green respectively.
`flutter analyze`: zero issues on both changed files.

## Phase 16 follow-up — 6th and 7th "Duplicate Signal" Bugs

Same real feedback continued: with the fix above rebuilt, the user
pointed out the Categories screen and the Home screen's main balance
card were STILL green with the same fully-exhausted account. Two more
instances of the identical architectural flaw, both threshold bugs
this time rather than a wrong-metric bug:

**6th instance — `categories_screen.dart`'s "TOTAL MONTHLY BUDGET"
banner.** Colored by `_spentPercent > 100` — strictly-greater-than, so
a category set exactly 100% spent (fully exhausted, the real account's
actual state: Rs 14,500 spent against Rs 14,500 total limit) evaluated
`false` and stayed green. This banner never read any backend signal at
all, unlike the rest of this same screen (which already reads real
`categoryHealth` per card, Phase 13.7). Fixed by fetching
`overallHealth.status` alongside the `categoryHealth` map this screen
already loads, and coloring the banner via
`HealthTheme.forStatus(_overallHealthStatus)` instead of the percent
threshold.

**7th instance — `home_screen.dart`'s `_isOverAllocatedBudget`
(drives the main `BalanceCard`'s Over Budget/Unused Budget coloring).**
Was `_totalBudgetSpent > _totalBudgetLimit` — the same
strictly-greater-than gap, and one this file's own comment had already
flagged as provisional ("Phase 3 will replace this once the Engine
exposes a health flag directly"). Rethresholded to
`_totalBudgetLimit > 0 && _unusedBudget <= 0` — `_unusedBudget` is
already a direct, unmodified read of the Engine's `remainingBudget`
(never a local subtraction), and `<= 0` is the exact same convention
`compute_recovery_plan()` already uses server-side to decide a category
is exhausted (`metrics_engine.py`, `exhausted = [... if remaining <= 0]`)
— so this card's threshold now agrees with the backend's own, instead
of inventing a second one.

**Verification**: both fixes checked directly against the real
account's actual `financialSummary`/`overallHealth` (income Rs 24,500,
5 categories, Rs 14,500 total limit == Rs 14,500 total spent,
`remainingBudget: 0.0`, `overallHealth.status: "red"`) —
`_overallHealthStatus` resolves to `red` (Categories banner now renders
`HealthTheme._red`) and `_isOverAllocatedBudget` resolves to `true`
(BalanceCard now renders "Over Budget"), both flipped from their
previous false-green outcomes on this exact data. `flutter analyze` on
both files: zero issues (2 files, only pre-existing-style const infos
on lines untouched by this change).

## Phase 17 — Pattern Spending Alerts — Design, FROZEN

Detects when today's spending in a category is unusually high compared
to the user's own recent baseline in that category, and notifies
through the same Notification Engine everything else in this app now
goes through — not a second, parallel alert system. Design decisions
below are frozen; implementation follows in the same commit/session.

**Detection algorithm** (`backend/services/pattern_service.py`, mirrors
`goal_service.py`'s plain-function/`db, uid, ...`-first convention):
- Fetch the category's confirmed, non-deleted expense transactions
  (`type == "expense"`, `status == "confirmed"`), capped at the 200
  most recent, ordered by `createdAt` descending — matching this
  codebase's existing convention (`utils.py`'s `is_today`/
  `is_in_current_month` etc.) of filtering by date client-side rather
  than a server-side range query, which would need a new composite
  Firestore index this app doesn't otherwise require.
- Group into daily totals by `createdAt`'s UTC date.
- Minimum trust gate: skip entirely (no anomaly possible) if fewer
  than 5 expenses have ever been logged in this category — matches
  the "5-8 logged expenses" floor already agreed; 5 chosen as the
  permissive end of that range.
- Baseline window: average of daily totals over the last 30 calendar
  days: if that window has at least 8 spending-days, use it as-is; if
  fewer (a newer or sparser category), fall back to the most recent 10
  spending-days regardless of calendar window, so a real but sparse
  history still gets a baseline instead of being starved by the 30-day
  cutoff.
- Threshold: flag if today's running total (including the transaction
  that just triggered this check) is at least 2x the baseline average.
  Rough heuristic, tunable later — same spirit as `_classify_pressure`'s
  first-cut thresholds in `metrics_engine.py`.
- Suggestion: `overage = todayTotal - baselineAverage`;
  `suggestedDailyAmount = max(0, baselineAverage - overage / 3)` for
  the next 3 days — spread the correction rather than a single "stop
  spending" message.
- Dedup: one flag per category per day. Enforced structurally by
  `eventId = f"{uid}:{today}:unusual_spending:{category}"` (Gate 4,
  Already Informed, rejects a repeat automatically), not a separate
  check inside `pattern_service.py` itself.

**New event `UNUSUAL_SPENDING_DETECTED`**, added to every matrix
`notification_generator.py`/`eligibility_engine.py` already keeps
(Rule 8 fails fast on any missing row, so every table needs an entry):
- Eligibility Matrix: `_ALWAYS` (the anomaly check itself is the
  justification — nothing further to gate at Eligibility's Gate 1/3).
- Priority: `High` (comparable to `CATEGORY_BECAME_EXHAUSTED` —
  timely and actionable, not Critical).
- Frequency: `DAILY`, but see the scoping fix below — this code fires
  for many different categories, the same shape of problem
  `MILESTONE_UNLOCKED` had with many different milestones.
- Timing: `IMMEDIATE` (the whole point is "tied to the specific
  transaction," not a batched daily digest).
- Template: `("TITLE_UNUSUAL_SPENDING", "Unusual {category} spending
  today", "You've spent Rs {todayTotal} on {category} today — about
  double your usual Rs {baselineAverage}", "Review {category}
  spending")` — English, matching every other row in `_TEMPLATES`
  (the Notification Center/Activity Feed read as one consistent
  language; only the chatbot's own conversational replies are
  Romanized Nepali, a distinct surface this event doesn't touch).
- Deep Link: `category_detail` (reused, same key
  `CATEGORY_BECAME_EXHAUSTED` already uses).
- Notification Preference category (Phase 16): `budgetAlerts` — the
  closest existing user-facing bucket to "alerts about my spending
  patterns," despite this event needing no budget/limit to exist at
  all (it's a pure pattern comparison, unlike `CATEGORY_BECAME_EXHAUSTED`).

**Frequency scoping, generalized instead of re-special-cased.**
`eligibility_engine._frequency_allows()`/`_most_recent_notification_for_code()`
previously hardcoded one exception (`payload.code` for
`MILESTONE_UNLOCKED` only, from the Phase 13.14 bug). Rather than add
a second hardcoded `if code == "UNUSUAL_SPENDING_DETECTED"` branch and
risk a third such bug going undetected for some future event,
generalized into one lookup: `_FREQUENCY_SCOPE_FIELD = {
"MILESTONE_UNLOCKED": "code", "UNUSUAL_SPENDING_DETECTED": "category"}`
— any event code sharing one eventCode across many distinct payload
identities registers its scoping field here once, and the lookup/match
logic is written once, generically, against whichever field is named.

**Architecturally new call site.** Every existing event so far is
produced by `scheduler_service.process_day()`'s nightly diff against
the previous day's snapshot — nothing today calls
`eligibility_engine.process_event()` synchronously from a live route.
`UNUSUAL_SPENDING_DETECTED` is deliberately the first to do so, called
from `pattern_service.check_spending_pattern()` right after the budget
increment in all three transaction-creation paths
(`routes/chat.py`'s `_handle_expense_or_income`,
`routes/transactions.py`'s manual-entry endpoint,
`routes/confirm.py`'s `confirm_transaction`) — required by the
"immediate, tied to the transaction" trigger timing agreed before this
phase was designed; a nightly diff cannot satisfy that requirement.
Delivery is best-effort (same as every other event, spec 5.8) and
never blocks the transaction's own success response.

**Scope decision: no separate chat-echo message.** The original plan
(written 2026-07-13, before this session's Notification Center existed)
wanted a bot message posted directly into chat history, specifically
so the nudge would be visible even without a dedicated notification
surface. Explicitly dropped now that the Notification Center/Activity
Feed (Phase 13.1) already gives equivalent-or-better visibility across
all three entry points uniformly — one delivery path, one copy to
maintain, instead of a second Romanized-Nepali copy living only in the
chat-origin path.

## Phase 17 — Pattern Spending Alerts — Implementation, FROZEN

Built exactly as designed above. `backend/services/pattern_service.py`
(new); `UNUSUAL_SPENDING_DETECTED` added to every matrix
`notification_generator.py`/`eligibility_engine.py` requires
(`_PRIORITY`, `_FREQUENCY`, `_TIMING`, `_TEMPLATES`, `_DEEP_LINKS`,
`_ALWAYS`, `_PREFERENCE_CATEGORY`); `_frequency_allows()`'s
scope-by-identity fix generalized from a single MILESTONE_UNLOCKED
special case into `_FREQUENCY_SCOPE_FIELD`, a small table any future
event with the same shape of problem can register into without a new
hardcoded branch. Wired into all three transaction-creation paths
(`chat.py`, `transactions.py`, `confirm.py`), each call best-effort and
non-blocking, matching the existing rebalance-check pattern already in
all three.

**A real query bug found and fixed during real-account verification,
before any real account was touched**: the original
`_recent_category_expenses()` chained `.order_by("createdAt")` on top
of three equality `.where()` filters, which Firestore rejected with
`FailedPrecondition: The query requires an index` — a genuinely new
composite index this app doesn't otherwise need. Fixed by dropping the
server-side `order_by`/`limit` entirely and sorting/capping in Python
instead, matching `utils.py`'s own `sum_category_expense()` (equality
filters only, no order_by) — no new Firestore index required.

**Verification**: `test_pattern_service.py` (new, 9 scenarios) tests
the pure decision core (`_detect_anomaly`, `_baseline_average`,
`_daily_totals`) directly against plain dicts, the same convention
`test_financial_engine.py` uses for its own pure pipeline stages — no
Firestore needed. `test_eligibility_engine.py` extended with a
regression scenario proving the generalized frequency-scoping fix
against a SECOND event code (not just the one, MILESTONE_UNLOCKED,
the underlying bug shape was originally found through): two different
categories sharing `UNUSUAL_SPENDING_DETECTED`'s eventCode are both
independently eligible the same day. Full backend suite (14 files):
zero regressions.

Real-account verification, two parts:
1. Against the real personal account (`BDpx6it7MeSZSrUJEBu9Bbwfp8l1`),
   confirmed the fix above (no crash) and correct negative-path
   behavior across all 6 real categories — every category correctly
   returned no anomaly, since none had any spending logged on the
   verification date at all (nothing to compare against).
2. Against the shared test account (`BvjbjFOGHQNmI1xcRm5xowKPpoB3`,
   safe to seed/clean up), a genuine positive path: seeded a Rs
   100/day baseline across 6 sparse days plus a real Rs 500 anomaly
   day, ran `check_spending_pattern()` for real — it detected the
   anomaly, computed `baselineAverage: 100`, `todayTotal: 500`,
   `suggestedDailyAmount: 0` (correctly floored at 0 rather than
   going negative — the 3-day spread math would have suggested
   -33.33/day), and a real notification was created and persisted in
   `generatedNotifications`. A second same-day call correctly
   returned `None` (deduped by `eventId` + Gate 4, Already Informed).
   All 7 seeded transactions and the notification doc were deleted
   afterward — the test account was left exactly as it started.

## Phase 17 follow-up — Category Health Materiality Bug, Found via Real Usage

Real feedback while looking at the Categories screen ("the Rent card
should have changed color too"): Rent was spent Rs 1,000 against a Rs
900 limit (111% over — genuinely `CATEGORY_EXHAUSTED`), yet its card
showed green. Root cause, confirmed against the real account: Rent's
limit is ~4.4% of the total budget, under `HEALTH_MATERIALITY_THRESHOLD`
(5%), so `_evaluate_category_rules()` (`health_engine.py`) short-circuited
to `LOW_MATERIALITY` before ever checking exhaustion — a category too
small to move the Overall Health *aggregate* was also having its own
individual card's true status suppressed, which was never the intent
of materiality (spec Phase 3.0, Q4: a tiny category "shouldn't
single-handedly move Overall Health" — nothing about hiding its own
honest status when the user is looking directly at it).

This one was a deliberate, tested, frozen design decision from Phase
3.2 (`test_health_engine.py` scenario 4 explicitly asserted
"materiality gates before exhaustion" for the category's own card) —
not a coding mistake, so it was raised as a design question rather
than silently changed. Confirmed: materiality should affect only
Overall Health's aggregate (unchanged — still correctly applied in
`_evaluate_rules()`'s `MULTIPLE_CATEGORIES_PRESSURED`/
`CATEGORY_HIGH_PRESSURE` logic); a category's own card should always
report its true exhaustion/pressure status regardless of size.

**Fixed**: removed the materiality short-circuit from
`_evaluate_category_rules()` entirely — exhaustion and pressure are
now always evaluated honestly for every category. `_build_category_
decision_trace()`'s materiality line kept as context only ("affects
Overall Health only"), no longer gating what follows it.

**Verification**: `test_health_engine.py`'s scenario 4 rewritten —
a non-material category with `CATEGORY_EXHAUSTED` now correctly
returns red (was asserting green before), and a new case confirms a
non-material `CATEGORY_HIGH_PRESSURE` (not exhausted) escalates to
amber too. Decision-trace assertions updated to match the always-full
waterfall. Full backend suite (14 files): zero regressions.
Real-account re-verification against `BDpx6it7MeSZSrUJEBu9Bbwfp8l1`:
Rent now correctly resolves to `red`/`CATEGORY_EXHAUSTED`; "Other" and
"Health" (genuinely under-spent, not merely small) correctly remain
green — confirming the fix escalates true exhaustion without
introducing noise for categories that are simply quiet.

## Frontend follow-up — Out-of-Order Response Race, Found via Real Usage

Real feedback, working through the fixes above: after a genuine
budget-rebalance transfer (confirmed correct via direct Firestore
checks each time — donor category's limit really did decrease,
target category's limit really did increase, every time), the
Categories/Home screens sometimes kept showing pre-rebalance numbers
(e.g. a card stuck at `Rs 4910 / Rs 4800`, exactly `todaySpent /
oldLimit` from just before that category's own rebalance had
confirmed) — even after a pull-to-refresh, and in one case even after
a full app restart.

Root cause: none of `categories_screen.dart`'s `_fetchFinancialSummary()`,
`home_screen.dart`'s eight per-widget fetch functions, or
`reports_screen.dart`'s `_loadReport()` guarded against their own
responses arriving out of order. Each of these screens can legitimately
be asked to refetch twice in quick succession (an expense's own refresh
trigger, then the rebalance-confirmation dialog's refresh trigger
moments later; or a lifecycle-resume racing a manual pull-to-refresh).
If the *older* request's response happened to arrive after the newer
one — which real network timing makes entirely possible — its
`setState()` silently overwrote the fresher data, and nothing else was
scheduled to fire and correct it. The older response wasn't corrupt
data either — it was a real, valid backend snapshot from the narrow
window between the transaction saving (updating `spent` immediately)
and the rebalance being confirmed (updating `limit` moments later) —
just no longer the current truth by the time it got applied.

**Fixed** in all three files with the same pattern: a monotonically
incrementing generation counter (`_fetchToken`/`_fetchGeneration`/
`_loadGeneration`), incremented once per fetch batch. Each async fetch
function captures the counter's value at its own start and checks it
still matches before ever calling `setState()` — a response whose
generation has been superseded by a newer fetch is discarded outright,
regardless of arrival order. Applied to every `setState()` site in all
three files' fetch paths, including `catch`/`else` branches (a stale
error handler resetting `_isLoading` after a newer fetch already
started was an equally real instance of the same bug).

**Verification**: `flutter analyze` clean on all three files (only
pre-existing, unrelated const-hint infos). No backend change was
needed or made — every real-account check throughout this
investigation confirmed the rebalance/budget-transfer math itself was
correct the entire time; this was purely a client-side display race,
never a money-movement bug.

## Backend follow-up — Stale Cached Summary After Rebalance, Found via Real Usage

The frontend race fix above turned out to only be a partial
explanation. Real feedback continued with a precise, deterministic
pattern: after a rebalance, exactly one category (the one *most
recently* rebalanced) kept showing pre-rebalance numbers indefinitely
— surviving a pull-to-refresh and even a full app restart — until a
completely unrelated *later* transaction happened to "fix" it.

Root cause: `financial_engine.get_summary()` (spec Section 0 — "the
only way anything reads calculated values") does not recompute fresh
from `budgets`/`transactions` on every call. It reads a cached
`financialSummary/{monthKey}` document and only self-heals by calling
`recompute()` if that document is missing entirely. `budget_service.
apply_pending_rebalance()` — the function that actually applies a
confirmed rebalance — writes directly to the raw `budgets` collection
(the overspent category's new limit, each donor's reduced limit) but
never called `recompute()` afterward. So the cached summary kept
reflecting the pre-rebalance limit indefinitely, and the only thing
that ever refreshed it was some unrelated *later* event that happened
to call `recompute()` on its own (every transaction-creation path
already does) — which is exactly the "always one category behind,
fixed only by the next transaction" pattern real usage caught. This
was never a frontend display race; the backend's own source of truth
was stale.

**Fixed**: added `RecomputeReason.REBALANCE_APPLIED` and a
`financial_engine.recompute()` call at the end of
`apply_pending_rebalance()`, right after the budget writes and alert
creation, best-effort (a recompute failure here must never undo the
rebalance that already succeeded).

**Verification**: a real end-to-end test against the shared test
account (`BvjbjFOGHQNmI1xcRm5xowKPpoB3`) — seeded a real overspend
(Rs 210 spent against a Rs 200 limit), proposed and confirmed a real
rebalance via `rebalance_on_overspend()`/`apply_pending_rebalance()`,
then called `get_summary()` immediately afterward with **no other
transaction in between** — `categoryRemaining.limit` correctly showed
`210` (matching the new, post-rebalance limit) right away, where
before this fix it would have stayed at the stale `200` until some
unrelated later event triggered a recompute. Test budget and
rebalance docs deleted afterward. Full backend suite (14 files): zero
regressions.

## Phase 18 — Goal Risk — Design, FROZEN

Answers a different question than Overall Health: not "is my spending
healthy" but "given my current spending pace, will I actually
contribute enough to THIS goal to stay on its own timeframe." A goal
can be at risk while spending is perfectly healthy (a lower-priority
goal correctly starved by a higher-priority one), and spending can be
unhealthy while every goal still happens to be on pace — two genuinely
different concerns, deliberately kept as two signals, never merged.

**Definition.** For each active goal:
- `monthlyTarget = targetAmount / timeframeMonths` — already computed
  today in `financial_engine._calculate_goal_impact`, reused as-is.
- `projectedContribution` — this goal's share of `projectedSavings.value`
  (Metrics Engine's already-existing Predictive forecast of end-of-month
  savings pool under current spending pace), split across active goals
  by the *exact same* priority-tier waterfall `goal_service.
  compute_goal_progress()` already uses for the CURRENT pool — reused,
  never reinvented, just fed a different pool value.
- `GOAL_AT_RISK` if `projectedContribution < monthlyTarget`, carrying
  `shortfall = monthlyTarget - projectedContribution`.
- Confidence inherited from `projectedSavings.confidence` (never
  "high" — same reason Projected Savings itself is never high-confidence:
  it assumes future behavior, per its own frozen design).
- Not computed (not flagged, not a false negative either) when
  `projectedSavings` is `None` — no budgets exist yet, nothing to
  project from; Health must always be able to explain itself, never
  guess past missing inputs.

**Ownership, keeping the existing calculation/judgment split intact**:
- The *calculation* — splitting a pool across goals by priority tier —
  already lives in `goal_service.py`. The tier-splitting logic inside
  `compute_goal_progress()` gets extracted into a shared private
  helper so a new `compute_projected_goal_progress(db, uid, month_key,
  projected_pool)` can reuse it against the projected pool instead of
  duplicating the waterfall. `compute_goal_progress()`'s own behavior
  is unchanged.
- The *judgment* — is that projected contribution enough, and how
  urgently — belongs in `health_engine.py`, as a new
  `compute_goal_risk()` alongside `compute_overall_health`/
  `compute_category_health`/`compute_risk_flags`. It only compares
  numbers goal_service/metrics_engine already computed (Rule 1: Health
  never computes financial values, only classifies already-computed
  ones).

**Surfacing, confirmed before starting**: `GOAL_AT_RISK` is added to
`_RISK_SEVERITY` (existing Risk Flags list) so it reaches the user
through infrastructure that already exists, rather than inventing a
new UI concept. It deliberately does NOT feed into
`_evaluate_rules()`/Overall Health's own status color — the two
questions ("is spending healthy" vs "is this specific goal on pace")
stay genuinely separate signals, matching the reasoning above.

## Phase 18 — Goal Risk — Implementation, FROZEN

Built exactly as designed above. `goal_service.py`'s tier-splitting
waterfall extracted from `compute_goal_progress()` into a pure
`_distribute_pool_across_tiers(goals, pool)`, reused unchanged by both
`compute_goal_progress()` (current pool, behavior unchanged) and the
new `compute_projected_goal_progress(db, uid, projected_pool)`.
`health_engine.py` gained `compute_goal_risk()` (reads `monthlyTarget`
from `financial_engine.get_summary()`'s already-computed
`goalProgress`, never re-derives it) and `_goal_risk_flags()` (pure,
converts an already-computed `goalRisk` dict into flag entries —
kept separate from `_build_risk_flags()` so that function's own
"no Firestore needed to test" property stays intact for its existing
callers). `GOAL_AT_RISK` added to `_RISK_SEVERITY` (medium, same tier
as `RECOVERY_NEEDED`/`CATEGORY_HIGH_PRESSURE`) and merged into
`compute_risk_flags()`'s output. `/financial-health` now returns
`goalRisk` alongside `overallHealth`/`categoryHealth`/`riskFlags`.

**A real invariant test caught the expected, honest gap between Goal
Risk and Goal Protection**: `test_recommendation_engine.py` asserts
every Risk Flag code has a Recommendation Matrix row (added earlier
specifically to catch exactly this class of gap), and `GOAL_AT_RISK`
correctly failed it — there's no recommendation for it yet, because
that's Goal Protection, a separate, not-yet-built phase, per the
user's own explicit ordering. Fixed by naming `GOAL_AT_RISK` as a
deliberate, documented exception in that test (`_NOT_YET_RECOMMENDED`)
rather than either silently weakening the invariant or rushing a
placeholder recommendation ahead of its own design pass.

**Verification**: `test_goal_service.py` (new, 8 scenarios) tests
`_distribute_pool_across_tiers` directly against plain dicts (empty
goals, zero pool, single-tier full/partial funding, proportional
same-tier splitting, higher tier fully funded before lower tier sees
anything) and `compute_projected_goal_progress()` via a minimal fake
Firestore (completed goals correctly excluded). `test_health_engine.py`
extended with 5 scenarios for `_goal_risk_flags()` (only at-risk goals
produce flags, shortfall/confidence carried through, empty/`None`
input never crashes). Full backend suite (15 files): zero regressions.

Real-account verification against `BDpx6it7MeSZSrUJEBu9Bbwfp8l1`: the
account's real `projectedSavings.value` is currently `-4541.36` (a
genuine projected deficit — every category budget is exhausted this
month), so `_distribute_pool_across_tiers` correctly gives every goal
`0.0` projected contribution regardless of priority, and both real
goals ("trip," `monthlyTarget: 10000`; "laptop," `monthlyTarget:
50000`) correctly resolve to `GOAL_AT_RISK` with their full
`monthlyTarget` as `shortfall`. Confirmed both flags appear correctly
in `compute_risk_flags()`'s full output, sorted by severity alongside
the account's existing `CATEGORY_EXHAUSTED`/`PROJECTED_DEFICIT`/etc.
flags — not a synthetic test, the real account's real current
financial state.

## Phase 19 — Goal Protection — Design, FROZEN

Answers "what can the user actually do" about a `GOAL_AT_RISK` flag
(Phase 18) — closing the deliberate, named gap
`test_recommendation_engine.py` caught when Goal Risk shipped.

**Constrained by how this engine already works, not a new mechanism.**
`recommendation_engine.py` is a pure Matrix lookup (Risk Flag code ->
recommendation code/type/actionValue/expiresWhen) — no recommendation
anywhere carries a human sentence; that's a separate, still-unbuilt
"Explainer" phase named elsewhere in this spec. Goal Protection stays a
structured fact, not worded coaching copy, to match every other row.

**Explicit scope decision, confirmed before starting**: surfaces only
the shortfall fact ("this goal is Rs X short of its monthly target
this month"), not a suggested spending cut. A cut-suggestion would
need a genuinely new metric — what "discretionary spending" even means
in this app doesn't exist as a concept anywhere today — and inventing
that arithmetic inside the Recommendation Engine would violate Rule 4
("every actionValue is read directly from an existing field, never
computed here"). Deferred as its own future decision, not built now.

**New Matrix row**: `"GOAL_AT_RISK": {"code":
"INCREASE_GOAL_CONTRIBUTION", "type": "protect", ...}`. `"protect"` is
a genuinely new recommendation type — none of the existing five
(recover/stop/reduce/monitor/maintain) fit "put more toward this
specific goal," so the frozen type taxonomy grows by one rather than
force-fitting an ill-matching label.

**`actionValue` = the flag's own `shortfall`** — already computed by
`compute_goal_risk()` (Phase 18), read directly off the flag, never
recomputed here. Same precedent as `CATEGORY_EXHAUSTED`'s fixed `0`:
a pre-resolved value, not a fresh Metrics Engine lookup.

**`_build_recommendation()` generalized**, not special-cased: today it
threads exactly one "which thing does this concern" field
(`category`) from flag to recommendation object. Extended to also
carry `goalId`/`goalName` when present on the flag, mirroring the
existing `category` field exactly rather than inventing a
goal-specific code path. `_goal_risk_flags()` (health_engine.py, Phase
18) gains a `goalName` field on its flags for this — Health Engine
already has the name via `financial_engine.get_summary()`'s
`goalProgress`, so this is a pass-through, not a new lookup.

## Phase 19 — Goal Protection — Implementation, FROZEN

Built exactly as designed above. `_RECOMMENDATION_MATRIX` gained
`"GOAL_AT_RISK" -> "INCREASE_GOAL_CONTRIBUTION"` (type `"protect"`,
a genuinely new addition to the frozen taxonomy). `_lookup_action_value()`
reads the flag's own `shortfall` directly for `GOAL_AT_RISK` — no new
metric, no arithmetic, matching `CATEGORY_EXHAUSTED`'s precedent of a
pre-resolved value rather than a fresh Metrics Engine lookup.
`_build_recommendation()` generalized to thread `goalId`/`goalName`
from flag to recommendation object exactly like the existing `category`
field, rather than a goal-specific code path; `_build_healthy_
recommendation()` and `_build_recommendation_trace()` updated to match.
`health_engine.py`'s `compute_goal_risk()`/`_goal_risk_flags()` (Phase
18) gained the `goalName` pass-through this phase needed.

**Verification**: `test_recommendation_engine.py` — the Phase 18
exception (`GOAL_AT_RISK` deliberately excluded from the "every Risk
Flag has a Matrix row" invariant) removed now that it has one; the
frozen type taxonomy extended with `INCREASE_GOAL_CONTRIBUTION ->
protect`; the one exact-dict-equality test (`RECOVERY_NEEDED`) updated
to include the two new always-present `goalId`/`goalName` keys; one
new dedicated scenario confirms `GOAL_AT_RISK` produces
`INCREASE_GOAL_CONTRIBUTION` with `actionValue` equal to the flag's
own shortfall, correct `goalName`/`goalId` threading, and a
goal-specific `expiresWhen`. `test_health_engine.py` extended to
assert `goalName` is carried on `GOAL_AT_RISK` flags. Full backend
suite (15 files): zero regressions.

Real-account verification against `BDpx6it7MeSZSrUJEBu9Bbwfp8l1`:
`compute_recommendations()` correctly produced two
`INCREASE_GOAL_CONTRIBUTION` alternatives, one per real at-risk goal
("trip," `actionValue: 10000`; "laptop," `actionValue: 50000`, each
exactly matching that goal's real `monthlyTarget`/shortfall since
`projectedContribution` is currently `0` for both, per Phase 18's
already-verified negative-projected-savings state), each correctly
named via `goalName`/`expiresWhen` — not synthetic data, the account's
real current recommendations.
