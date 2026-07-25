# BachatBot — Changes Log

## Session: Income Onboarding, Income Page, Tour Guide, Bills Removal

---

## What Changed & Where

### 1. Removed "Bills" Category

| File | Change |
|------|--------|
| `backend/schemas/categories.py` | Removed `BILLS` enum value and `"Bills"` from `EXPENSE_CATEGORIES` list |
| `frontend/lib/screens/home_screen.dart` | Removed Bills entry from `_catMeta` list |
| `frontend/lib/screens/categories_screen.dart` | Removed Bills entry from `_catMeta` list |

**Effect:** Bills no longer appears as a category anywhere in the app. Existing Bills transactions/budgets in Firestore are unaffected (they just won't display in category UI).

---

### 2. Declared Income Feature (Backend)

#### New file: `backend/routes/income.py`
- `GET /income` — returns user's declared income: `{inHand, inBank, onlineBanking, total}`
- `POST /income` — sets/updates declared income sources (partial update supported); creates alert notifications for each changed source (e.g. "Rs 500 added to In Hand income.")

#### `backend/schemas/profile.py`
- Added `IncomeData` model: `{inHand, inBank, onlineBanking, total}`
- Added `tourCompleted: bool = False` to `OnboardingData`
- Added `income: Optional[IncomeData]` to `UserProfileResponse`

#### `backend/routes/profile.py`
- `GET /profile` now returns `income` field (in-hand, in-bank, online-banking, total) extracted from user document

#### `backend/main.py`
- Registered `income_router` from `routes.income`

**Firestore structure added:**
```
users/{uid}
  income: {
    inHand: 5000.0,
    inBank: 15000.0,
    onlineBanking: 3000.0,
    updatedAt: timestamp
  }
```

---

### 3. Income Onboarding Flow (Frontend)

**New signup flow** (only for NEW users, existing users unaffected):
```
Signup → OnboardingScreen → IncomeOnboardingScreen → CategoryBudgetOnboardingScreen → HomeScreen (with tour)
```

#### New file: `frontend/lib/screens/income_onboarding_screen.dart`
- **Page 1 (Trust intro):** Privacy reassurance — "Your money, your privacy" — 3 trust points, "Let's Begin" button
- **Page 2 (Income input):** Cash in Hand, In Bank, Online Banking (eSewa/Khalti) fields; live total counter; "Continue" calls `POST /income`
- Progress dots at top; "Skip" button available at all times
- Navigates to `CategoryBudgetOnboardingScreen` on continue

#### New file: `frontend/lib/screens/category_budget_onboarding_screen.dart`
- **Step 1 (Category selection):** Grid of all 8 categories; tap to select/deselect; "Set Budgets →" or "Skip for now"
- **Step 2 (Budget allocation):** Budget field per selected category; live "Rs X remaining from Rs Y income" banner at top; turns red with "No more balance left" if over-allocated; calls `POST /budgets` for each non-zero budget; calls `PATCH /profile {onboarding: {isCompleted: true}}`; navigates to `MainScreen(showTour: true)`

#### `frontend/lib/screens/onboarding_screen.dart` (updated)
- `_save()` now sets `onboarding.isCompleted: false` (final `true` is set by CategoryBudgetOnboardingScreen)
- Navigates to `IncomeOnboardingScreen` instead of `HomeScreen`

---

### 4. Income Management Page (Frontend)

#### New file: `frontend/lib/screens/income_page.dart`
- **Total income card:** Gradient card showing combined total; "Rs X unallocated" badge (total income - sum of budget limits)
- **Income sources:** Three cards (In Hand / In Bank / Online Banking) each with inline edit; tap pencil → edit field with save/cancel buttons
- **Add income section:** Source chip selector (In Hand / In Bank / Online Banking); amount field; "Add" button adds on top of existing value and creates alert notification
- Accessible from home screen income card tap

---

### 5. First-Time User Tour Guide

#### New file: `frontend/lib/widgets/app_tour_overlay.dart`
- `AppTourOverlay` widget wraps the home screen content
- Activates when `showTour: true` AND SharedPreferences `tour_done` is not set
- 5 sequential steps with semi-transparent overlay and bottom info card:
  1. Dashboard overview
  2. Eye icon (hide/show amounts)
  3. Category budgets (scroll down)
  4. Monthly reports (scroll down)
  5. Chat FAB (bottom-right corner)
- "Next →" / "Got it! 🎉" to proceed; "Skip" dismisses all steps
- Saves `tour_done: true` to SharedPreferences on completion

#### `frontend/lib/screens/main_screen.dart` (updated)
- Added `showTour: bool = false` parameter; passed through to `HomeScreen`

#### `frontend/lib/screens/home_screen.dart` (updated)
- Added `showTour: bool = false` parameter
- Home body now wrapped in `AppTourOverlay(showTour: widget.showTour, child: content)`

---

### 6. Home Screen — Savings Card Redesign

#### `frontend/lib/widgets/balance_card.dart` (redesigned)
- **Big card renamed:** "Current Balance" → "Savings"
- **Parameter renamed:** `currentBalance` → `savings`
- Backwards-compatible `BalanceCard.legacy` factory constructor kept
- **Three savings states:**
  - Positive: green gradient, "Rs X saved", "X% of income saved" subtitle
  - Zero (income set but 0 savings): "Rs 0 · Keep tracking — savings start here! 💪"
  - Negative (over budget): red/orange gradient, "-Rs X", "Expenses exceed your income this month"
- **Mini cards redesigned:** Compact left-aligned layout with icon, label, amount; "View >" chevron shown when tappable
- Income card now shows "Total Income" label (tap → IncomePage)

#### `frontend/lib/screens/home_screen.dart` (updated)
- Added `_fetchIncome()` — calls `GET /income` to get declared income
- `_incomeForCard`: uses declared income if > 0, else falls back to transaction income from report
- `_savings` = `_incomeForCard - _totalExpense`
- Income card tap → `IncomePage` (was: `NotificationScreen(initialType: 'income')`)
- `BalanceCard` now uses `savings:` parameter
- Bills removed from `_catMeta`

---

### 7. Reports — Savings Section

#### `frontend/lib/screens/reports_screen.dart` (updated)
- Added `_declaredIncome` field; fetched via `GET /income` in parallel with report
- Added `_buildSavingsCard()` method:
  - Only shown when income is set (declared or transaction)
  - Positive savings: green card "You saved this month!" with amount and percentage
  - Negative savings: red card "Over budget this month" with deficit
- Savings card inserted between Total Spending and Category Chart

---

## API Endpoints Added

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/income` | JWT | Get declared income (inHand, inBank, onlineBanking, total) |
| POST | `/income` | JWT | Set/update income sources; creates alert per changed source |

---

## Data Flow Summary

```
New user signup
  → OnboardingScreen (occupation/housing/spend) → PATCH /profile {isCompleted: false}
  → IncomeOnboardingScreen → POST /income {inHand, inBank, onlineBanking}
  → CategoryBudgetOnboardingScreen → POST /budgets (x N) + PATCH /profile {isCompleted: true}
  → MainScreen(showTour: true)
  → HomeScreen shows AppTourOverlay (5-step guide, dismissed with SharedPrefs)

Returning user:
  → SplashScreen checks SharedPrefs onboarding_done → MainScreen (skips all new screens)
  → AppTourOverlay checks SharedPrefs tour_done → skips tour if already completed
```

---

## Files Changed Summary

| File | Type | Change |
|------|------|--------|
| `backend/schemas/categories.py` | Modified | Removed Bills |
| `backend/schemas/profile.py` | Modified | Added IncomeData, tourCompleted |
| `backend/routes/income.py` | **New** | GET/POST /income |
| `backend/routes/profile.py` | Modified | Returns income in GET /profile |
| `backend/main.py` | Modified | Registered income router |
| `frontend/lib/screens/income_onboarding_screen.dart` | **New** | Trust + income input pages |
| `frontend/lib/screens/category_budget_onboarding_screen.dart` | **New** | Category select + budget allocation |
| `frontend/lib/screens/income_page.dart` | **New** | Income management page |
| `frontend/lib/widgets/app_tour_overlay.dart` | **New** | First-time tour guide |
| `frontend/lib/screens/onboarding_screen.dart` | Modified | Navigate to income onboarding |
| `frontend/lib/widgets/balance_card.dart` | Modified | Savings redesign |
| `frontend/lib/screens/home_screen.dart` | Modified | Income fetch, savings, tour, Bills removed |
| `frontend/lib/screens/main_screen.dart` | Modified | showTour parameter |
| `frontend/lib/screens/reports_screen.dart` | Modified | Savings card |
| `frontend/lib/screens/categories_screen.dart` | Modified | Bills removed |

---

## Things NOT Changed (Preserved)
- Chat flow (expense/income logging via AI)
- Budget CRUD flows
- Category detail page
- Notification/Activity page
- Profile page
- Authentication flow (login/signup)
- All existing API endpoints (no fields removed)
- Firestore rules and indexes
