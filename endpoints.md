# 📘 ENDPOINTS.md — BachatBot Backend API

> **Version:** 1.0 (MVP)  
> **Backend:** FastAPI + Firebase Admin SDK + Firestore  
> **Auth:** Firebase Email/Password  
> **AI:** Google Gemini 2.5 Flash  
> **Database Schema:** Matches `schema.md` exactly

---

## 🔐 Authentication & Token Management

### How Auth Works (End to End)

```
Flutter App
    │
    ├── User signs up / logs in using Firebase Auth SDK
    ├── Firebase returns: idToken + refreshToken
    ├── idToken expires every ~1 hour
    ├── Firebase SDK AUTO-REFRESHES using refreshToken
    ├── Flutter always calls: await user.getIdToken(true)
    │   (this returns fresh token automatically, no re-login needed)
    │
    ▼
FastAPI Backend
    │
    ├── Receives: Authorization: Bearer <idToken>
    ├── Verifies using: firebase_admin.auth.verify_id_token(token)
    ├── Extracts: uid from verified token
    ├── All Firestore operations use this uid
    │
    ▼
User stays logged in forever until they manually logout
```

### Token Rules

| Rule | Detail |
|------|--------|
| Token expires | ~1 hour |
| Auto refresh | Firebase SDK does it automatically |
| Flutter code | `await user.getIdToken(true)` before every API call |
| Backend receives expired token | Returns `401` |
| Flutter gets `401` | Calls `getIdToken(true)` → retries request |
| User logs out | `FirebaseAuth.instance.signOut()` → clears everything |
| User closes app and reopens | Firebase SDK auto-restores session → no re-login |

### Flutter Token Interceptor (Namrata should use this)

```dart
class ApiService {
  final String baseUrl = "https://your-backend.com";

  Future<Map<String, String>> _getHeaders() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception("Not logged in");
    
    // This auto-refreshes if expired. User NEVER has to re-login.
    final idToken = await user.getIdToken(true);
    
    return {
      "Authorization": "Bearer $idToken",
      "Content-Type": "application/json",
    };
  }

  Future<dynamic> get(String endpoint) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse("$baseUrl$endpoint"),
      headers: headers,
    );
    if (response.statusCode == 401) {
      // Force refresh and retry once
      final headers = await _getHeaders();
      return http.get(Uri.parse("$baseUrl$endpoint"), headers: headers);
    }
    return jsonDecode(response.body);
  }
}
```

### Backend Token Verification (You build this)

```python
# backend/auth.py
from firebase_admin import auth
from fastapi import Request, HTTPException

async def get_current_user(request: Request):
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    
    token = auth_header.split("Bearer ")[1]
    
    try:
        decoded = auth.verify_id_token(token)
        return decoded  # contains uid, email, etc.
    except auth.ExpiredIdTokenError:
        raise HTTPException(status_code=401, detail="Token expired")
    except auth.InvalidIdTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")
    except Exception:
        raise HTTPException(status_code=401, detail="Auth failed")
```

---

## 🛣️ Complete Endpoint Reference

### Summary Table

| # | Method | Endpoint | Purpose | Auth | Firestore Path |
|---|--------|----------|---------|------|----------------|
| 1 | POST | `/complete-signup` | Create user profile | ✅ | `users/{uid}` |
| 2 | GET | `/profile` | Get user profile | ✅ | `users/{uid}` |
| 3 | PATCH | `/profile` | Update onboarding/preferences | ✅ | `users/{uid}` |
| 4 | POST | `/chat` | Main AI chat endpoint | ✅ | `messages`, `transactions`, `notifications`, `budgets`, `alerts` |
| 5 | GET | `/transactions` | List transactions | ✅ | `users/{uid}/transactions` |
| 6 | POST | `/confirm-transaction/{id}` | Confirm pending transaction | ✅ | `users/{uid}/transactions/{id}` |
| 7 | POST | `/reject-transaction/{id}` | Reject pending transaction | ✅ | `users/{uid}/transactions/{id}` |
| 8 | DELETE | `/transactions/{id}` | Soft delete transaction | ✅ | `users/{uid}/transactions/{id}` |
| 9 | POST | `/budgets` | Create/update budget | ✅ | `users/{uid}/budgets` |
| 10 | GET | `/budgets` | List budgets for month | ✅ | `users/{uid}/budgets` |
| 11 | GET | `/monthly-report` | Get monthly report | ✅ | `users/{uid}/monthlyReports/{monthKey}` |
| 12 | GET | `/alerts` | Get alerts | ✅ | `users/{uid}/alerts` |
| 13 | PATCH | `/alerts/{id}/read` | Mark alert read | ✅ | `users/{uid}/alerts/{id}` |
| 14 | GET | `/messages` | Get chat history | ✅ | `users/{uid}/messages` |
| 15 | GET | `/notifications` | List SMS notification history (with filters) | ✅ | `users/{uid}/notifications` |

