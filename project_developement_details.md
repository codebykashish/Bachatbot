# BachatBot — Project Development Documentation

This document explains what BachatBot is, how it is built, why it is built that way, and exactly how every part of the system works — from a user typing a message in chat, to a number appearing on a chart, to a notification landing on a phone. It is written in plain language on purpose, so it is useful both as a technical reference and as material for explaining the project to someone who has never seen the code.

---

## Table of Contents

1. [What is BachatBot](#1-what-is-bachatbot)
2. [Tech Stack](#2-tech-stack)
3. [High-Level Architecture](#3-high-level-architecture)
4. [Authentication & Security](#4-authentication--security)
5. [Database (Firestore) — Schema & Indexes](#5-database-firestore--schema--indexes)
6. [The Financial Engine (the heart of the backend)](#6-the-financial-engine-the-heart-of-the-backend)
7. [Behavior Engine (streaks, milestones, habits)](#7-behavior-engine-streaks-milestones-habits)
8. [Notification Engine](#8-notification-engine)
9. [Weekly Reflection ("Your Week in Money")](#9-weekly-reflection-your-week-in-money)
10. [The Chatbot (Gemini integration)](#10-the-chatbot-gemini-integration)
11. [API Endpoints Reference](#11-api-endpoints-reference)
12. [Frontend Architecture (Flutter)](#12-frontend-architecture-flutter)
13. [Development Methodology](#13-development-methodology)
14. [Known Limitations & Deliberately Deferred Work](#14-known-limitations--deliberately-deferred-work)

---

## 1. What is BachatBot

BachatBot is a conversational personal-finance / expense-tracking app built for people in Nepal. The core idea: most expense trackers are form-heavy, English-only, and give you numbers with no real understanding of your situation. BachatBot instead lets you **just tell it what you spent, in your own language** ("Momo 250", "khaja ma 300 kharcha bhayo", "spent 500 on food") — in Nepali, Roman Nepali, or English — and it logs it, tracks it, and tells you what it actually means for your month.

**Target users**: young adults in Nepal — students and early-career workers — who use mobile money (eSewa, Khalti, IME Pay) and want low-friction expense tracking without spreadsheets or forms. The onboarding flow itself asks about occupation (student / employed / business) and housing (rent / own), confirming this is the intended audience.

**What makes it different from a normal expense tracker**:
- You talk to it like a person, not a form.
- It doesn't just record numbers — it has a whole decision-making pipeline (described in Section 6) that understands whether your month is going well, why, and what to actually do about it.
- It builds habits (streaks, milestones) the way a habit app would, but tied to real money behavior.
- Every week, it writes you a short, honest reflection on what happened with your money — not a wall of charts, a few sentences.

---

## 2. Tech Stack

| Layer | Technology |
|---|---|
| Mobile app | Flutter (Dart) — Android/iOS/Windows |
| Backend API | FastAPI (Python) |
| Database | Google Firestore (NoSQL, document-based) |
| Authentication | Firebase Authentication |
| AI / Chat | Google Gemini (via `google-generativeai` / Gemini API) |
| File storage | Cloudinary (profile photos) |
| Push notifications | Firebase Cloud Messaging (FCM) |
| Scheduled jobs | APScheduler (in-process cron: monthly rollover, daily snapshot, pre-month-end reminder) |
| Charts | fl_chart (Flutter) |
| Email | SMTP (OTP codes, contact-us form) |

---

## 3. High-Level Architecture

```
┌─────────────────┐        HTTPS (Bearer token)        ┌──────────────────────┐
│   Flutter App    │ ─────────────────────────────────> │   FastAPI Backend     │
│ (Android/iOS/Win)│ <───────────────────────────────── │  (routes/ + services/)│
└─────────────────┘              JSON                   └──────────┬───────────┘
                                                                     │
                                                     reads/writes    │
                                                                     v
                                                          ┌─────────────────────┐
                                                          │  Google Firestore    │
                                                          │  (users/{uid}/...)   │
                                                          └─────────────────────┘
                                                                     ^
                                                     verified via    │
                                                                     │
                                                          ┌─────────────────────┐
                                                          │   Firebase Auth       │
                                                          └─────────────────────┘

Backend also calls out to:
  - Google Gemini API      (chat understanding + responses)
  - Cloudinary              (profile photo upload)
  - SMTP server             (OTP emails, contact form)
  - Firebase Cloud Messaging (push notifications)
```

The backend is organized as **routes** (thin HTTP handlers, one file per resource — `routes/chat.py`, `routes/goals.py`, `routes/budgets.py`, etc.) calling into **services** (the actual logic — `services/financial_engine.py`, `services/health_engine.py`, `services/behavior_engine.py`, etc.). This separation matters a lot for one specific reason, explained in detail in Section 6: **calculations happen in exactly one place, and every other layer reads the result instead of recalculating it.**

---

## 4. Authentication & Security

### How a request proves who it is

Every protected endpoint depends on a single function: `get_current_user(request)` in `backend/auth.py`. Here is exactly what happens on every request:

1. The Flutter app attaches an `Authorization: Bearer <firebase-id-token>` header to every API call (see Section 12 for how the app gets and attaches this token).
2. The backend checks the header exists — if missing, it returns `401 MISSING_TOKEN`.
3. It checks the header actually starts with `"Bearer "` — if not, `401 INVALID_TOKEN_FORMAT`.
4. It checks there's an actual token after `"Bearer "` — if empty, `401 EMPTY_TOKEN`.
5. It hands the token to Firebase Admin SDK's `auth.verify_id_token(token, check_revoked=False)`. This checks the token's cryptographic signature and expiry against Firebase's servers.
6. On success, the full decoded token (containing `uid`, `email`, and other claims) is returned and made available to the route handler as `current_user["uid"]`.
7. On failure, the specific Firebase exception is mapped to a specific error: `TOKEN_EXPIRED`, `INVALID_TOKEN`, `TOKEN_REVOKED`, or a generic `AUTH_FAILED`.

**A note worth being transparent about**: the call passes `check_revoked=False`, even though a comment beside it says the opposite. In practice this means if a user is force-logged-out server-side, their existing token still works until it naturally expires (Firebase ID tokens expire after 1 hour by default) — it isn't instantly invalidated. This is a minor, known gap, not an active exploit path (a stolen token is already time-limited to begin with), but worth fixing by simply changing that one flag to `True` if stronger logout guarantees are ever needed.

### User isolation

Every route reads `uid = current_user["uid"]` from the verified token and scopes every Firestore query to `users/{uid}/...`. There is no endpoint that reads another user's data by ID — the `uid` always comes from the token, never from a request parameter, so one user cannot address another user's data even by guessing an ID.

### CORS and middleware

- CORS is currently wide open (`allow_origins=["*"]`) — a development-time convenience, not a production hardening choice.
- A custom logging middleware runs on every request: it normalizes accidental double-slash URLs (a defensive fix for a Flutter client bug), logs which `uid` made the request (by independently calling `get_current_user`, swallowing any failure so it never blocks the real request), logs the first 500 characters of POST bodies, and logs the final response status code. This is observability only — it does not enforce anything; the actual auth enforcement is the route's own `Depends(get_current_user)`.

### Backend startup

Firebase is initialized once when the backend process starts. Three scheduled jobs start alongside the API (via APScheduler, in-process — no external cron): a monthly budget rollover (1st of the month, 00:01), a pre-month-end reminder (28th of the month, 10:00), and a nightly full-account snapshot (00:30 daily) that also seeds behavior-tracking events.

---

## 5. Database (Firestore) — Schema & Indexes

Firestore is a NoSQL document database — data is organized as **collections** of **documents**, and documents can contain **subcollections** of their own. Almost everything in BachatBot lives under one document per user: `users/{uid}`.

### Full collection tree (verified against actual code, not just the design docs)

```
users/{uid}
├── (root fields)  firstName, lastName, email, phone, photoUrl, fcmToken,
│                  onboarding{isCompleted, occupation, housingType,
│                  estimatedMonthlySpend, tourCompleted}, income{inHand,
│                  inBank, onlineBanking, total}, preferences{language,
│                  currency, alertThreshold, notifications{...}},
│                  createdAt, updatedAt
│
├── transactions/{transactionId}
│     amount, category, type (expense|income|transfer),
│     status (confirmed|pending|cancelled),
│     source (chat|manual|notification|offline_sync),
│     description, monthKey, isDeleted, deletedAt,
│     originalMessageId, idempotencyKey, createdAt, updatedAt
│
├── budgets/{budgetId}
│     category, limit, spent, alertThreshold, monthKey, createdAt, updatedAt
│
├── goals/{goalId}
│     name, targetAmount, timeframeMonths, priority, status (active|completed),
│     isDeleted, createdAt, updatedAt
│     (progress numbers like savedSoFar/percentComplete are NEVER stored here —
│      they're computed fresh every time from transactions + budgets, see Section 6)
│
├── messages/{messageId}                       — chat history
│     role, parts, content (legacy), intent, extractedData,
│     relatedTransactionId, status, createdAt
│
├── pendingAction/current                       — single fixed document
│     actions, pendingTxIds, source, monthKey, waitingForBudget,
│     waitingCategory, createdAt
│     (tracks "the bot is waiting for a yes/no or a category" state)
│
├── notifications/{notificationId}              — parsed bank/wallet SMS
│     rawText, parsedAmount, parsedCategory, parsedType, sourceApp,
│     status, transactionId, receiverName, suggestedCategory, createdAt
│
├── generatedNotifications/{id}                 — backend-generated proactive
│     notifications (budget alerts, streak nudges, etc.) — separate from the
│     bank/wallet SMS notifications above
│
├── alerts/{alertId}                            — the in-app alert feed
│     type, category, message, severity, isRead, isDeleted, monthKey,
│     relatedTransactionId, createdAt
│
├── monthlyReports/{monthKey}                   — cached generated report
│     totalExpense, totalIncome, netSavings, categoryBreakdown,
│     budgetUtilization, daysRemaining, survivalBudgetPerDay,
│     alertCount, generatedAt
│
├── financialSummary/{monthKey}                 — the Financial Engine's
│     persisted monthly output (income, budgets, goalProgress, savingsPool)
│
├── dailySnapshots/{isoDate}                    — one full point-in-time
│     rollup per day (financial + metrics + health + categoryHealth +
│     recommendation + behaviorState + behaviorSummary), written by the
│     nightly cron job
│
├── weeklyReflections/{isoDateOfMonday}         — one per completed week
│     weekStart, weekEnd, generatedAt, opening, highlights, concerns,
│     pattern, goalContext, nextStep, observationMetadata, interpretation
│
├── behaviorState/{docId}                       — live streak/habit tracking state
├── behaviorHistory/{docId}                     — historical behavior transitions
├── events/{eventId}                            — behavior-event log
├── pending_rebalances/{rebalanceId}             — proposed budget transfers
│     awaiting user confirmation after an overspend
└── budgetMonthMeta/{monthKey}                  — per-month rollover metadata

verification_codes/{email}                      — top-level, NOT under users/
                                                    (pre-signup OTP codes)
```

### Firestore composite indexes

Firestore needs a pre-declared "composite index" whenever a query filters/sorts on more than one field in a way its automatic single-field indexes can't cover. These live in `backend/firestore.indexes.json`. Currently defined:

| Collection | Fields (in query order) |
|---|---|
| `transactions` | `monthKey` ↑, `status` ↑, `createdAt` ↓ |
| `transactions` | `type` ↑, `status` ↑, `isDeleted` ↑, `createdAt` ↓ |
| `transactions` | `source` ↑, `status` ↑, `createdAt` ↓ |
| `alerts` | `isRead` ↑, `createdAt` ↓ |
| `alerts` | `monthKey` ↑, `createdAt` ↓ |
| `budgets` | `category` ↑, `monthKey` ↑ |
| `notifications` | `status` ↑, `createdAt` ↓ |

These were added reactively — the project has hit "this query requires an index" errors in real use before (documented in the spec's own changelog) and added the specific index needed each time, rather than pre-declaring every possible combination. One query shape in `routes/transactions.py` (filtering by `isDeleted` + `status` + `source`, sorted by `createdAt`) does not exactly match any of the 7 indexes above and could hit the same error if it's ever exercised at scale — worth an eye if that endpoint starts failing.

---

## 6. The Financial Engine (the heart of the backend)

This is the most important architectural idea in the whole backend, and everything else is built to respect it:

> **One number is calculated in exactly one place. Every other layer reads that number — it never recalculates it.**

Without this rule, you'd end up with (for example) the Home screen computing "days remaining in month" one way, and the Reports screen computing it slightly differently, and the two silently disagreeing. The whole backend is structured as a **pipeline of engines**, each one only allowed to consume the previous engine's *already-computed* output:

```
Transactions/Budgets/Income (raw Firestore data)
        │
        v
┌─────────────────┐
│  Metrics Engine   │  turns raw data into numbers: days remaining, budget
│                   │  utilization %, recommended daily spend, spending pace,
│                   │  category pressure, projected savings, recovery plan
└────────┬──────────┘
         v
┌─────────────────┐
│  Health Engine    │  classifies those numbers into a simple status:
│                   │  green / amber / red — for the month overall AND per
│                   │  category — plus a list of "risk flags" (named reasons
│                   │  something needs attention). Health NEVER computes a
│                   │  financial value itself, it only classifies what the
│                   │  Metrics Engine already computed.
└────────┬──────────┘
         v
┌──────────────────────┐
│ Recommendation Engine │  looks at the risk flags and picks exactly ONE
│                        │  action to suggest — never a checklist. Every
│                        │  number it shows (e.g. "try Rs 200/day") is read
│                        │  directly from an existing engine field, never
│                        │  computed fresh inside the Recommendation Engine.
└────────┬───────────────┘
         v
   Health screen / Home / Chat / Notifications / Weekly Reflection
   (all just DISPLAY what the engines already decided)
```

### Metrics Engine (`services/metrics_engine.py`)

Computes, from raw transactions/budgets/income:
- **Days remaining in month**
- **Budget utilization** — % of each category's budget spent
- **Recommended daily spend** — how much you can safely spend per day for the rest of the month
- **Category daily target** — same idea, per category
- **Spending pace** — are you spending faster or slower than a "flat" pace would predict
- **Recovery plan** — if you've overspent, is recovery still mathematically possible, and if so, what daily amount gets you back on track
- **Category pressure** — which categories are trending toward trouble even if not over yet
- **Projected savings** — a forward-looking (never a fact, always a forecast) estimate of what you'll end the month with, based on current pace

### Health Engine (`services/health_engine.py`)

Takes the Metrics Engine's numbers and answers "is this okay?":
- **Overall Health** — one status for the whole month: `green` (good shape), `amber` (stable, worth a look), `red` (needs attention). Comes with a `primaryReason` — the single most important true fact driving that status, never a vague feeling.
- **Category Health** — the same green/amber/red idea, per category.
- **Risk Flags** — a list of specific, named problems (e.g. `PROJECTED_DEFICIT`, `CATEGORY_EXHAUSTED`, `SPENDING_TOO_FAST`, `GOAL_AT_RISK`), sorted by severity. This is the list the Recommendation Engine and Notification Engine both read from.
- **Goal Risk** — for each active savings goal, whether you're projected to fall short of this month's needed contribution, and by how much (the shortfall is a real computed number, reused everywhere it's mentioned — never re-guessed).

### Recommendation Engine (`services/recommendation_engine.py`)

Looks at the risk flags (highest severity first) and maps each one to exactly one recommendation code (e.g. `STOP_CATEGORY_SPENDING`, `REDUCE_CATEGORY_SPENDING`, `LIMIT_DAILY_SPENDING`, `START_RECOVERY_PLAN`, `INCREASE_GOAL_CONTRIBUTION`). Two hard rules:
- **One recommendation per problem** — never a checklist of five things to fix at once. Overwhelming a stressed user with a list is the opposite of helpful.
- **Every number shown is read from an existing field** — the Recommendation Engine is never allowed to compute a new number itself; it only picks *which already-computed number* to surface.

### Goal Protection

When a goal is at risk (per Goal Risk above), the Recommendation Engine can surface `INCREASE_GOAL_CONTRIBUTION`, telling you exactly how much short you're projected to be this month. This is deliberately scoped to *reporting the shortfall* — a deeper feature (suggesting exactly which discretionary spending to cut to close that gap) was designed but intentionally left unbuilt for now, to avoid the Recommendation Engine starting to invent financial advice beyond what the Engine can actually verify.

### Why recompute-on-read instead of storing pre-calculated numbers?

Almost everything above is calculated **fresh, on every request** (`recompute()` in `services/financial_engine.py`), not stored once and reused. The `financialSummary/{monthKey}` document is a cache of the *last* computed result, but any transaction, budget, or income change triggers a fresh recompute so the cache never goes stale. The alternative — incrementing/decrementing stored totals every time a transaction changes — is exactly the kind of bug-prone pattern (an edited or deleted transaction forgetting to reverse its effect on some cached total) this design deliberately avoids. It costs a bit more computation per request; it buys correctness that doesn't depend on every code path remembering to update every derived number.

---

## 7. Behavior Engine (streaks, milestones, habits)

Separate from the Financial Engine, the Behavior Engine (`services/behavior_engine.py`) tracks *habits*, not money amounts. It watches four kinds of behavior:

- **Logging streak** — how many days in a row you've logged at least one expense. Miss a day, it resets to 1.
- **Spending behavior** — a "healthy spending streak": days where your spending stayed within a healthy range.
- **Saving behavior** — a "protection streak": months where your savings goal contribution stayed on track.
- **Recovery behavior** — tracks when you're actively recovering from an overspend, and for how long.

These four feed into a single **Behavior Summary status**: `excellent` / `good` / `building` / `needs_improvement` / `inactive` — a plain-language read on "how are your money habits going right now," independent of whether your month's numbers are green or red (you can have red finances and still be in "building" habit-wise, because habits and current-month numbers are different questions).

**Milestones** are one-time unlockable achievements (e.g. hitting a 7-day, 30-day, 90-day streak) — stored per user, each with `unlocked` (bool) and `unlockedAt` (timestamp), never re-locked once earned.

A nightly cron job (`services/scheduler_service.py`, 00:30 daily) creates a full **daily snapshot** — a point-in-time rollup of everything (financial + metrics + health + behavior) — partly so the Weekly Reflection feature (Section 9) has real historical data to look back on instead of only ever seeing "right now."

---

## 8. Notification Engine

BachatBot doesn't just fire a notification every time something happens — a huge amount of design went into deciding **when a notification is actually worth interrupting someone for**. The Notification Engine is split into clear stages, each with its own philosophy:

1. **Eligibility** (`services/eligibility_engine.py`) — for each possible notification type, is the user's preference for that category turned on? Are the underlying conditions actually met? A notification that fails eligibility never gets generated at all.
2. **Priority** — how urgent is this, relative to everything else that might also be true right now?
3. **Frequency** — how often is this *type* of notification allowed to repeat (you don't want a budget-pressure nudge every single time you spend anything).
4. **Timing** — notifications are never sent at a "random" moment; timing follows a deliberate philosophy (e.g. not the middle of the night, not immediately re-triggering).
5. **Generation** (`services/notification_generator.py`) — turns an eligible, prioritized, correctly-timed signal into actual human-readable text, using a template matrix (one template per notification code) rather than freeform text generation.
6. **Repository** (`services/notification_repository.py`) — persists notifications idempotently: the same underlying event never creates two duplicate notifications.
7. **Delivery** (`services/delivery_service.py`) — sends the notification via Firebase Cloud Messaging to the user's registered device token.

### Notification preferences

Users can toggle categories on/off (Budget Alerts, Financial Health, Recovery, Streaks & Progress, Milestones) from Settings. One category — "Transactions" — used to exist but controlled two event types (`TRANSACTION_CREATED`, `TRANSACTION_CONFIRMED`) that were later found to be redundant with the app's existing in-app alert system (a separate, already-working mechanism for showing "you just logged X" feedback). Rather than building a notification producer that would just duplicate that existing signal, those two event types — and the now-pointless toggle controlling them — were removed outright.

---

## 9. Weekly Reflection ("Your Week in Money")

Every completed week (Monday–Sunday), BachatBot writes a short, honest reflection on what happened — not a dashboard, a few sentences a person would actually read. This is the newest and most carefully staged feature in the backend, built as a five-stage pipeline (`services/weekly_reflection_service.py`):

1. **Observation** — gathers the *raw facts* for that week only: transactions, budgets (as they existed that week — never today's budget misattributed to a past week), health snapshots, behavior state, and any pattern-spending alerts. Nothing is interpreted yet, just collected.
2. **Interpretation** — turns those raw facts into a small number of structured findings: **highlights** (things that went well — e.g. a category comfortably under budget, a logging streak), **concerns** (things worth watching — e.g. a category that crossed 80% usage), a **pattern** (an unusual spending pattern, if one was flagged that week), and **goal context** (how your goal pace looked that week). Selection between competing candidates is always deterministic (e.g. "pick the category with the highest amount," never random), so re-running the same week produces the same reflection.
3. **Composition** — turns the structured findings into actual sentences, using a fixed tone principle (written down and enforced with tests): *"the reflection is observational, supportive, and actionable. It describes facts without shame, exaggeration, artificial urgency, or moral judgment."* Words like "overspent" or "fail" are deliberately never used.
4. **Persistence** — saves the finished reflection once, permanently, at `weeklyReflections/{weekStart}`. Idempotent: asking for the same week's reflection twice returns the exact same saved document, never a re-generated (and potentially different) one.
5. **Flutter UI** — a dedicated screen (not folded into Reports or Health, because it answers a different question: "what did I learn this week," not "what are my numbers" or "am I okay right now") plus a small preview card on the Home screen.

**The Account Existence Boundary** — a rule added after finding a real bug during testing: if a week entirely predates when the account was created, there's no honest reflection to write (budgets aren't stored historically, so "today's limit" can't be safely attributed to a week before the account existed). In that case the endpoint returns `{"data": null}` — an honest "nothing to show yet," not an error, and not a fabricated reflection.

---

## 10. The Chatbot (Gemini integration)

### Model and setup

The chatbot uses Google's **`gemini-2.5-flash`** model via the `google-generativeai` Python SDK. The API key lives in a `.env` file next to `backend/gemini.py` (`GEMINI_API_KEY`). A fresh Gemini model object is created for **every single chat request**, with that request's context injected as a `system_instruction` — this keeps the actual conversation history clean (the instructions aren't repeated as fake conversation turns), which the code notes "dramatically improves multi-turn context retention."

### The System Prompt — what Gemini is actually told to do

Gemini is given one large (~420-line) rulebook, not a JSON schema. It's told, in short:

> "Make expense tracking feel effortless. Be friendly and SHORT. Ask when things are unclear instead of guessing. NEVER block expense logging because budget is not set. Always return a `DATA[...]DATA` JSON array at the end of every reply."

The rulebook covers, in order: multi-turn slot-filling (asking for amount, then category, one at a time, if a message is incomplete), a one-time-only onboarding greeting, small talk handling, strict yes/no rules (a "yes" only means something if the bot itself just asked a yes/no question), the core expense/income logging rules, budget-aware behavior, and a full glossary mapping Nepali/Roman-Nepali words to the app's fixed expense categories (with explicit disambiguation — e.g. "bhada" alone is ambiguous between Transport's "gadi bhada" and Rent's "ghar bhada," so the bot is told to ask rather than guess).

**Output format**: not Gemini's structured-output/function-calling feature — a deliberately simple, custom convention. Every reply must end with a JSON array wrapped in `DATA[ ... ]DATA`, which the backend extracts with a regex, not a schema validator. Each object in that array has fields like `intent`, `amount`, `category`, `type`, `incomeSource`, `limit`, `monthKey`, `confirmed`, etc. If Gemini's reply doesn't match the expected pattern at all, the backend quietly treats it as harmless small talk rather than surfacing an error to the user.

### What Gemini is allowed to know and say (and what it's explicitly not)

Before every Gemini call, the backend builds a small "USER CONTEXT" block and injects it:

```
FirstName: ...
FirstMessage: true/false
MissingBudgetCategories: [...]
HealthStatus: green/amber/red/unknown
TopRiskCategory: ... or 'none'
AtRiskGoal: "<goal> short by Rs <amount>" or 'none'
```

Every one of those facts is read directly from an engine that already computed it (Health Engine, Risk Engine) — nothing is calculated inside the prompt-building code itself. The prompt is explicit and strict about the boundary this creates:

> "You may ONLY state facts explicitly present in this context block. Never calculate a new financial fact, never invent an amount, category, goal, or cause beyond what's given here."
>
> "Never state a specific number, category, or amount because of HealthStatus alone — HealthStatus shapes how you say things, never what you claim is true."

For anything bigger — "how much did I spend this month," "what's my top spending category" — Gemini doesn't even try to answer with a number. It just recognizes the *intent* (e.g. `query_top_spend_category`) and the backend's Python code looks up the real number from the Financial Engine and writes the reply itself. This is the same "engine computes, chat only explains" rule that governs the rest of the backend (Section 6), applied to the chatbot specifically so it can never state a financial fact it wasn't handed.

### Walking through a real message: "momo 250"

1. The message is saved to `users/{uid}/messages` immediately.
2. The last 20 messages are fetched to give Gemini conversation memory (roles are cleaned up so they strictly alternate user/model — Gemini's API requires that).
3. If the user currently has a **pending transaction awaiting a yes/no answer**, the message is checked for "yes"/"no" *before Gemini is even called* — this whole confirmation flow is handled in plain Python, not by asking the LLM again (see below).
4. Otherwise, Gemini is called with the message, history, and context block.
5. Gemini decides: is this a *clear* expense (has a spending verb like "khaye"/"spend"/"kharcha") → log immediately; or *ambiguous* (just an amount and an item, no verb) → ask one yes/no confirmation first ("momo ma Rs 200 kharcha garnu bhayo?").
6. If it's a clear expense with a category: the backend checks whether a budget exists for that category. If yes, it's saved as `confirmed` immediately, the budget's `spent` is incremented, an alert is created, and the Financial Engine is told to recompute. If no budget exists yet, the expense is still saved (never blocked!) as `pending`, and the bot asks (but never forces) whether to set a budget.
7. A reply is composed — mostly from **hard-coded Nepali/English template strings in the Python backend**, not Gemini's own free-text output, for anything involving a real number (e.g. `"Rs 250 Food ma kharcha gareko ✅"`). Gemini's role is mainly to extract *what* happened; the backend decides *how to say it back* for anything structured.
8. The assistant's reply is saved to `messages`, and the response (reply text + any transaction/budget/alert data) is sent back to the app.

### Confirming, correcting, or cancelling via chat

- **Pending confirmation** ("did you mean X?") is tracked in a single document, `pendingAction/current`. A plain "yes"/"ho"/"thik cha" confirms it (transaction flips to `confirmed`, budget updates, alert fires); a plain "no"/"chaina"/"haina" cancels it. This check happens *before* Gemini is asked anything — it's handled entirely by simple keyword matching (`is_affirmative`/`is_denial`, with both English and Nepali words recognized).
- **Corrections** ("oops, it was Transport not Food") are a dedicated Gemini intent (`correction`) that updates the existing transaction's fields in place, rather than deleting and re-creating it — this preserves the transaction's ID and history, and was a deliberate fix for an earlier bug where amount-only corrections could silently delete money without re-logging it.
- **Setting a budget right after being asked** auto-confirms any expense that was waiting on that budget — no separate yes/no needed.

### Bank/wallet notification parsing (eSewa, Khalti, IME Pay)

When a bank or wallet SMS notification is intercepted on the device, it's sent to the *same* `/chat` endpoint, but flagged with `source: "notification"` — which sends it down a completely separate, simpler path:
- A short, dedicated prompt (not the big conversational one) just extracts `{amount, category, type, uncertain}` from the raw notification text.
- A separate, non-AI regex layer tries to pull out the merchant/receiver name (e.g. "paid to X", "Merchant: X") to help guess a category.
- The resulting transaction is **always saved as `pending`, never auto-confirmed** — the prompt is explicit: *"Never auto-log transactions. Every detected transaction must be reviewed."* The user still has to confirm it via a follow-up chat message, using the same yes/no mechanism as any other pending transaction.

### Guardrails, verbatim

- *"NEVER block expense logging because budget is not set."*
- *"Ask when things are unclear instead of guessing... Do NOT guess. Do NOT log immediately. Ask once, clearly."*
- *"You may ONLY state facts explicitly present in this context block. Never calculate a new financial fact, never invent an amount, category, goal, or cause beyond what's given here."*
- *"Only treat 'yes/no' as confirmation when YOU just asked a yes/no question in the immediately preceding turn."*
- *"For ALL income, ALWAYS use `income_log` intent... NEVER use `expense_log` for income."*
- (Notification prompt) *"Never auto-log transactions. Every detected transaction must be reviewed."*

There's no explicit "never give investment advice" sentence in the prompt — but the bot structurally can't, since it only has a fixed vocabulary of intents (expense/income/budget/report) and is barred from asserting anything beyond what the engines already computed.

---

## 11. API Endpoints Reference

Every endpoint below requires `Authorization: Bearer <firebase-id-token>` unless marked "no auth". Grouped by what they're for.

### Account & Signup
| Endpoint | What it does |
|---|---|
| `POST /check-email` | Checks if an email is already registered (enforces @gmail.com domain). *No auth.* |
| `POST /send-verification-code` | Generates a 6-digit OTP, emails it via SMTP. *No auth.* |
| `POST /verify-code` | Validates the OTP; deletes it once used so it can't be replayed. *No auth.* |
| `POST /complete-signup` | Creates the Firestore user profile after Firebase signup completes. Idempotent — calling it again just returns the existing profile. |
| `GET /profile` (also `GET /api/v1/user/profile`) | Returns the full profile, plus `totalIncome`/`totalExpense` for the Home screen. Self-heals: if no profile exists yet, one is created. |
| `PATCH /profile` | Updates name/phone/password/onboarding answers/preferences. Password changes are verified against the stored hash first. |
| `POST /upload/profile-photo` | Uploads an image to Cloudinary, returns the URL (frontend then PATCHes `/profile` with it). |
| `GET`/`POST /logout` | Revokes the Firebase token server-side. |
| `POST /contact` | Sends a Contact-Us message via SMTP. *No auth.* |

### Chat
| Endpoint | What it does |
|---|---|
| `POST /chat` (alias `POST /messages`) | The main chatbot endpoint — see Section 10 for the full pipeline. |
| `POST /chat/sync` | Processes a batch of messages that queued up while the phone was offline, in original order. |
| `GET /messages` | Chat history, oldest-first, paginated via `before=<messageId>`. |
| `DELETE /messages/{message_id}` | Soft-deletes one chat message. |

### Transactions
| Endpoint | What it does |
|---|---|
| `POST /transactions/manual` | Add an expense directly from a category page (mirrors what chat does — writes the transaction, increments budget, creates an alert). |
| `GET /transactions` | List transactions for a month, filterable by status. |
| `GET /transactions/pending/notifications` | Lists transactions still awaiting confirmation that came from a bank/wallet notification. |
| `POST /transactions` | Manually create a transaction. |
| `GET /transactions/{id}` | Fetch one transaction. |
| `PUT /transactions/{id}` | Edit a transaction (always triggers an Engine recompute). |
| `DELETE /transactions/{id}` | Soft-delete (only if it was a confirmed, counted transaction does this trigger a recompute). |
| `POST /confirm-transaction/{id}` | Confirm one pending transaction, with optional amount/category override. |
| `POST /confirm-transactions` | Bulk confirm or cancel a list of pending transactions in one call. |
| `POST /reject-transaction/{id}` | Reject a pending transaction outright. |
| `POST /confirm-rebalance/{id}` / `POST /reject-rebalance/{id}` | Accept or reject a proposed budget-rebalance (moving money between categories after an overspend). |

### Budgets
| Endpoint | What it does |
|---|---|
| `GET /budgets` | All budgets for a month, with `percentUsed` calculated. |
| `POST /budgets` | Create/update a category's monthly limit. Supports `dryRun` to preview a rebalance plan without writing anything. |
| `POST /budgets/confirm` | Marks a month's budgets as "confirmed" (stops pre-month-end reminders). |
| `DELETE /budgets/{category}` | Delete a budget — only allowed if nothing's been spent against it yet. |

### Reports
| Endpoint | What it does |
|---|---|
| `GET /monthly-report` | The main Reports data — `view=today\|week\|month`, category breakdown, daily breakdown. |
| `GET /monthly-report/year-summary` | One total per calendar month (powers the Reports month-strip). Added in this UI-refinement phase. |
| `GET /daily-summary` | Quick "today" snapshot for the Home screen (top category, one-line summary). |

### Alerts & Notifications
| Endpoint | What it does |
|---|---|
| `GET /alerts` | The in-app alert feed, filterable by type/category/date/read-status. |
| `PATCH /alerts/{id}/read` | Mark one alert read. |
| `POST /alerts/{id}/undo` | Reverse an alert's financial effect (e.g. undo the expense it logged) and soft-delete it. |
| `POST /notifications/device-token` | Register/replace this device's FCM push token. |
| `POST /notifications/{event_id}/read` / `/dismiss` | Mark a backend-generated notification read/dismissed. |

### Income & Goals
| Endpoint | What it does |
|---|---|
| `GET`/`POST /income` | View/update declared income sources (in-hand, bank, online banking). |
| `GET`/`POST /goals` | List / create a savings goal. |
| `PATCH`/`DELETE /goals/{id}` | Edit or delete a goal. |

### The Engines (read-only, always fresh — see Section 6)
| Endpoint | What it does |
|---|---|
| `GET /financial-summary` | Remaining budget, category remaining, savings pool, goal progress, income, total spent. |
| `GET /financial-metrics` | Days remaining, spending pace, projected savings, recovery plan, category pressure. |
| `GET /financial-health` | Overall health, category health, risk flags, goal risk. |
| `GET /financial-recommendations` | The single primary recommendation + alternatives. |
| `GET /behavior` | Streak summary, raw behavior state, all milestones (locked and unlocked). |
| `GET /weekly-reflection` | The most recent completed week's reflection (generates it on first request, then cached). |
| `GET /debug/engine-health` | Dev-only: metadata from the last recompute (for debugging, not user-facing). |

### Misc
| Endpoint | What it does |
|---|---|
| `GET /` | Root health-check. |
| `GET /health` | Server health-check. |

---

## 12. Frontend Architecture (Flutter)

### How the app starts

`main.dart` initializes Firebase, sets up background push-notification handling, and turns on Firestore's offline cache before showing `SplashScreen`. The splash screen decides where to send you:
- Never onboarded before → `GetStartedScreen` → a 3-page feature carousel → email signup → OTP verification → name/phone/password → income setup → initial category budgets → `MainScreen`.
- Already onboarded and logged in → straight to `MainScreen`.
- Already onboarded but logged out → `LoginScreen`.

### The bottom navigation (`main_screen.dart`)

The four tabs (Home, Categories, Reports, Profile) are **not separate routes** — they're four widgets built once and kept alive inside an `IndexedStack`, with a `_currentIndex` switching which one is visible. This means switching tabs doesn't reload anything; each tab screen keeps its own scroll position and state.

To let `MainScreen` force a tab to refresh (e.g. after you log an expense in chat, so Home's numbers update), each tab screen exposes a `GlobalKey` and a public `refresh()` method — `MainScreen` just calls `_homeKey.currentState?.refresh()` rather than rebuilding the whole widget tree. `MainScreen` also owns several always-running background services (see below), a floating action button that opens the chat screen, and a first-run "spotlight tour" that highlights key UI elements for new users.

### How the app talks to the backend (`api_service.dart`)

Every request goes through one class, `ApiService`. The pattern is always the same:
1. Get the current Firebase ID token (force-refreshed every time, so it should never be stale).
2. Attach it as `Authorization: Bearer <token>`.
3. Make the request.
4. If the server says `401` (token rejected), refresh the token once and retry automatically — the user never sees a random logout from a token that just happened to expire mid-session.

The backend's address is currently a **hardcoded URL string** in this file (an ngrok tunnel address, since the backend runs on a developer machine rather than a deployed server) — there's no environment/build-flavor switch, so pointing the app at a different backend means editing this one line.

Errors aren't swallowed at this layer — a failed request throws an exception that the calling screen decides how to handle (usually: log it and quietly keep showing whatever data it already has, rather than a scary error screen).

### State management: deliberately simple

There is **no Provider, Riverpod, Bloc, or similar state-management library** in this app. Every screen is a plain `StatefulWidget` that calls `setState()` after fetching data — a deliberate choice to keep the app straightforward rather than adding an architecture layer the project didn't need. For the few things that genuinely need to be shared *across* screens (the streak count shown in the top bar, the notification unread badge, the overall health status used for the app-wide color tint), there are small hand-written singleton services exposing a `ValueNotifier` that any widget can listen to with `ValueListenableBuilder` — a lightweight alternative to a full state-management package.

### Always-running background services

A handful of services are started once, when `MainScreen` first loads, and live for the whole app session:
- **`NotificationSyncService`** / **`SmsSyncService`** — watch for incoming Android system notifications and SMS messages that look like a bank/wallet transaction (regex-matched, e.g. "credited/debited ... NPR"), and forward them into the chat pipeline as `source: "notification"` messages (Section 10).
- **`PushNotificationService`** — Firebase Cloud Messaging setup, plus local notification display.
- **`ActivityFeedService`** — a live Firestore listener merging alerts + generated notifications, powering the notification-bell unread badge everywhere, even on screens that never open the feed itself.
- **`AlertPopupService`** — watches for new alerts and pops up an in-app banner.
- **`BehaviorPreviewService`**, **`MonthEventService`**, **`HealthThemeService`** — small caches so the top bar's streak badge, the month-rollover banner, and the app-wide ambient color tint don't each need their own full API fetch.

### Design system — an honest gap

There is **one** theme file (`theme/health_theme.dart`), and it's narrowly scoped to the green/amber/red health-status visual language — it is not a general design system. There's no shared file for the brand color, spacing, or typography: the primary green (`#2DBE7F`) is redeclared as a local constant independently in nearly every screen file, by convention rather than a single source of truth. This works today because the color hasn't needed to change, but it's the reason "Health Theme System" was named as the first UI-refinement priority in this project's later phase (Section 13) — extending `HealthTheme` centrally, rather than letting each screen invent its own status colors, is a direct fix for this gap.

### Key third-party packages

| Purpose | Packages |
|---|---|
| Auth | `firebase_auth` |
| Backend platform | `firebase_core`, `cloud_firestore` (offline persistence on) |
| Notifications | `firebase_messaging`, `flutter_local_notifications` |
| SMS/notification capture | `notification_listener_service`, `another_telephony` |
| Networking | `http`, `http_parser` |
| Charts | `fl_chart` |
| Media | `image_picker` |
| Local storage | `shared_preferences` |
| Fonts | `google_fonts` |
| Formatting | `intl` |

---

## 13. Development Methodology

This project was built using a deliberately disciplined, repeatable process for every non-trivial feature, applied the same way whether the feature was a backend engine or a UI screen:

```
  Design  →  Freeze  →  Implement  →  Unit Test  →  Real-Account Test  →  Freeze
```

**What each step actually means here:**

1. **Design** — before any code, write down exactly what the feature means in plain terms (e.g. "a goal is at risk if projected contribution < this month's needed contribution"), what data it needs, and what it explicitly will *not* do yet. Ambiguous cases are resolved with an explicit decision, not left implicit.
2. **Freeze** — once the design is agreed, it's written into `backend/FINANCIAL_ENGINE_SPEC.md` as a dated, permanent record, before implementation starts. This spec file is effectively the project's engineering diary — every phase (Metrics Engine, Health Engine, Notification Engine, Behavior Engine, Goal Risk, Goal Protection, Weekly Reflection, etc.) has its design and its implementation each frozen as their own dated section.
3. **Implement** — write the code to match exactly what was frozen, no scope creep, no "while I'm here" extras.
4. **Unit Test** — dedicated test files (`backend/tests/test_*.py`) cover each engine's pure logic with fake/minimal data, so the core decision-making can be verified without touching a real database.
5. **Real-Account Test** — every feature was also verified against one real Firestore account with real transactions, not just synthetic test fixtures — catching things unit tests can't (e.g. a real bug where a past week's reflection used *today's* budget limit instead of what existed at the time, fixed by the "Account Existence Boundary" rule in Section 9).
6. **Freeze** — once verified for real, the outcome (including real numbers from the real-account test) is written back into the spec as permanent documentation, and the feature is considered done — not touched again except for a deliberate, separately-designed change.

### Other recurring principles

- **"Engine computes, everything else reads."** Named repeatedly throughout this document because it's the single most-enforced rule in the codebase — see Section 6.
- **One recommendation, never a checklist.** The Recommendation Engine and the chatbot both follow this — overwhelming a user with a list of five things to fix is worse than one clear thing.
- **Deterministic, never random.** Anywhere the system has to pick one thing among several candidates (which category to highlight, which milestone, which pattern), the tie-breaking rule is explicit and fixed, so the same data always produces the same output.
- **Idempotency by default.** Anything that shouldn't happen twice (a daily snapshot, a weekly reflection, a notification) checks for its own existence first and returns the existing result unchanged, rather than risking a duplicate.
- **Removing code counts as progress.** When the phantom `TRANSACTION_CREATED`/`TRANSACTION_CONFIRMED` notification events were found to duplicate an already-working alert mechanism, they were deleted outright rather than "fixed" — a smaller, more honest system was treated as the win, not a compromise.
- **Verify against real code/data, not assumptions.** Several designs in this project were revised mid-flight specifically because checking the real code turned up a detail the initial design had gotten wrong (e.g. the pre-account-week budget bug above). The process treats "I checked and confirmed" as different from — and more trustworthy than — "this should work."

---

## 14. Known Limitations & Deliberately Deferred Work

Being transparent about what's *not* done, and why, is part of this documentation's job — not everything below is a bug; most of it is a conscious scope decision.

| Item | Status | Why |
|---|---|---|
| Discretionary-spending-cut suggestions for Goal Protection | Designed, not built | Goal Protection currently only reports the shortfall amount; suggesting *which* spending to cut would require the Recommendation Engine to start making judgment calls beyond what it can verify from existing data. Left for a future, separately-designed pass. |
| "Available buffer" fact for Chat Context | Designed, not built | Chat Context v2 was deliberately scoped to exactly two facts (`TopRiskCategory`, `AtRiskGoal`) to keep the "chat only states given facts" rule airtight; a third fact was named as a future candidate, not added yet. |
| Interruption Level / Context Gate (notification attention-awareness) | Designed, not built | A deeper idea for deciding *when* someone is in the right headspace to be interrupted by a notification. Explicitly deprioritized as "later architectural refinement" — the current Notification Engine (Section 8) already has eligibility/priority/frequency/timing, which covers most of the same goal more simply. |
| Duplicated budget/rebalance-waterfall logic in Transactions/Chat | Known tech debt | An older, additive-only version of the rebalance calculation still lives inline in a couple of route files instead of reusing the shared helper extracted for Goal Risk. Functionally fine today; flagged for a cleanup pass. |
| `check_revoked=False` in token verification | Known gap | See Section 4 — a force-logged-out user's token still works until natural expiry (up to ~1 hour) rather than being instantly rejected. Low risk (tokens are already time-limited), easy one-line fix if stronger guarantees are ever needed. |
| Wide-open CORS (`allow_origins=["*"]`) | Development-time convenience | Fine for a project in active development against an ngrok tunnel; would need tightening before any real production deployment. |
| Hardcoded backend URL in the Flutter app | Known gap | `api_service.dart`'s `baseUrl` is a literal string (currently an ngrok tunnel), not environment/build-flavor driven — switching backends means editing code, not a config flag. |
| No central design-token file (colors/typography) beyond `HealthTheme` | Known gap, actively being addressed | The brand color is redeclared per-file by convention. This is exactly why "Health Theme System" was prioritized first in the UI-refinement phase — centralizing status-driven styling so screens stop each inventing their own version. |
| `resolve_category_from_receiver_name()` (notification merchant-name → category mapping) | Stub, always returns `None` | Documented as a future extension point — the merchant-name map (`_RECEIVER_CATEGORY_MAP`) is currently empty. |
| One un-indexed query shape in `routes/transactions.py` (`isDeleted`+`status`+`source`+`createdAt`) | Potential future error | Doesn't exactly match any of the 7 defined Firestore composite indexes; could hit a "query requires an index" error under real load, the same class of issue the project has hit and fixed reactively before (Section 5). |
| Alternate/legacy signup screen (`signup_screen.dart`) alongside the main flow | Likely dead code | Appears to duplicate the `email_signup_page.dart` → `code_verification_page.dart` → `signup_details_page.dart` chain; not confirmed wired into any active route. Worth a cleanup pass to confirm and remove if genuinely unused. |

Everything else described in this document — the full Financial Engine pipeline, Behavior Engine, Notification Engine, Weekly Reflection, the chatbot, and every screen in the current Flutter app — is complete, tested, and verified against a real account as of this writing.

