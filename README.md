# BachatBot (बचत-बोट)

<div align="center">

**Know your kharcha, grow your bachat.**

[![Status](https://img.shields.io/badge/Status-Shipped-brightgreen)](https://github.com/yourusername/bachatbot)
[![License](https://img.shields.io/badge/License-Educational-blue)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.19+-blue)](https://flutter.dev)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.110+-green)](https://fastapi.tiangolo.com)

*Nepal's first truly conversational expense tracker — chat in Nepali, Roman Nepali, or English.*

[Features](#-features) • [Architecture](#-architecture) • [Setup](#-getting-started) • [API](#-api-endpoints) • [Team](#-team)

</div>

---

## The Problem

Traditional expense tracking apps in Nepal are:
- **Form-heavy** — boring input fields kill motivation
- **English-only** — excludes Roman Nepali speakers
- **Manual** — users forget to log expenses
- **No context** — just numbers, no real insights

**BachatBot removes all friction through conversational AI.**

---

## How It Works

Instead of filling forms, users just chat:

```
User: Momo khada 250 gayo
Bot:  Rs 250 Food ma save gareko chu ✓
      Food: Rs 2,250 / 5,000 used (45%)
```

Bank/eSewa notifications are auto-parsed:

```
eSewa SMS: "Payment of Rs 1,250 successful"
         ↓ (auto-detected in background)
Bot:  eSewa bata Rs 1,250 Shopping ma kharcha bhako jasto cha.
      Confirm garnu hos? [Yes] [No]
```

No manual entry. Zero effort.

---

## Features

### Natural Language Expense Tracking
Log in **Nepali**, **Roman Nepali**, or **English** — even mixed:
```
"Momo 250"
"Bhatbhateni ma 3400 shopping gareko"
"Rent 12k pathaye"
"Salary 45k aayo"
"200 momo, 20 bus ma kharcha"   ← multiple at once
```
AI extracts amount, category, and type automatically.

### Smart Bank Notification Sync
- Listens to eSewa, Khalti, IME Pay, and Nepali bank SMS in the background
- Parses amount + category → saved as **pending**
- User confirms in chat → becomes permanent
- Zero typing for digital payments

### Budget Management
Set and manage monthly budgets per category from the app or via chat:
```
"Set my food budget to 5000"
"Change rent to 12k"
```
- Cannot set a budget lower than what you've already spent that month
- "Unallocated income" shown when editing — you always know how much is left to assign
- Budget alerts at 80% and 100% usage

### Activity Feed (Notifications)
- All budget warnings, income logs, and expense alerts in one feed
- Tap any alert to jump directly to the related category page
- Filter by type, time range, and category
- Income alerts are highlighted in green; tap to mark as read

### Undo System
- Every manually-added expense or income entry has an **Undo** button
- Undoing an expense removes the record and decrements `budget.spent` automatically
- Undoing an income entry reverses the income delta for the correct source (in-hand / bank / online)
- Available in the Activity feed, Category detail page, and Income history page

### Monthly Reports
- Total income, total expense, net savings
- Category-by-category spending breakdown
- Spending status: **Low** (green) / **Medium** (yellow) / **High** (red)
- Month navigation to view past history

### Category Savings Tracker
- Savings = **Declared Income − Total Spent** (when income is set)
- Falls back to Total Budget − Total Spent when no income declared
- Prominent income card on Categories screen nudges users to set income first

### Profile & Account
- Profile photo upload (via Cloudinary)
- Edit first name and last name (always fetches fresh data so name is current)
- Home screen greeting updates immediately after name change

---

## Architecture

```
┌───────────────────────────────────────────────┐
│              Flutter App (Frontend)            │
│  Firebase Auth · Chat UI · Reports · Budgets  │
│  Background Notification Listener (Android)   │
└──────────────────┬────────────────────────────┘
                   │ HTTPS  Authorization: Bearer <idToken>
┌──────────────────▼────────────────────────────┐
│           FastAPI Backend (Python)             │
│  Firebase Admin SDK · Google Gemini 2.5 Flash │
│  Budget Logic · Alert Engine · Report Builder │
└──────────────────┬────────────────────────────┘
                   │ Firebase Admin SDK
┌──────────────────▼────────────────────────────┐
│              Cloud Firestore                   │
│  users/{uid}/                                  │
│    transactions · budgets · alerts · messages  │
└───────────────────────────────────────────────┘
```

**Key principle:** Flutter never writes to Firestore directly. All data flows through the backend API, which verifies identity on every request.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | Flutter 3.19+, Dart 3 |
| **Backend** | FastAPI (Python 3.11+) |
| **Database** | Cloud Firestore |
| **Auth** | Firebase Authentication (Email/Password) |
| **AI / NLP** | Google Gemini 2.5 Flash |
| **Image Storage** | Cloudinary |
| **Notifications** | flutter_notification_listener |
| **Charts** | fl_chart |

---

## Database Schema

```
users/{uid}
  ├── firstName, lastName, email, phone
  ├── photoUrl
  ├── income: { inHand, inBank, onlineBanking }  ← total = sum of three
  ├── onboarding: { isCompleted, occupation, housingType }
  ├── preferences: { language, currency, alertThreshold }
  ├── createdAt, updatedAt
  │
  ├── transactions/{txId}
  │     amount, category, type (expense|income), status (confirmed|pending|rejected)
  │     source (chat|manual|notification), description, monthKey, isDeleted
  │
  ├── budgets/{budgetId}
  │     category, limit, spent, alertThreshold, monthKey
  │
  ├── alerts/{alertId}
  │     type (expense|income|budget_set|budget_warning|overspent|budget_rebalanced)
  │     category, message, severity, isRead, monthKey
  │
  └── messages/{msgId}
        role (user|assistant), content, intent, extractedData, relatedTransactionId
```

---

## Security

- Every API call requires `Authorization: Bearer <Firebase idToken>`
- Backend always uses the verified `uid` from the token — never a user-supplied value
- Users can only read and write their own data
- Token auto-refresh happens client-side; users stay logged in without re-authenticating

---

## Getting Started

### Prerequisites

```
Backend:  Python 3.11+, Firebase project (Firestore enabled), Gemini API key
Frontend: Flutter 3.19+, Dart 3, Android Studio / Xcode
```

### Backend

```bash
cd backend
python -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

Add credentials:
```
backend/serviceAccountKey.json    ← Firebase service account (from Firebase Console)
backend/.env                      ← GEMINI_API_KEY=your_key_here
```

Run:
```bash
uvicorn main:app --reload
# API docs: http://localhost:8000/docs
```

### Frontend

```bash
cd frontend
flutter pub get
flutterfire configure               # links Firebase project
```

Set the API base URL in `lib/api_service.dart`:
```dart
static const String baseUrl = 'http://localhost:8000';  // or your deployed URL
```

Run:
```bash
flutter run
```

---

## API Endpoints

Full specs in [endpoints.md](endpoints.md).

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/complete-signup` | POST | Create profile after Firebase signup |
| `/profile` | GET | Get full user profile |
| `/profile` | PATCH | Update name, photo, preferences |
| `/income` | GET / POST | Declare monthly income |
| `/chat` | POST | Main AI endpoint — NLP + transaction logging |
| `/transactions` | GET | List transactions (filters: month, category, type) |
| `/transactions/{id}` | DELETE | Soft-delete a transaction |
| `/budgets` | GET / POST | List or create/update budgets |
| `/budgets/{category}` | DELETE | Remove a category budget |
| `/monthly-report` | GET | Full month report with category breakdown |
| `/alerts` | GET | Activity feed (filters: type, dateRange, category) |
| `/alerts/{id}/read` | PATCH | Mark alert as read |
| `/alerts/{id}/undo` | POST | Undo an entry — reverses financial effect + soft-deletes alert |
| `/messages` | GET | Chat history |
| `/upload/profile-photo` | POST | Upload photo to Cloudinary |

All endpoints: `Authorization: Bearer <idToken>` required.

---

## Email Policy

Signup accepts any legitimate email domain:
- `gmail.com`, `yahoo.com`, `outlook.com`, `hotmail.com`, `icloud.com`
- Educational: `.edu`, `.edu.np`, `.ac.uk`, `.ac.in`, and similar
- Institutional: `.org`, `.gov`, `.gov.np`

Known disposable/throwaway services are blocked.

---

## Team

| Name | Role |
|------|------|
| **Kashish** | Backend — FastAPI, Gemini AI, Firebase Admin, deployment |
| **Namrata** | Frontend — Flutter UI, screens, widgets, UX |
| **Luniva** | Database & Architecture — schema, reports, analytics |
| **Sabitra** | DevOps & QA — notification sync, testing, deployment |

**Institution:** Sunway College, Kathmandu  
**Program:** BIT (Bachelor of Information Technology)

---

## SDG Alignment

| SDG | Connection |
|-----|-----------|
| **SDG 1** No Poverty | Budget awareness reduces unnecessary debt |
| **SDG 8** Decent Work | Promotes financial literacy for young workers |
| **SDG 10** Reduced Inequalities | Nepali-language support makes finance tech accessible |
| **SDG 12** Responsible Consumption | Encourages mindful, data-driven spending |

---

<div align="center">

Made with ❤️ in Nepal

*Because tracking kharcha shouldn't feel like kharcha.*

</div>
