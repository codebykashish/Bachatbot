# Financial Engine Specification

This is the "constitution" of BachatBot's money logic. It exists so that
every future feature is checked against a written rule instead of being
reimplemented from scratch in a new file with a slightly different formula
(which is how the app ended up with two different "savings priority"
implementations — one in `budget_service.py`, one in `routes/budgets.py` —
before this spec existed).

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
| 2 | Financial Metrics — daily allowance, projected savings, spending pace, days remaining |
| 3 | Health & Risk Engine — green/amber/red, health scores |
| 4 | Recommendation Engine — recovery suggestions, coaching insights |
| 5 | Notification Engine — alerts, unusual spending, timing rules |
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

Each phase ships and is verified before the next starts — phase N+1 always
assumes phase N's numbers are already trustworthy.