---

## 📝 Detailed Endpoint Specifications

---

### Endpoint 1: `POST /complete-signup`

**Purpose:** Create user document in Firestore after Firebase signup.

**When called:** Immediately after `FirebaseAuth.createUserWithEmailAndPassword()` succeeds.

**Firestore writes to:** `users/{uid}`

**Request:**
```json
{
  "firstName": "Ram",
  "lastName": "Sharma",
  "email": "ram@email.com",
  "phone": "+97798XXXXXXXX"
}
```

**What backend does:**
```
1. Verify idToken → extract uid
2. Check if users/{uid} already exists → if yes, return error
3. Create document:
   users/{uid} = {
     firstName, lastName, email, phone,
     createdAt: SERVER_TIMESTAMP,
     updatedAt: SERVER_TIMESTAMP,
     onboarding: {
       isCompleted: false,
       occupation: null,
       housingType: null,
       estimatedMonthlySpend: null
     },
     preferences: {
       language: "ne",
       currency: "NPR",
       alertThreshold: 80
     }
   }
4. Return created profile
```

**Success Response (201):**
```json
{
  "success": true,
  "message": "Signup completed.",
  "data": {
    "uid": "firebase_uid",
    "firstName": "Ram",
    "lastName": "Sharma",
    "email": "ram@email.com",
    "phone": "+97798XXXXXXXX",
    "createdAt": "2026-04-01T10:00:00Z",
    "updatedAt": "2026-04-01T10:00:00Z",
    "onboarding": {
      "isCompleted": false,
      "occupation": null,
      "housingType": null,
      "estimatedMonthlySpend": null
    },
    "preferences": {
      "language": "ne",
      "currency": "NPR",
      "alertThreshold": 80
    }
  }
}
```

**Error (409 - Already exists):**
```json
{
  "success": false,
  "error": {
    "code": "USER_EXISTS",
    "message": "User profile already exists."
  }
}
```

---

### Endpoint 2: `GET /profile`

**Purpose:** Fetch current user's full profile.

**Firestore reads from:** `users/{uid}`

**When called:**
- After login (to check onboarding status)
- On profile screen
- To load preferences

**Request:** No body. Token only.

**What backend does:**
```
1. Verify token → get uid
2. Fetch users/{uid}
3. If not found → 404
4. Return full document
```

**Success Response (200):**
```json
{
  "success": true,
  "data": {
    "uid": "firebase_uid",
    "firstName": "Ram",
    "lastName": "Sharma",
    "email": "ram@email.com",
    "phone": "+97798XXXXXXXX",
    "createdAt": "2026-04-01T10:00:00Z",
    "updatedAt": "2026-04-05T14:00:00Z",
    "onboarding": {
      "isCompleted": true,
      "occupation": "student",
      "housingType": "rent",
      "estimatedMonthlySpend": 15000
    },
    "preferences": {
      "language": "ne",
      "currency": "NPR",
      "alertThreshold": 80
    }
  }
}
```

**Frontend uses this to decide:**
```
if onboarding.isCompleted == false → show onboarding screen
if onboarding.isCompleted == true → show home/chat screen
```

---

### Endpoint 3: `PATCH /profile`

**Purpose:** Update onboarding answers or preferences.

**Firestore updates:** `users/{uid}` (merge update)

**Request:**
```json
{
  "onboarding": {
    "isCompleted": true,
    "occupation": "student",
    "housingType": "rent",
    "estimatedMonthlySpend": 15000
  }
}
```

Or preferences only:
```json
{
  "preferences": {
    "language": "en",
    "alertThreshold": 75
  }
}
```

Or both together.

**What backend does:**
```
1. Verify token → get uid
2. Merge update users/{uid} with provided fields
3. Update updatedAt timestamp
4. Return success
```

**Response (200):**
```json
{
  "success": true,
  "message": "Profile updated."
}
```

---

### Endpoint 4: `POST /chat`

**Purpose:** Main AI endpoint. Handles ALL chat interactions.

**This is the most complex endpoint. It handles:**
1. General conversation
2. Expense logging
3. Income logging
4. Budget setting via chat
5. Notification parsing
6. Report queries
7. Confirmation responses

**Firestore writes to:**
- `users/{uid}/messages` (always — save both user and bot message)
- `users/{uid}/transactions` (if expense/income detected)
- `users/{uid}/notifications` (if source is notification)
- `users/{uid}/budgets` (if budget setting detected)
- `users/{uid}/alerts` (if budget threshold crossed)

---

#### Chat Request Format

**Normal chat:**
```json
{
  "message": "Momo khada 250 gayo",
  "source": "chat"
}
```

**Notification:**
```json
{
  "message": "eSewa: Payment of Rs 250 successful to Bhatbhateni",
  "source": "notification",
  "sourceApp": "eSewa",
  "originalMessageId": "msg_abc123"
}
```

