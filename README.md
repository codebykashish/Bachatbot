# 💰 BachatBot (बचत-बोट)

<div align="center">

**Know your kharcha, grow your bachat.**

[![Status](https://img.shields.io/badge/Status-In%20Development-yellow)](https://github.com/yourusername/bachatbot)
[![License](https://img.shields.io/badge/License-Educational-blue)](LICENSE)
[![Week](https://img.shields.io/badge/Progress-Week%208%2F14-green)](GANTT.md)

*Nepal's first truly conversational expense tracker for students and young professionals.*

[Features](#-features) • [Demo](#-demo) • [Architecture](#-architecture) • [Setup](#-getting-started) • [Team](#-team)

</div>

---

## 🎯 The Problem

Traditional expense tracking apps in Nepal are:
- ❌ **Form-heavy** — boring input fields kill motivation
- ❌ **English-only** — excludes Roman Nepali speakers
- ❌ **Manual** — users forget to log expenses
- ❌ **No context** — just numbers, no financial insights
- ❌ **Designed abroad** — don't understand Nepali spending patterns

**Result:** 87% of users abandon within first week (our research, 2025)

---

## 💡 Our Solution

BachatBot removes all friction through **conversational AI**.

### Instead of this:
```
[Form Field] Amount: ____
[Dropdown] Category: ____
[Date Picker] Date: ____
[Text Area] Description: ____
[Button] Submit
```

### Users just chat:
```
User: Momo khada 250 gayo
Bot:  Rs 250 Food ma save gareko chu ✅
      Food budget: Rs 2,250 / 5,000 (45% used)
```

Even better — **bank/eSewa notifications auto-parse**:
```
eSewa SMS: "Payment of Rs 1,250 successful"
         ↓
Bot:  eSewa bata Rs 1,250 Shopping ma kharcha bhako jasto cha.
      Thik cha? [Yes] [No]
```

No manual entry. Zero effort.

---

## ✨ Core Features (MVP)

### 1️⃣ Natural Language Expense Tracking
Log expenses in **Nepali**, **Roman Nepali**, or **English**:
```
✅ "Momo 250"
✅ "Bhatbhateni ma 3400 shopping gareko"
✅ "Rent 12k pathaye"
✅ "Salary 45k aayo"
```
AI extracts amount, category, merchant, and type automatically.

### 2️⃣ Smart Bank Notification Sync
- Flutter listens to SMS/notifications in background
- Auto-detects eSewa, Khalti, IME Pay, banks
- Parses transaction → saves as **pending**
- User confirms in chat → becomes permanent
- **Zero manual typing for digital payments**

### 3️⃣ Intelligent Budget Alerts
Set monthly budgets per category (via chat or UI):
```
User: Food ko lagi 8k rakhchu yo mahina
Bot:  Food budget Rs 8,000 set gareko chu ✅
```

As you spend, bot warns you **before it's too late**:
```
⚠️ Food ma Rs 6,400 / 8,000 spend bhaisakyo!
   Only Rs 1,600 left and 18 days remaining.
   Daily limit: Rs 89/day. Aaja momo nahkaanu hola 😅
```

**Alert triggers:**
- 80% budget used
- 100% budget exceeded
- Spending pace faster than month pace
- Low survival budget (<Rs 500/day remaining)

### 4️⃣ Monthly Financial Reports
On 1st of every month, bot generates:
- 📊 **Bar graph** (category-wise spending)
- 📈 **Income vs Expense vs Savings**
- 🎯 **Budget utilization** (which categories went over)
- 💸 **Survival budget per day** for remaining month

Example:
```
April 2026 Report:
━━━━━━━━━━━━━━━━━━━━━━
Total Income:   Rs 45,000
Total Expense:  Rs 18,400
Net Savings:    Rs 26,600 ✅

Category Breakdown:
Food          Rs 8,500 / 8,000  🔥 106% (overspent!)
Transport     Rs 3,200 / 4,000  ✅  80%
Rent          Rs 12,000 / 12,000 ✅ 100%
Shopping      Rs 1,800 / 3,000  ✅  60%

Survival Budget: Rs 460/day for next 10 days
```

### 5️⃣ Onboarding Memory
Bot asks profile questions **only once**:
- Student or working?
- Rent or own house?
- Approximate monthly income?

Never repeats. Remembers forever.

### 6️⃣ Multi-Language Support
- Nepali Devanagari (नयाँ मोबाइल ४५०००)
- Roman Nepali (Momo khada 250 gayo)
- English (Bought groceries 3400)

All work perfectly.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Flutter App (Frontend)                  │
│  • Firebase Auth (Email/Password)                           │
│  • Chat UI • Transaction List • Budget Setup • Reports      │
│  • Notification Listener (Background Service)               │
└────────────────────┬────────────────────────────────────────┘
                     │
                     │ HTTPS (Authorization: Bearer idToken)
                     │
┌────────────────────▼────────────────────────────────────────┐
│                  FastAPI Backend (Python)                    │
│  • Firebase Admin SDK (Token Verification)                  │
│  • Google Gemini 1.5 Flash (NLP Processing)                 │
│  • Business Logic (Budgets, Alerts, Reports)                │
└────────────────────┬────────────────────────────────────────┘
                     │
                     │ Firebase Admin SDK
                     │
┌────────────────────▼────────────────────────────────────────┐
│                  Firestore Database                          │
│  users/{uid}/                                               │
│    ├── profile, onboarding, preferences                     │
│    ├── transactions (subcollection)                         │
│    ├── budgets (subcollection)                              │
│    ├── messages (subcollection)                             │
│    ├── notifications (subcollection)                        │
│    ├── monthlyReports (subcollection)                       │
│    └── alerts (subcollection)                               │
└─────────────────────────────────────────────────────────────┘
```

**Key Principle:** Frontend never writes to database directly. All data flows through secure backend APIs.

---

## 🗄️ Database Schema

```
users (collection)
└── {uid} ← Firebase Auth User ID
    ├── firstName, lastName, email, phone
    ├── createdAt, updatedAt
    │
    ├── onboarding (map)
    │   ├── isCompleted: boolean
    │   ├── occupation: "student" | "employed" | "business"
    │   ├── housingType: "rent" | "own"
    │   └── estimatedMonthlySpend: number
    │
    ├── preferences (map)
    │   ├── language: "ne" | "en"
    │   ├── currency: "NPR"
    │   └── alertThreshold: 80
    │
    ├── budgets (subcollection)
    │   └── {budgetId}
    │       ├── category: "Food" | "Transport" | ...
    │       ├── limit: 5000
    │       ├── spent: 2500 ← Auto-updated
    │       ├── alertThreshold: 80
    │       ├── monthKey: "2026-04"
    │       └── createdAt, updatedAt
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
    │       ├── originalMessageId: string
    │       └── createdAt, updatedAt
    │
    ├── messages (subcollection) ← Full chat history
    │   └── {messageId}
    │       ├── role: "user" | "assistant"
    │       ├── content: "Momo 250"
    │       ├── intent: "expense_log" | "general_chat" | ...
    │       ├── extractedData: { amount, category, type }
    │       ├── relatedTransactionId: string
    │       └── createdAt
    │
    ├── notifications (subcollection) ← Raw bank messages
    │   └── {notificationId}
    │       ├── rawText: "eSewa: Payment of Rs 250"
    │       ├── parsedAmount: 250
    │       ├── parsedCategory: "Food"
    │       ├── sourceApp: "eSewa" | "Khalti" | ...
    │       ├── status: "pending" | "confirmed"
    │       ├── transactionId: string
    │       └── createdAt
    │
    ├── monthlyReports (subcollection)
    │   └── {monthKey} ← "2026-04"
    │       ├── totalExpense, totalIncome, netSavings
    │       ├── categoryBreakdown: { Food: 8500, ... }
    │       ├── budgetUtilization: { Food: 106, ... }
    │       ├── daysRemaining: 10
    │       ├── survivalBudgetPerDay: 380
    │       └── generatedAt
    │
    └── alerts (subcollection)
        └── {alertId}
            ├── type: "budget_warning" | "overspent" | ...
            ├── category: "Food"
            ├── message: "Only Rs 1200 left..."
            ├── severity: "low" | "medium" | "high"
            ├── isRead: false
            ├── monthKey: "2026-04"
            └── createdAt
```

**Schema Status:** 🔒 Locked for MVP (no changes without team approval)

---

## 🛠️ Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| **Frontend** | Flutter 3.19+ | Cross-platform, beautiful UI, fast development |
| **Backend** | FastAPI (Python 3.11+) | Async, fast, auto-docs, type safety |
| **Database** | Cloud Firestore | NoSQL, real-time, scalable, free tier |
| **Auth** | Firebase Authentication | Secure, battle-tested, auto token refresh |
| **AI/NLP** | Google Gemini 1.5 Flash | Free, fast, Nepali-aware, structured output |
| **Deployment** | Railway / Render | Free, auto-deploy from Git, HTTPS |
| **Notification** | flutter_notification_listener | Background SMS parsing |
| **Charts** | fl_chart | Beautiful Flutter graphs |
| **HTTP** | Dio | Flutter HTTP client with interceptors |

---

## 🔐 Security & Privacy

### Authentication Flow
```
1. User signs up via Firebase Auth (email + password)
2. Firebase returns idToken (expires in 1 hour)
3. Flutter SDK auto-refreshes token using refreshToken
4. Every API call includes: Authorization: Bearer <idToken>
5. Backend verifies token → extracts uid → isolates data
6. User never re-logs in unless they manually logout
```

### Data Isolation
- Each user's data stored under `users/{uid}`
- Backend always uses verified `uid` from token
- No user can access another user's data
- Firebase Security Rules enforce this at database level

### Token Auto-Refresh (No Re-Login Required)
```dart
// Flutter handles this automatically
final idToken = await FirebaseAuth.instance.currentUser!.getIdToken(true);
// ↑ Force refresh if expired. User stays logged in forever.
```

---

## 🚀 Getting Started

### Prerequisites
```bash
# Backend
Python 3.11+
Firebase Project with Firestore enabled
Google Cloud project with Gemini API enabled

# Frontend
Flutter 3.19+
Dart 3.0+
```

### Backend Setup

1. **Clone repository:**
```bash
git clone https://github.com/yourusername/bachatbot.git
cd bachatbot/backend
```

2. **Create virtual environment:**
```bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

3. **Install dependencies:**
```bash
pip install -r requirements.txt
```

4. **Add Firebase credentials:**
- Download `serviceAccountKey.json` from Firebase Console
- Place in `backend/` folder

5. **Create `.env` file:**
```env
GEMINI_API_KEY=your_gemini_api_key_here
```

6. **Run backend:**
```bash
uvicorn main:app --reload
```
Backend runs at: `http://localhost:8000`  
API docs at: `http://localhost:8000/docs`

### Frontend Setup

1. **Navigate to Flutter app:**
```bash
cd ../flutter_app
```

2. **Install dependencies:**
```bash
flutter pub get
```

3. **Configure Firebase:**
```bash
flutterfire configure
```

4. **Update API base URL:**
```dart
// lib/services/api_service.dart
final String baseUrl = "http://localhost:8000"; // or your deployed URL
```

5. **Run app:**
```bash
flutter run
```

---

## 📡 API Endpoints (Summary)

See [ENDPOINTS.md](ENDPOINTS.md) for complete specifications.

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/complete-signup` | POST | Create user profile after signup |
| `/api/v1/user/profile` | GET | Get user profile |
| `/api/v1/user/profile` | PATCH | Update onboarding/preferences |
| `/chat` | POST | Main AI endpoint (chat + notifications) |
| `/transactions` | GET | List transactions with filters |
| `/confirm-transaction/{id}` | POST | Confirm pending notification |
| `/reject-transaction/{id}` | POST | Reject pending notification |
| `/transactions/{id}` | DELETE | Soft delete transaction |
| `/budgets` | POST | Create/update budget |
| `/budgets` | GET | List budgets for month |
| `/monthly-report` | GET | Generate monthly report |
| `/alerts` | GET | Get alerts |
| `/alerts/{id}/read` | PATCH | Mark alert as read |
| `/messages` | GET | Get chat history |

All endpoints require: `Authorization: Bearer <idToken>`

---

## 🎨 Demo (Coming Soon)

### Screenshots
*Will be added in Week 13*

### Demo Video
*Final demo video will be ready by Week 14*

### Try it yourself
*APK link will be shared after Week 14*

---

## 📊 Project Status

**Current Phase:** Week 8/14 — Foundation & Auth Setup  
**Progress:** 35% Complete  
**Expected Launch:** End of April 2025

### Completed ✅
- Problem research & SDG mapping
- Market analysis & competitor study
- System design (UI/UX)
- Database schema finalization
- API contract documentation
- Initial chatbot logic

### In Progress 🔄
- Backend endpoint implementation
- Firebase Auth integration (Flutter)
- Chat UI development
- Transaction management

### Upcoming 📅
- Notification sync (Week 9–10)
- Budget system (Week 10–11)
- Smart alerts (Week 11–12)
- Monthly reports (Week 12–13)
- Testing & deployment (Week 13–14)

See [GANTT.md](GANTT.md) for detailed timeline.

---

## 👥 Team

| Name | Role | Responsibilities |
|------|------|------------------|
| **Kashish** | Backend Lead | FastAPI, Firebase Admin, Gemini AI, API design, deployment |
| **Namrata** | Frontend Lead | Flutter UI, screens, widgets, user experience |
| **Luniva** | Database & Architecture | Schema design, reports logic, graph data structure |
| **Sabitra** | DevOps & Testing | Deployment, notification listener, QA testing |

**Mentored by:** [Your mentor name]  
**Institution:** [Your college name]  
**Project Duration:** 14 weeks (Jan–Apr 2025)

---

## 🌍 Impact & SDG Alignment

### Target Audience
- 🎓 **Students** (college, +2) managing pocket money
- 💼 **Young professionals** (first job, 22–30 age)
- 🏠 **Hostel residents** tracking shared expenses
- 👨‍👩‍👧 **Young families** budgeting household costs

### Sustainable Development Goals (SDGs)
- **SDG 1:** No Poverty — Helps low-income users avoid debt through budget awareness
- **SDG 8:** Decent Work & Economic Growth — Promotes financial literacy
- **SDG 10:** Reduced Inequalities — Nepali language support makes finance tech accessible
- **SDG 12:** Responsible Consumption — Encourages conscious spending

### Expected Impact (Year 1)
- 5,000+ active users in Nepal
- Average 30% improvement in savings rate
- 70% reduction in manual expense tracking time
- Financial literacy increase through AI conversations

---

## 🔮 Future Roadmap (Post-MVP)

### Phase 2 (Q3 2025)
- Shared wallets (roommates, couples)
- Recurring expenses (rent, subscriptions)
- Investment suggestions based on savings
- Export reports (PDF, Excel)

### Phase 3 (Q4 2025)
- Voice input support
- WhatsApp bot integration
- Bill splitting with friends
- Merchant offers integration

### Phase 4 (2026)
- AI financial advisor
- Predictive budgeting
- Credit score insights
- Integration with Nepali banks

---

## 🤝 Contributing

Currently in private development for academic project.  
After April 2025 launch, we'll open-source the project.

Interested in collaborating? Contact: [your-email@example.com]

---

## 📄 License

Educational Project — [Your Institution Name]  
Not for commercial use without permission.

---

## 🙏 Acknowledgments

- **Firebase** for free infrastructure
- **Google Gemini** for AI capabilities
- **FastAPI** community for excellent docs
- **Flutter** team for beautiful framework
- Our beta testers for brutal honest feedback

---

## 📞 Contact

- **Project Lead:** Kashish ([your-email])
- **Frontend Lead:** Namrata ([namrata-email])
- **GitHub:** [github.com/yourusername/bachatbot](https://github.com/yourusername/bachatbot)
- **Demo:** (Coming soon)

---

<div align="center">

**Made with ❤️ in Nepal**

*Because tracking kharcha shouldn't feel like kharcha.*

[⬆ Back to top](#-bachatbot-बचत-बोट)

</div>

---

