# BachatBot – Official README.md (Final Version – April 2025 MVP)
Know your kharcha, grow your bachat.
Nepal’s smartest, laziest, and most honest expense tracker.

🚀 What BachatBot Actually Does (100% Final Scope)
Chat like a human – money gets tracked automatically

text

Momo 250
Ghar ko rent 12k pathaye
Salary 45k aayo Khalti bata
Bank / eSewa / Khalti notifications → auto-captured

Flutter listens to SMS/notifications in background
Sends raw text to backend → Gemini parses → saved as source: "notification" + status: "pending"
Chat instantly shows:
Rs 1,250 Bhatbhateni ma gayo – thik cha? [Yes/No]
User taps Yes → becomes confirmed
Smart Budget + Real-time Intelligent Alerts (This is the killer feature)

User sets monthly budget per category (via chat or settings)
text

Food ko lagi 8k matra rakhchu yo mahina
Transport ma 5k
As soon as spending crosses 70–80%, bot sends alert in chat + push notification:
text

⚠️ Food ma already Rs 6,200 kharcha bhayo out of 8,000!
Only Rs 1,800 left and 18 days remaining.
Aaja momo nahkaanu hola 😭
At 100%: red alert
At 120%: bot literally begs you to stop
Monthly Report – Beautiful & Brutally Honest (1st of every month)

Bar graph (category vs amount) using fl_chart
Below graph:
text

Food          - ₹18,400 / 15,000  🔥 123% (overspent 3.4k)
Transport     - ₹7,200  / 8,000   ✅ 90%
Rent          - ₹12,000 / 12,000  ✅
Entertainment - ₹9,500  / 6,000   🔥 158% (bro chill gara)
Total Savings This Month → ₹8,400 only 😔
New Month = Fresh Start

On 1st of new month (or first login in new month):
Naya mahina suru bhayo! 😄 Yo mahina ko budget set garne ho?
Full Nepali + Roman + English support
Works perfectly with Devanagari, Roman Nepali, and English.

🏗️ Final Database Schema (Firestore) – Locked Forever
plaintext

users (collection)
└── {uid} (document – from Firebase Auth)
    ├── firstName, lastName, email, phone
    ├── createdAt, updatedAt

    ├── onboarding (map)
    │   ├── isCompleted: bool
    │   ├── occupation: "student" | "employed" | "business"
    │   ├── housingType: "rent" │ "own"
    │   └── estimatedMonthlySpend: number

    ├── preferences (map)
    │   ├── language: "ne" | "en"
    │   ├── currency: "NPR"
    │   └── alertThreshold: 80 (default)

    ├── budgets (subcollection)
    │   └── {budgetId auto-id}
    │       ├── category: "Food"
    │       ├── limit: 8000
    │       ├── spent: 6200          ← auto-updated
    │       ├── alertThreshold: 80
    │       ├── monthKey: "2025-04"
    │       └── createdAt, updatedAt

    ├── transactions (subcollection)
    │   └── {transactionId}
            ├── amount, category, type, status, source
            ├── description (raw text)
            ├── monthKey: "2025-04"
            ├── isDeleted: false
            ├── createdAt, updatedAt

    ├── messages (subcollection)     ← full chat history
    │   └── {messageId}
            ├── role: "user" | "assistant"
            ├── content, intent, extractedData
            ├── pendingAction (for confirmations)
            └── createdAt

    ├── notifications (subcollection)  ← raw bank messages
    │   └── {notificationId}
            ├── rawText, parsedAmount, parsedCategory
            ├── status: "pending" | "confirmed" | "rejected"
            └── transactionId (after confirm)

    ├── monthlyReports (subcollection)
    │   └── {monthKey} e.g. "2025-04"
            ├── totalExpense, totalIncome, netSavings
            ├── categoryBreakdown (map)
            ├── budgetUtilization (map)
            ├── daysRemaining, survivalBudgetPerDay
            └── generatedAt

    └── alerts (subcollection)
        └── {alertId}
            ├── type: "budget_warning" | "overspent" | "low_survival_budget"
            ├── category, message, severity: "medium" | "high"
            ├── isRead: false
            └── createdAt
🔗 Final API Endpoints (Locked – Will Never Change)
Method	Endpoint	Purpose
POST	/complete-signup	After Firebase signup
POST	/chat	Main entry: user message OR notification text
GET	/transactions	?month=2025-04 (optional)
GET	/profile	Returns onboarding + preferences + current budgets
POST	/confirm-transaction/{tid}	User taps "Yes"
POST	/reject-transaction/{tid}	User taps "No"
POST	/set-budget	From chat or settings screen
GET	/monthly-report?month=2025-03	Returns full report + graph data
GET	/alerts	Unread alerts
All protected with Firebase idToken