**Budget setting via chat:**
```json
{
  "message": "Food ko lagi 8000 rakhchu yo mahina",
  "source": "chat"
}
```

**Confirmation response:**
```json
{
  "message": "yes",
  "source": "chat"
}
```

---

#### What Backend Does (Step by Step)

```
1. Verify token → get uid

2. Save user message to messages subcollection:
   users/{uid}/messages/{auto_id} = {
     role: "user",
     content: message,
     intent: (determined after AI processing),
     extractedData: (filled after AI processing),
     createdAt: SERVER_TIMESTAMP
   }

3. Send message to Gemini API with system prompt
   → Gemini returns structured response with DATA{...}DATA block

4. Parse Gemini response:
   - Extract intent
   - Extract amount, category, type (if transaction)
   - Extract budget info (if budget setting)

5. Based on intent:

   IF intent == "expense_log" or "income_log":
     → Create transaction in users/{uid}/transactions
     → If source == "chat": status = "confirmed"
     → If source == "notification": status = "pending"
     → Update budget spent amount (if budget exists for that category)
     → Check budget threshold → create alert if needed
     → Save notification document (if source == "notification")

   IF intent == "budget_set":
     → Create/update budget in users/{uid}/budgets
     → Check if budget for same category+monthKey exists
       → If yes: update limit
       → If no: create new

   IF intent == "general_chat" or "greeting":
     → Just return reply, no database writes except messages

   IF intent == "query_report":
     → Fetch monthly report data
     → Return summary in reply

   IF intent == "confirmation_response":
     → Find latest pending transaction
     → Confirm or reject based on user response

6. Save bot message to messages subcollection:
   users/{uid}/messages/{auto_id} = {
     role: "assistant",
     content: reply_text,
     intent: detected_intent,
     extractedData: {...} or null,
     relatedTransactionId: txn_id or null,
     createdAt: SERVER_TIMESTAMP
   }

7. Return response to Flutter
```

---

#### Chat Response Formats

**Expense Logged (source: chat):**
```json
{
  "success": true,
  "data": {
    "reply": "Rs 250 Food ma save gareko chu ✅",
    "intent": "expense_log",
    "needsConfirmation": false,
    "transaction": {
      "id": "txn_abc123",
      "amount": 250,
      "category": "Food",
      "type": "expense",
      "status": "confirmed",
      "source": "chat",
      "description": "Momo khada 250 gayo",
      "monthKey": "2026-04",
      "isDeleted": false,
      "deletedAt": null,
      "originalMessageId": null,
      "createdAt": "2026-04-10T12:30:00Z",
      "updatedAt": "2026-04-10T12:30:00Z"
    },
    "budgetUpdate": {
      "category": "Food",
      "limit": 5000,
      "spent": 2250,
      "remaining": 2750,
      "percentUsed": 45
    },
    "alerts": []
  }
}
```

**Expense Logged + Alert Triggered:**
```json
{
  "success": true,
  "data": {
    "reply": "Rs 1500 Food ma save gareko chu ✅\n⚠️ Food budget ma Rs 4200/5000 spend bhaisakyo! Only Rs 800 left and 18 days remaining.",
    "intent": "expense_log",
    "needsConfirmation": false,
    "transaction": {
      "id": "txn_def456",
      "amount": 1500,
      "category": "Food",
      "type": "expense",
      "status": "confirmed",
      "source": "chat",
      "description": "Khana 1500",
      "monthKey": "2026-04",
      "isDeleted": false,
      "deletedAt": null,
      "originalMessageId": null,
      "createdAt": "2026-04-12T18:00:00Z",
      "updatedAt": "2026-04-12T18:00:00Z"
    },
    "budgetUpdate": {
      "category": "Food",
      "limit": 5000,
      "spent": 4200,
      "remaining": 800,
      "percentUsed": 84
    },
    "alerts": [
      {
        "id": "alert_789",
        "type": "budget_warning",
        "category": "Food",
        "message": "Food ma Rs 4200/5000 spend bhaisakyo! Only Rs 800 left and 18 days remaining.",
        "severity": "high",
        "isRead": false,
        "monthKey": "2026-04",
        "createdAt": "2026-04-12T18:00:00Z"
      }
    ]
  }
}
```

