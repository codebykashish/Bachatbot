\users (collection)
└── {uid} (document) ← From Firebase Auth
    ├── firstName: "Ram"
    ├── lastName: "Sharma"
    ├── email: "ram@email.com"
    ├── phone: "+97798XXXXXXXX"
    ├── createdAt: timestamp
    ├── updatedAt: timestamp
    │
    ├── onboarding (map)
    │   ├── isCompleted: true
    │   ├── occupation: "student" | "employed" | "business"
    │   ├── housingType: "rent" | "own"
    │   └── estimatedMonthlySpend: 15000
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
    │       ├── status: "confirmed" | "pending" | "rejected"
    │       ├── source: "chat" | "manual" | "notification"
    │       ├── description: "Momo khada 250 gayo"
    │       ├── monthKey: "2026-04"
    │       ├── isDeleted: false
    │       ├── deletedAt: timestamp (null if active)
    │       ├── originalMessageId: "msg_abc123"
    │       ├── createdAt: timestamp
    │       └── updatedAt: timestamp
    │
    ├── messages (subcollection)  ◀ Optimized for Gemini API
    │   └── {messageId}
    │       ├── role: "user" | "model"  ◀ Changed "assistant" to "model" to match Gemini requirements
    │       ├── parts: [ { text: "Sanchai xau?" } ] ◀ Changed string to array of objects to map directly to Gemini API
    │       ├── intent: "general_chat" | "expense_log" | "budget_set" | "undo_request" | "greeting" | "query_report" | "confirmation_response"
    │       ├── extractedData (map, optional)
    │       │   ├── amount: 250
    │       │   ├── category: "Food"
    │       │   └── type: "expense"
    │       ├── pendingAction (map, optional)
    │       │   ├── type: "budget_conflict"
    │       │   ├── oldValue: 5000
    │       │   └── newValue: 6000
    │       ├── relatedTransactionId: "txn_abc" (optional)
    │       ├── isSynced: true
    │       └── createdAt: timestamp  ◀ Use this to sort chronologically for your sliding history window
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
    │       └── createdAt: timestamp
    │
    ├── monthlyReports (subcollection)
    │   └── {monthKey} ← Document ID = "2026-04"
    │       ├── monthKey: "2026-04"
    │       ├── totalExpense: 15000
    │       ├── totalIncome: 45000
    │       ├── netSavings: 30000
    │       ├── categoryBreakdown (map)
    │       │   ├── Food: 1200
    │       │   ├── Rent: 8000
    │       │   └── ...
    │       ├── budgetUtilization (map)
    │       │   ├── Food: 85
    │       │   └── ...
    │       ├── daysRemaining: 10
    │       ├── survivalBudgetPerDay: 380
    │       ├── alertCount: 3
    │       └── generatedAt: timestamp
    │
    └── alerts (subcollection)
        └── {alertId}
            ├── type: "budget_warning" | "overspent" | "low_survival_budget" | "monthly_report_ready"
            ├── category: "Food"
            ├── message: "You have only Rs 1200 left for Food. 5 days remaining. Spend wisely!"
            ├── severity: "medium" | "high"
            ├── isRead: false
            ├── monthKey: "2026-04"
            └── createdAt: timestamp