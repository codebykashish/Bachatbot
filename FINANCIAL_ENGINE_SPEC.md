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
`recompute` ran, not because something patched it inline.

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

### Phase 1 — What the Engine receives (inputs only)

The Engine works only with raw data — it never receives an already-computed
value:

- Income (declared, from the user doc)
- Budgets (category, limit, spent — as currently persisted)
- Transactions (for anything Phase 1 needs beyond the `spent` counters)
- Savings Goals (target, timeframe, priority)
- Current date (for days-remaining-style math in later phases)

It never receives remaining budget, health, colors, recommendations, or
daily allowance as input — those only ever come out of the Engine, never
into it. (Health/colors/recommendations aren't Phase 1's job at all — see
the roadmap — but the rule holds from here forward: once something is an
output, it is never fed back in as an input.)

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

Each phase ships and is verified before the next starts — phase N+1 always
assumes phase N's numbers are already trustworthy.