**Notification → Pending:**
```json
{
  "success": true,
  "data": {
    "reply": "eSewa bata Rs 250 Food ma kharcha bhako jasto cha. Thik cha?",
    "intent": "notification_parse",
    "needsConfirmation": true,
    "transaction": {
      "id": "txn_pending_123",
      "amount": 250,
      "category": "Food",
      "type": "expense",
      "status": "pending",
      "source": "notification",
      "description": "eSewa: Payment of Rs 250 successful to Bhatbhateni",
      "monthKey": "2026-04",
      "isDeleted": false,
      "deletedAt": null,
      "originalMessageId": "msg_abc123",
      "createdAt": "2026-04-10T12:30:00Z",
      "updatedAt": "2026-04-10T12:30:00Z"
    },
    "notification": {
      "id": "notif_xyz",
      "rawText": "eSewa: Payment of Rs 250 successful to Bhatbhateni",
      "parsedAmount": 250,
      "parsedCategory": "Food",
      "parsedType": "expense",
      "sourceApp": "eSewa",
      "status": "pending",
      "transactionId": "txn_pending_123",
      "createdAt": "2026-04-10T12:30:00Z"
    },
    "budgetUpdate": null,
    "alerts": []
  }
}
```

**Budget Set via Chat:**
```json
{
  "success": true,
  "data": {
    "reply": "Food ko budget Rs 8000 set gareko chu yo mahina ko lagi ✅",
    "intent": "budget_set",
    "needsConfirmation": false,
    "transaction": null,
    "budget": {
      "id": "budget_abc",
      "category": "Food",
      "limit": 8000,
      "spent": 0,
      "alertThreshold": 80,
      "monthKey": "2026-04",
      "createdAt": "2026-04-01T10:00:00Z",
      "updatedAt": "2026-04-01T10:00:00Z"
    },
    "alerts": []
  }
}
```

**General Chat:**
```json
{
  "success": true,
  "data": {
    "reply": "Namaste! Ma timro BachatBot 😄 Kharcha track garna ready chu!",
    "intent": "general_chat",
    "needsConfirmation": false,
    "transaction": null,
    "budgetUpdate": null,
    "alerts": []
  }
}
```

**Income Logged:**
```json
{
  "success": true,
  "data": {
    "reply": "Rs 45000 Income (Salary) ma record gareko chu ✅",
    "intent": "income_log",
    "needsConfirmation": false,
    "transaction": {
      "id": "txn_income_001",
      "amount": 45000,
      "category": "Salary",
      "type": "income",
      "status": "confirmed",
      "source": "chat",
      "description": "Salary 45k aayo",
      "monthKey": "2026-04",
      "isDeleted": false,
      "deletedAt": null,
      "originalMessageId": null,
      "createdAt": "2026-04-01T10:00:00Z",
      "updatedAt": "2026-04-01T10:00:00Z"
    },
    "budgetUpdate": null,
    "alerts": []
  }
}
```

---

### Endpoint 5: `GET /transactions`

**Purpose:** Fetch transaction history with filters.

**Firestore reads from:** `users/{uid}/transactions`

**Query Parameters:**

| Param | Type | Required | Default | Example |
|-------|------|----------|---------|---------|
| `monthKey` | string | No | current month | `2026-04` |
| `status` | string | No | all | `confirmed` |
| `source` | string | No | all | `notification` |
| `type` | string | No | all | `expense` |
| `category` | string | No | all | `Food` |
| `limit` | int | No | 50 | `100` |
| `orderBy` | string | No | `createdAt` | `amount` |
| `order` | string | No | `desc` | `asc` |

**Example Calls:**
```
GET /transactions
GET /transactions?monthKey=2026-04
GET /transactions?monthKey=2026-04&status=confirmed
GET /transactions?monthKey=2026-04&type=expense&category=Food
GET /transactions?status=pending
```

**What backend does:**
```
1. Verify token → get uid
2. Query users/{uid}/transactions
3. Apply filters: monthKey, status, source, type, category
4. Apply ordering and limit
5. Filter out isDeleted == true
6. Return array
```

**Response (200):**
```json
{
  "success": true,
  "data": {
    "transactions": [
      {
        "id": "txn_abc123",
        "amount": 250,
        "category": "Food",
        "type": "expense",
        "status": "confirmed",
        "source": "chat",
        "description": "Momo khada 250 gayo",
        "monthKey": "2026-04",
        "isDeleted": false,
        "deletedAt": null,
        "originalMessageId": null,
        "createdAt": "2026-04-10T12:30:00Z",
        "updatedAt": "2026-04-10T12:30:00Z"
      },
      {
        "id": "txn_def456",
        "amount": 1500,
        "category": "Food",
        "type": "expense",
        "status": "confirmed",
        "source": "notification",
        "description": "eSewa: Payment of Rs 1500",
        "monthKey": "2026-04",
        "isDeleted": false,
        "deletedAt": null,
        "originalMessageId": "msg_xyz",
        "createdAt": "2026-04-12T18:00:00Z",
        "updatedAt": "2026-04-12T18:00:00Z"
      }
    ],
    "count": 2
  }
}
```

**Empty Response:**
```json
{
  "success": true,
  "data": {
    "transactions": [],
    "count": 0
  }
}
```

---

### Endpoint 6: `POST /confirm-transaction/{transactionId}`

