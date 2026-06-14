# BachatBot — API & Firestore Schema

---

## REST API Endpoints

### Profile

| Method | Path                  | Alias         | Auth | Description                          |
|--------|-----------------------|---------------|------|--------------------------------------|
| GET    | /api/v1/user/profile  | GET /profile  | JWT  | Get current user's full profile      |
| PATCH  | /api/v1/user/profile  | PATCH /profile| JWT  | Update profile fields / password / photoUrl |
| POST   | /api/v1/user/profile  |               | JWT  | Create initial profile after signup  |

> `/profile` and `/api/v1/user/profile` are identical aliases — both are registered.
> Frontend may use either path; the backend handles both.

**PATCH /profile — Accepted fields (all optional):**
`firstName`, `lastName`, `phoneNumber`, `onboarding`, `preferences`, `photoUrl` (string, Cloudinary URL), `currentPassword`, `newPassword`, `confirmNewPassword`

**GET /profile — Response shape:**
```json
{
  "success": true,
  "data": {
    "uid": "abc123",
    "firstName": "Ram",
    "lastName": "Sharma",
    "email": "ram@example.com",
    "phoneNumber": "+97798XXXXXXXX",
    "photoUrl": "https://res.cloudinary.com/..." ,
    "onboarding": { "isCompleted": true, "occupation": "student", "housingType": "rent", "estimatedMonthlySpend": 15000 },
    "preferences": { "language": "en", "currency": "NPR", "alertThreshold": 80 },
    "totalIncome": 45000,
    "totalExpense": 15000,
    "recentTransaction": {
      "id": "txn_abc123",
      "type": "expense",
      "amount": 250,
      "category": "Food",
      "note": "Momo khada",
      "createdAt": "..."
    },
    "createdAt": "...",
    "updatedAt": "..."
  }
}
```
> `photoUrl` is `null` if the user has not uploaded a profile photo.  
> `recentTransaction` is `null` if the user has no transactions yet.

---

### Chat

| Method | Path          | Auth | Description                        |
|--------|---------------|------|------------------------------------|
| POST   | /chat         | JWT  | Send a chat message to BachatBot   |
| POST   | /messages     | JWT  | Alias for POST /chat               |
| GET    | /messages     | JWT  | Get paginated chat history         |
| POST   | /chat/sync    | JWT  | Batch-process offline messages     |

**GET /messages — Query params:**
- `limit` (int, default 50, max 200) — number of messages to return
- `before` (string, optional) — message document ID for cursor pagination

**GET /messages — Response shape:**
```json
{
  "success": true,
  "data": {
    "messages": [
      {
        "id": "msg_abc",
        "role": "user",
        "parts": [{ "text": "200 momo khaye" }],
        "intent": null,
        "extractedData": null,
        "createdAt": "..."
      }
    ],
    "hasMore": false,
    "nextCursor": null
  }
}
```
Messages are returned in **chronological order** (oldest first).
The backend never clears message history; it is persistent per user.

**POST /chat — Request body:**
```json
{
  "message": "aja maile 500 momo ma khaye",
  "source": "chat",
  "idempotencyKey": "optional-uuid"
}
```

**POST /chat — Response shape:**
```json
{
  "success": true,
  "data": {
    "reply": "Rs 500 Food (momo) ma save gareko chu",
    "intent": "expense_log",
    "needsConfirmation": false,
    "transaction": { "id": "...", "amount": 500, "category": "Food", "type": "expense", "status": "confirmed" },
    "budgetUpdate": { "id": "...", "category": "Food", "limit": 5000, "spent": 1500, "remaining": 3500, "percentUsed": 30.0 },
    "alerts": [{ "id": "...", "type": "expense", "message": "Rs 500 Food expense saved.", "category": "Food", "severity": "low", "isRead": false }]
  }
}
```

---

### Gemini Chat Intents

These are the `intent` values the backend processes from Gemini's response:

| Intent                    | type field      | Description                                       |
|---------------------------|-----------------|---------------------------------------------------|
| expense_log               | "expense"       | Log an expense transaction                        |
| income_log                | "income"        | Log an income transaction — NEVER use expense_log for income |
| set_budget                | null            | Create or update a category monthly budget        |
| confirm_expense           | null            | User confirmed a pending expense                  |
| query_report              | null            | Daily / weekly / monthly spending report          |
| query_month_total         | null            | Total expense for current month                   |
| query_top_spend_category  | null            | Which category has highest spend this month       |
| query_spend_feedback      | null            | AI suggestion based on spending patterns          |
| query_category_spend      | null            | Spend total for a specific category               |
| query_budget_status       | null            | Budget utilization for a specific category        |
| undo_last_expense         | null            | Soft-delete the most recent expense               |
| set_notification_category | null            | Assign category to a pending notification tx      |
| general_chat              | null            | Conversational reply, no DB action                |
| greeting                  | null            | Greeting response                                 |

**Income rule:** For any income message, Gemini MUST emit `income_log` with `type: "income"`.
`expense_log` is never used for income. The alert created for income reads:
`"Rs {amount} income added."` (NOT "expense saved").