**Purpose:** Confirm a pending notification transaction.

**Firestore updates:**
- `users/{uid}/transactions/{transactionId}` → status = "confirmed"
- `users/{uid}/notifications/{notificationId}` → status = "confirmed"
- `users/{uid}/budgets/{budgetId}` → spent += amount
- `users/{uid}/alerts` → create if threshold crossed

**What backend does:**
```
1. Verify token → get uid
2. Fetch transaction → check it exists and status == "pending"
3. Update transaction: status = "confirmed", updatedAt = now
4. Update notification: status = "confirmed"
5. Find budget for same category + monthKey
6. If budget exists:
   a. budget.spent += transaction.amount
   b. Calculate percentUsed = (spent / limit) * 100
   c. Calculate daysRemaining in month
   d. If percentUsed >= alertThreshold:
      → Create alert in users/{uid}/alerts
7. Save bot confirmation message in messages
8. Return updated transaction + any alerts
```

**Response (200):**
```json
{
  "success": true,
  "message": "Transaction confirmed.",
  "data": {
    "transaction": {
      "id": "txn_pending_123",
      "amount": 250,
      "category": "Food",
      "type": "expense",
      "status": "confirmed",
      "source": "notification",
      "updatedAt": "2026-04-10T12:35:00Z"
    },
    "budgetUpdate": {
      "category": "Food",
      "limit": 5000,
      "spent": 3250,
      "remaining": 1750,
      "percentUsed": 65
    },
    "alerts": []
  }
}
```

**Error (404):**
```json
{
  "success": false,
  "error": {
    "code": "TRANSACTION_NOT_FOUND",
    "message": "Transaction not found or already confirmed."
  }
}
```

---

### Endpoint 7: `POST /reject-transaction/{transactionId}`

**Purpose:** Reject a pending notification transaction.

**Firestore updates:**
- `users/{uid}/transactions/{transactionId}` → status = "rejected"
- `users/{uid}/notifications/{notificationId}` → status = "rejected"

**What backend does:**
```
1. Verify token → get uid
2. Fetch transaction → check status == "pending"
3. Update transaction: status = "rejected", updatedAt = now
4. Update notification: status = "rejected"
5. Save bot message in messages
6. Do NOT update any budget
```

**Response (200):**
```json
{
  "success": true,
  "message": "Transaction rejected.",
  "data": {
    "transaction": {
      "id": "txn_pending_123",
      "status": "rejected"
    }
  }
}
```

---

### Endpoint 8: `DELETE /transactions/{transactionId}`

**Purpose:** Soft delete a transaction.

**Firestore updates:** `users/{uid}/transactions/{transactionId}`

**What backend does:**
```
1. Verify token → get uid
2. Fetch transaction
3. Update: isDeleted = true, deletedAt = now, updatedAt = now
4. If transaction was confirmed AND budget exists:
   → budget.spent -= transaction.amount (reverse the spend)
   → Update budget
```

**Response (200):**
```json
{
  "success": true,
  "message": "Transaction deleted.",
  "data": {
    "transaction": {
      "id": "txn_abc123",
      "isDeleted": true,
      "deletedAt": "2026-04-10T15:00:00Z"
    },
    "budgetUpdate": {
      "category": "Food",
      "limit": 5000,
      "spent": 2000,
      "remaining": 3000,
      "percentUsed": 40
    }
  }
}
```

---

### Endpoint 9: `POST /budgets`

**Purpose:** Create or update monthly budget for a category.

**Firestore writes to:** `users/{uid}/budgets`

**Request:**
```json
{
  "category": "Food",
  "limit": 5000,
  "monthKey": "2026-04",
  "alertThreshold": 80
}
```

**What backend does:**
```
1. Verify token → get uid
2. Check if budget for same category + monthKey exists
   → If yes: update limit and alertThreshold
   → If no: create new budget document with spent = 0
3. Return budget
```

**Response (201 or 200):**
```json
{
  "success": true,
  "message": "Food budget set to Rs 5000 for 2026-04.",
  "data": {
    "budget": {
      "id": "budget_abc",
      "category": "Food",
      "limit": 5000,
      "spent": 0,
      "alertThreshold": 80,
      "monthKey": "2026-04",
      "createdAt": "2026-04-01T10:00:00Z",
      "updatedAt": "2026-04-01T10:00:00Z"
    }
  }
}
```

---

### Endpoint 10: `GET /budgets`

**Purpose:** Fetch all budgets for a month.

**Firestore reads from:** `users/{uid}/budgets`

**Query:** `GET /budgets?monthKey=2026-04`

**What backend does:**
```
1. Verify token → get uid
2. Query budgets where monthKey == provided monthKey
3. Calculate remaining and percentUsed for each
4. Return array
```

**Response (200):**
```json
{
  "success": true,
  "data": {
    "budgets": [
      {
        "id": "budget_abc",
        "category": "Food",
        "limit": 5000,
        "spent": 2000,
        "remaining": 3000,
        "percentUsed": 40,
        "alertThreshold": 80,
        "monthKey": "2026-04",
        "createdAt": "2026-04-01T10:00:00Z",
        "updatedAt": "2026-04-10T12:30:00Z"
      },
      {
        "id": "budget_def",
        "category": "Transport",
        "limit": 3000,
        "spent": 800,
        "remaining": 2200,
        "percentUsed": 27,
        "alertThreshold": 80,
        "monthKey": "2026-04",
        "createdAt": "2026-04-01T10:00:00Z",
        "updatedAt": "2026-04-08T09:00:00Z"
      }
    ]
  }
}
```

---

### Endpoint 11: `GET /monthly-report`

**Purpose:** Generate/fetch monthly report for dashboard and graphs.

**Firestore reads from:** `users/{uid}/transactions`, `users/{uid}/budgets`  
**Firestore writes to:** `users/{uid}/monthlyReports/{monthKey}` (caches report)

**Query:** `GET /monthly-report?monthKey=2026-04`

**What backend does:**
```
1. Verify token → get uid
2. Check if monthlyReports/{monthKey} exists and is recent
   → If exists and generatedAt < 1 hour ago: return cached
   → Otherwise: regenerate

3. Regenerate:
   a. Fetch all confirmed transactions for monthKey
   b. Calculate totalExpense (sum of type=="expense")
   c. Calculate totalIncome (sum of type=="income")
   d. Calculate netSavings = totalIncome - totalExpense
   e. Calculate categoryBreakdown (group by category, sum amounts)
   f. Fetch budgets for monthKey
   g. Calculate budgetUtilization (spent/limit * 100 per category)
   h. Calculate daysRemaining in month
   i. Calculate survivalBudgetPerDay = remaining budget / daysRemaining
   j. Count alerts for month

4. Save report to monthlyReports/{monthKey}
5. Return report
```

**Response (200):**
```json
{
  "success": true,
  "data": {
    "report": {
      "monthKey": "2026-04",
      "totalExpense": 18400,
      "totalIncome": 45000,
      "netSavings": 26600,
      "categoryBreakdown": {
        "Food": 8500,
        "Transport": 3200,
        "Rent": 12000,
        "Entertainment": 2400,
        "Shopping": 1800,
        "Bills": 500
      },
      "budgetUtilization": {
        "Food": 106,
        "Transport": 80,
        "Rent": 100,
        "Entertainment": 120,
        "Shopping": 60
      },
      "daysRemaining": 10,
      "survivalBudgetPerDay": 460,
      "alertCount": 3,
      "generatedAt": "2026-04-20T12:00:00Z"
    }
  }
}
```

**Frontend uses this for:**
```
Bar Graph:
  X-axis = keys of categoryBreakdown (Food, Transport, Rent, ...)
  Y-axis = values (8500, 3200, 12000, ...)

Below graph cards:
  Food          - Rs 8,500 / 8,000   🔥 106% (overspent!)
  Transport     - Rs 3,200 / 4,000   ✅ 80%
  Rent          - Rs 12,000 / 12,000 ✅ 100%
  Entertainment - Rs 2,400 / 2,000   🔥 120%

Summary card:
  Total Expense: Rs 18,400
  Total Income:  Rs 45,000
  Net Savings:   Rs 26,600
  Daily Budget:  Rs 460/day for remaining 10 days
```

---

### Endpoint 12: `GET /alerts`

**Purpose:** Fetch alerts for notification/alert screen.

**Firestore reads from:** `users/{uid}/alerts`

**Query Params:**

| Param | Type | Required | Default |
|-------|------|----------|---------|
| `monthKey` | string | No | current month |
| `isRead` | boolean | No | all |
| `limit` | int | No | 20 |

**Example:** `GET /alerts?monthKey=2026-04&isRead=false`

**Response (200):**
```json
{
  "success": true,
  "data": {
    "alerts": [
      {
        "id": "alert_001",
        "type": "budget_warning",
        "category": "Food",
        "message": "Food ma Rs 4200/5000 spend bhaisakyo! Only Rs 800 left and 18 days remaining.",
        "severity": "high",
        "isRead": false,
        "monthKey": "2026-04",
        "createdAt": "2026-04-12T18:00:00Z"
      },
      {
        "id": "alert_002",
        "type": "overspent",
        "category": "Entertainment",
        "message": "Entertainment budget OVER! Rs 2400 spend out of Rs 2000 limit.",
        "severity": "high",
        "isRead": false,
        "monthKey": "2026-04",
        "createdAt": "2026-04-15T20:00:00Z"
      },
      {
        "id": "alert_003",
        "type": "low_survival_budget",
        "category": null,
        "message": "Only Rs 460/day left for remaining 10 days. Kharcha control gara!",
        "severity": "medium",
        "isRead": false,
        "monthKey": "2026-04",
        "createdAt": "2026-04-20T12:00:00Z"
      }
    ],
    "unreadCount": 3
  }
}
```