---

### Notifications

| Method | Path                          | Auth | Description                                   |
|--------|-------------------------------|------|-----------------------------------------------|
| POST   | /chat (source:"notification") | JWT  | Parse a wallet/bank notification              |
| POST   | /confirm-transactions         | JWT  | Confirm or reject pending notification txs    |
| GET    | /alerts                       | JWT  | Fetch alerts with filters                     |

**GET /alerts — Supported query params:**
- `monthKey` (string, optional) — default: current month. Not applied for yesterday/last_week dateRange queries (cross-month support).
- `type` = `"expense"` | `"income"`
- `category` = `"Food"` | `"Transport"` | etc.
- `dateRange` = `"today"` | `"yesterday"` | `"week"` | `"last_week"` | `"month"` | `"all"`
  - `yesterday` and `last_week` do **not** restrict by monthKey (cross-month safe)
- `isRead` = boolean
- `limit` (int, default 20)

**Notification alert types:**
- `type: "expense"` → message: `"Rs {amount} {category} expense saved."`
- `type: "income"`  → message: `"Rs {amount} income added."`
- `type: "budget_set"` → message: `"{category} budget Rs {limit} set gareko chu."`

---

### Transactions (Manual)

| Method | Path                      | Auth | Description                                        |
|--------|---------------------------|------|----------------------------------------------------|
| POST   | /transactions/manual      | JWT  | Manually add an expense from category detail page  |

**POST /transactions/manual — Request body:**
```json
{
  "category": "Food",
  "amount": 250.0,
  "note": "Momo khada",
  "monthKey": "2026-04"
}
```
> `note` and `monthKey` are optional. If `monthKey` is omitted, current month is used.

**POST /transactions/manual — Side effects:** saves transaction + increments `budget.spent` (if budget exists for that category+month) + creates alert. Same side effects as chat-logged expenses.

**POST /transactions/manual — Response shape:**
```json
{
  "success": true,
  "message": "Expense added successfully.",
  "data": {
    "transactionId": "txn_abc123",
    "category": "Food",
    "amount": 250.0,
    "monthKey": "2026-04",
    "budgetUpdate": {
      "id": "budget_abc",
      "category": "Food",
      "limit": 5000,
      "spent": 2250,
      "remaining": 2750,
      "percentUsed": 45.0
    }
  }
}
```
> `budgetUpdate` is `null` if no budget is set for that category.

---

### Income

| Method | Path      | Auth | Description                                      |
|--------|-----------|------|--------------------------------------------------|
| GET    | /income   | JWT  | Get declared income sources (inHand, inBank, onlineBanking, total) |
| POST   | /income   | JWT  | Set/update income sources; creates alert per changed source |

**POST /income — Request body (all fields optional, partial update supported):**
```json
{
  "inHand": 5000.0,
  "inBank": 15000.0,
  "onlineBanking": 3000.0
}
```

**GET /income — Response shape:**
```json
{
  "success": true,
  "data": {
    "inHand": 5000.0,
    "inBank": 15000.0,
    "onlineBanking": 3000.0,
    "total": 23000.0
  }
}
```

**POST /income — Side effects:** updates `users/{uid}.income.*` via dot-notation; creates one alert per changed source (e.g. "Rs 5000 added to In Hand income." / "In Bank income updated to Rs 15000.").

---

### Upload

| Method | Path                      | Auth | Description                                      |
|--------|---------------------------|------|--------------------------------------------------|
| POST   | /upload/profile-photo     | JWT  | Upload profile photo to Cloudinary, returns URL  |

**POST /upload/profile-photo — Request:** `multipart/form-data`, field name `"file"`, accepted types: `image/jpeg`, `image/png`, `image/webp`, max size 5 MB.

**POST /upload/profile-photo — Response shape:**
```json
{
  "success": true,
  "photoUrl": "https://res.cloudinary.com/..."
}
```

**POST /upload/profile-photo — Errors:**

| Error code | HTTP | Reason |
|------------|------|--------|
| `INVALID_FILE_TYPE` | 400 | File is not jpeg/png/webp |
| `FILE_TOO_LARGE` | 400 | File exceeds 5 MB |
| `UPLOAD_FAILED` | 500 | Cloudinary upload error |

> After receiving `photoUrl`, the frontend calls `PATCH /profile` with `{ "photoUrl": "..." }` to persist it.

---

### Contact

| Method | Path       | Auth | Description                     |
|--------|------------|------|---------------------------------|
| POST   | /contact   | None | Submit contact form, sends email |

**POST /contact — Request body:**
```json
{
  "name": "Ram Sharma",
  "email": "ram@example.com",
  "message": "I have a question about..."
}
```

**POST /contact — Response shape:**
```json
{
  "success": true,
  "message": "Your message has been sent. We'll get back to you soon."
}
```
> Sends email to support inbox via SMTP. No auth required.

---

## Firestore Collections