---

### Endpoint 13: `PATCH /alerts/{alertId}/read`

**Purpose:** Mark single alert as read.

**Firestore updates:** `users/{uid}/alerts/{alertId}` → isRead = true

**Response (200):**
```json
{
  "success": true,
  "message": "Alert marked as read."
}
```

---

### Endpoint 14: `GET /messages`

**Purpose:** Fetch chat history for chat screen.

**Firestore reads from:** `users/{uid}/messages`

**Query Params:**

| Param | Type | Required | Default |
|-------|------|----------|---------|
| `limit` | int | No | 50 |
| `before` | string (ISO date) | No | now |

**Example:** `GET /messages?limit=50`

**What backend does:**
```
1. Verify token → get uid
2. Query messages ordered by createdAt DESC
3. Apply limit
4. Return array (frontend reverses for chat display)
```

**Response (200):**
```json
{
  "success": true,
  "data": {
    "messages": [
      {
        "id": "msg_001",
        "role": "user",
        "content": "Momo khada 250 gayo",
        "intent": "expense_log",
        "extractedData": {
          "amount": 250,
          "category": "Food",
          "type": "expense"
        },
        "relatedTransactionId": "txn_abc123",
        "createdAt": "2026-04-10T12:30:00Z"
      },
      {
        "id": "msg_002",
        "role": "assistant",
        "content": "Rs 250 Food ma save gareko chu ✅",
        "intent": "expense_log",
        "extractedData": null,
        "relatedTransactionId": "txn_abc123",
        "createdAt": "2026-04-10T12:30:01Z"
      }
    ],
    "hasMore": true
  }
}
```

---

## 🚨 Error Response Format (All Endpoints)

| HTTP Code | When |
|-----------|------|
| `400` | Bad request body, missing required fields |
| `401` | Missing/invalid/expired Firebase token |
| `403` | Token valid but accessing another user's data |
| `404` | Resource not found |
| `409` | Conflict (e.g., user already exists) |
| `422` | Validation error (FastAPI/Pydantic) |
| `500` | Internal server error |

**Error Format:**
```json
{
  "success": false,
  "error": {
    "code": "TRANSACTION_NOT_FOUND",
    "message": "Transaction with id txn_xyz not found."
  }
}
```
---

### Endpoint 15: `GET /notifications`

**Purpose:** Fetch SMS/notification history for **Notifications Page** (Architecture section 8).  
Lists raw SMS + parsed data + confirmation status.

**Firestore reads from:** `users/{uid}/notifications`

**Query Parameters:**

| Param | Type | Required | Default | Example |
|-------|------|----------|---------|---------|
| `monthKey` | string | No | current month | `2026-04` |
| `category` | string | No | all | `Food` |
| `week` | string | No | all | `2026-W15` (ISO week) |
| `status` | string | No | all | `pending` |
| `limit` | int | No | 20 | `50` |

**Example Calls:**
GET /notifications
GET /notifications?monthKey=2026-04
GET /notifications?monthKey=2026-04&category=Food
GET /notifications?week=2026-W15&status=pending
GET /notifications?status=pending&limit=50


**What backend does:**

1. Verify token → get uid
2. Query users/{uid}/notifications ordered by createdAt DESC
3. Apply filters:
monthKey (exact match)
category (match parsedCategory field)
week: compute ISO week-of-year from createdAt (e.g., "2026-W15")
status (exact: pending/confirmed/rejected)
4. Apply limit
5. Count unreadCount (status == "pending" OR isRead == false)
6. Return array + metadata


**Response (200):**
```json
{
  "success": true,
  "data": {
    "notifications": [
      {
        "id": "notif_xyz789",
        "rawText": "eSewa: Payment of Rs 250 successful to Bhatbhateni",
        "parsedAmount": 250,
        "parsedCategory": "Food",
        "parsedType": "expense",
        "sourceApp": "eSewa",
        "status": "confirmed",
        "transactionId": "txn_abc123",
        "isRead": true,
        "createdAt": "2026-04-10T12:30:00Z"
      },
      {
        "id": "notif_abc123",
        "rawText": "Khalti: Rs 1500 debited for momo shop",
        "parsedAmount": 1500,
        "parsedCategory": "Food",
        "parsedType": "expense",
        "sourceApp": "Khalti",
        "status": "pending",
        "transactionId": "txn_pending_456",
        "isRead": false,
        "createdAt": "2026-04-12T18:00:00Z"
      }
    ],
    "unreadCount": 1,
    "hasMore": false
  }
}

Empty Response:

JSON

{
  "success": true,
  "data": {
    "notifications": [],
    "unreadCount": 0,
    "hasMore": false
  }
}

Frontend uses this for:

text

Notifications Page (Settings → Notifications):
  - Filter by Week/Month/Category
  - Show rawText + parsed amount/category
  - Show status badge (pending = yellow, confirmed = green, rejected = red)
  - Tap notification → show confirm/reject buttons (call /confirm-transaction or /reject-transaction)
  - Unread badge count on hamburger menu

---

## 📊 Alert Generation Logic (Important Backend Logic)

```
After every confirmed expense (from chat OR after notification confirm):

1. Find budget for transaction.category + transaction.monthKey
2. If no budget exists → skip alerts
3. If budget exists:
   
   spent = budget.spent (already updated)
   limit = budget.limit
   percentUsed = (spent / limit) * 100
   threshold = budget.alertThreshold (default 80)
   
   today = current date
   daysInMonth = total days in current month
   daysPassed = today - first day of month
   daysRemaining = daysInMonth - daysPassed
   remaining = limit - spent
   
   IF percentUsed >= 100:
     → Create alert: type = "overspent", severity = "high"
     → Message: "{category} budget OVER! Rs {spent} out of Rs {limit}."
   
   ELSE IF percentUsed >= threshold:
     → Create alert: type = "budget_warning", severity = "medium" or "high"
     → Message: "{category} ma Rs {spent}/{limit} spend. Rs {remaining} left, {daysRemaining} days remaining."
   
   ELSE IF percentUsed > (daysPassed/daysInMonth * 100) + 20:
     → Spending faster than expected
     → Create alert: type = "budget_warning", severity = "medium"
     → Message: "{category} ma spending fast cha! {daysRemaining} days ma Rs {remaining} matra cha."

4. Also check overall survival budget:
   totalRemaining = sum of all (budget.limit - budget.spent)
   IF daysRemaining > 0:
     survivalPerDay = totalRemaining / daysRemaining
     IF survivalPerDay < 500:
       → Create alert: type = "low_survival_budget", severity = "high"
```

---

## 📂 Backend File Structure

```
backend/
├── main.py                    # FastAPI app + CORS
├── firebase_config.py         # Firebase Admin SDK init
├── auth.py                    # Token verification dependency
├── schemas.py                 # Pydantic models (request/response)
├── utils.py                   # Date helpers, month key generator
├── gemini.py                  # Gemini API integration
├── routes/
│   ├── signup.py              # POST /complete-signup
│   ├── profile.py             # GET, PATCH /profile
│   ├── chat.py                # POST /chat (main AI endpoint)
│   ├── transactions.py        # GET, DELETE /transactions
│   ├── confirm.py             # POST /confirm, /reject
│   ├── budgets.py             # POST, GET /budgets
│   ├── reports.py             # GET /monthly-report
│   ├── alerts.py              # GET /alerts, PATCH /alerts/{id}/read
│   └── messages.py            # GET /messages
│   └── notifications.py       # GET /notifications (NEW)
├── services/
│   ├── transaction_service.py # Transaction CRUD logic
│   ├── budget_service.py      # Budget CRUD + spent update
│   ├── alert_service.py       # Alert generation logic
│   ├── report_service.py      # Report aggregation logic
│   └── notification_service.py # Notification parsing + storage
├── .env                       # GEMINI_API_KEY
├── serviceAccountKey.json     # Firebase credentials
├── requirements.txt
└── README.md
```

---

## 📋 Categories (Fixed for MVP)

```json
[
  "Food",
  "Transport",
  "Rent",
  "Education",
  "Shopping",
  "Health",
  "Entertainment",
  "Bills",
  "Salary",
  "Freelance",
  "Gift",
  "Other"
]
```

Expense categories: Food, Transport, Rent, Education, Shopping, Health, Entertainment, Bills, Other  
Income categories: Salary, Freelance, Gift, Other

---

## ✅ Implementation Order

| Priority | Endpoint | Reason |
|----------|----------|--------|
| 1 | `POST /complete-signup` | Without this, no user profile exists |
| 2 | `GET /profile` | Frontend needs this to check onboarding |
| 3 | `PATCH /profile` | Onboarding completion |
| 4 | `POST /chat` | Core feature |
| 5 | `GET /transactions` | Transaction list screen |
| 6 | `GET /messages` | Chat history on reopen |
| 7 | `POST /confirm-transaction` | Notification flow |
| 8 | `POST /reject-transaction` | Notification flow |
| 9 | `POST /budgets` | Budget setup |
| 10 | `GET /budgets` | Budget display |
| 11 | `GET /monthly-report` | Report screen |
| 12 | `GET /alerts` | Alert display |
| 13 | `PATCH /alerts/{id}/read` | UX polish |
| 14 | `DELETE /transactions/{id}` | Edit/delete feature |
| 15 | `GET /notifications` | Notifications Page (SMS history + filters) |