```
\users (collection)
└── {uid} (document) ← From Firebase Auth
    ├── firstName: "Ram"
    ├── lastName: "Sharma"
    ├── email: "ram@email.com"
    ├── phone: "+97798XXXXXXXX"
    ├── photoUrl: "https://res.cloudinary.com/..." (null if not set)
    ├── createdAt: timestamp
    ├── updatedAt: timestamp
    │
    ├── onboarding (map)
    │   ├── isCompleted: true
    │   ├── occupation: "student" | "employed" | "business"
    │   ├── housingType: "rent" | "own"
    │   ├── estimatedMonthlySpend: 15000
    │   └── tourCompleted: false  ← set true after first-time tour guide is dismissed
    │
    ├── income (map)  ← declared income set during onboarding / income page
    │   ├── inHand: 5000.0
    │   ├── inBank: 15000.0
    │   ├── onlineBanking: 3000.0
    │   └── updatedAt: timestamp
    │
    ├── preferences (map)
    │   ├── language: "ne" | "en"
    │   ├── currency: "NPR"
    │   └── alertThreshold: 80
    │
    ├── budgets (subcollection)
    │   └── {budgetId}
    │       ├── category: "Food"
    │       ├── limit: 5000
    │       ├── spent: 2500
    │       ├── alertThreshold: 80
    │       ├── monthKey: "2026-04"
    │       ├── createdAt: timestamp
    │       └── updatedAt: timestamp
    │
    ├── transactions (subcollection)
    │   └── {transactionId}
    │       ├── amount: 250
    │       ├── category: "Food"
    │       ├── type: "expense" | "income" | "transfer"
    │       ├── status: "confirmed" | "pending" | "cancelled"
    │       ├── source: "chat" | "manual" | "notification" | "offline_sync"
    │       ├── description: "Momo khada 250 gayo"
    │       ├── monthKey: "2026-04"
    │       ├── isDeleted: false
    │       ├── deletedAt: timestamp (null if active)
    │       ├── originalMessageId: "msg_abc123"
    │       ├── idempotencyKey: "uuid" (optional, for deduplication)
    │       ├── createdAt: timestamp
    │       └── updatedAt: timestamp
    │
    ├── messages (subcollection)  ◀ Persistent — never cleared by backend
    │   └── {messageId}
    │       ├── role: "user" | "model"  ◀ "assistant" normalized to "model" on read
    │       ├── parts: [ { text: "Sanchai xau?" } ]
    │       ├── content: "Sanchai xau?"  (legacy field, kept for backward compat)
    │       ├── intent: "general_chat" | "expense_log" | "income_log" | "set_budget" |
    │       │           "confirm_expense" | "query_report" | "greeting" | ...
    │       ├── extractedData (array, optional)
    │       │   └── { intent, amount, category, type, limit, monthKey }
    │       ├── relatedTransactionId: "txn_abc" (optional)
    │       ├── status: "pending" | "delivered"
    │       └── createdAt: timestamp  ◀ Sort by this for chronological order
    │
    ├── notifications (subcollection)
    │   └── {notificationId}
    │       ├── rawText: "eSewa: Payment of Rs 250 successful"
    │       ├── parsedAmount: 250
    │       ├── parsedCategory: "Food"
    │       ├── parsedType: "expense" | "income"
    │       ├── sourceApp: "eSewa" | "Khalti" | "NabilBank" | "Unknown"
    │       ├── status: "pending" | "confirmed" | "rejected"
    │       ├── transactionId: "txn_abc" (filled after user confirms)
    │       ├── receiverName: "Sandar Momo" (optional)
    │       ├── suggestedCategory: "Food" (optional)
    │       └── createdAt: timestamp
    │
    ├── pendingAction (subcollection — single doc "current")
    │   └── current
    │       ├── actions: [ { intent, amount, category, type } ]
    │       ├── pendingTxIds: ["txn_abc"]
    │       ├── source: "chat" | "notification"
    │       ├── monthKey: "2026-04"
    │       └── createdAt: timestamp
    │
    ├── monthlyReports (subcollection)
    │   └── {monthKey}  ← Document ID = "2026-04"
    │       ├── monthKey: "2026-04"
    │       ├── totalExpense: 15000
    │       ├── totalIncome: 45000
    │       ├── netSavings: 30000
    │       ├── categoryBreakdown (map)  { Food: 1200, Rent: 8000, ... }
    │       ├── budgetUtilization (map)  { Food: 85, ... }
    │       ├── daysRemaining: 10
    │       ├── survivalBudgetPerDay: 380
    │       ├── alertCount: 3
    │       └── generatedAt: timestamp
    │
    └── alerts (subcollection)
        └── {alertId}
            ├── type: "expense" | "income" | "budget_set" | "budget_warning" |
            │         "overspent" | "low_survival_budget" | "monthly_report_ready"
            ├── category: "Food" (null for income alerts)
            ├── message: "Rs 500 Food expense saved." | "Rs 3000 income added."
            ├── severity: "low" | "medium" | "high"
            ├── isRead: false
            ├── isDeleted: false
            ├── monthKey: "2026-04"
            ├── relatedTransactionId: "txn_abc" (optional)
            └── createdAt: timestamp
```
