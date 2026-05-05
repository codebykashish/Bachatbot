# 📱 BachatBot App Flow & Architecture

> **Document Purpose:** This document defines the exact user journey, screen layouts, and core logic for the BachatBot application. All UI/UX and backend development must follow this flow.

---

## 1. 🔐 Authentication Flow

*   **First Open:** User lands on the **Login Page**.
*   **Sign Up:** User clicks "Create Account" ➡️ routes to **Signup Page**.
*   **Routing Logic:**
    *   🟢 *Successful Login* ➡️ Navigates directly to **Home Page**.
    *   🟢 *Successful Signup* ➡️ Navigates directly to **Home Page**.

---

## 2. 🧭 Global Navigation

No matter where the user is in the app, these navigation elements are always accessible:

*   **🔽 Bottom Navigation Bar (Footer):**
    1.  Home
    2.  Categories
    3.  Reports
*   **💬 Floating Action Button (FAB):** A Chat icon hovering at the bottom right (above the footer). Clicking this opens the **Chatbot Interface** from anywhere.
*   **🍔 Hamburger Menu (Top Left):** Opens a side drawer containing:
    *   ⚙️ Settings *(Placeholder/Empty for now)*
    *   ℹ️ About Us *(Routes to a static About Us page)*
    *   🚪 Logout *(Clears session and routes back to Login)*

---

## 3. 🏠 Home Page (Dashboard)

The central hub for the user's financial overview.

*   **💳 Income & Expense Cards:** Two prominent boxes at the top.
    *   *Interaction:* When clicked, they play a **flip animation** to reveal the total amount.
    *   *Logic:* Income amount visually reflects the "Available Balance" (Total Income - Total Expenses).
*   **🏷️ Categories Preview:** A mini-list of top spending categories with a "See All" button.
*   **📉 Report Preview:** A mini bar graph showing a quick visual insight into spending. *Clicking the graph navigates to the full Reports page.*

---

## 4. 🗂️ Categories & Budget Setting

Accessed via the Bottom Nav or "See All" on the Home Page.

*   **📋 List View:** Shows all categories (Food, Transport, Rent, etc.).
*   **📊 Progress Bars:** Each category shows budget utilization (e.g., `Food: 500 / 10,000`).
*   **⚙️ Manual Budget Setting:**
    *   When a user clicks on a category (e.g., Food), a **calculator/input pop-up** appears.
    *   User enters their *Total Monthly Budget* for that category.
    *   **⚠️ Rule:** The system always respects the **latest** budget set (whether set manually via this UI *or* via the Chatbot).

---

## 5. 📊 Reports & Analytics

Accessed via the Bottom Nav or the Home page Report Preview graph.

*   **📈 Visuals:** A detailed Bar Graph providing month-wise insights (Amount vs. Category).
*   **🔍 Budget Breakdown:** Below the graph, a notification-style list of categories showing exact utilization limits (e.g., `Food: 5,000 / 10,000`).

---

## 6. 🤖 The Chatbot Engine (Core Feature)

Accessed via the FAB. Users can talk naturally instead of doing manual data entry.

### 🎯 Setting Budgets
> **🧑 User:** "Set my food budget to 5000 for this month."
> **🤖 Bot:** "Noted. 5000 Food budget has been updated." *(Updates database)*

### 💸 Logging Expenses
> **🧑 User:** "I ate momo for 500."
> **🤖 Bot:** "500 for momo saved." *(Updates Expense total and Food category progress)*
*   **Tracking:** Saved in DB with `source: "chat"`.

### 💰 Logging Income
> **🧑 User:** "Add 5000 to my income."
> **🤖 Bot:** "Income updated." *(Adds to total balance)*

### 🧠 Smart Duplicate Detection
*If a user logs an identical amount for the same category on the same day (e.g., 150 for Momo in the morning, and 150 for Momo in the afternoon).*
> **🤖 Bot:** "Earlier today you also said 150 for momo. Are you spending this again? Should I save this too?"
> **🧑 User:** Confirms (saves) OR Dismisses (ignores).

---

## 7. 📲 Notification Sync (Automation)

The app runs a background listener to read incoming SMS/Push notifications from digital wallets (eSewa, Khalti) and Banks.

### 🔻 Expense Deduction Detected
*   **⚙️ System:** Reads SMS (e.g., *"Rs 500 transferred"*).
*   **🤖 Bot (in chat):** "Did you transfer Rs 500? Which category?"
*   **🧑 User:** "Yes, Food."
*   **⚙️ System:** Deducts 500 from Food budget and triggers an in-app notification.
*   **Tracking:** Saved in DB with `source: "notification"`.

### 🔺 Income Deposit Detected
*   **⚙️ System:** Reads SMS of money received.
*   **🤖 Bot:** "Rs 5000 was deposited. Is this your income?"
*   **🧑 User:** Confirms.
*   **⚙️ System:** Adds to total balance.

---

## 8. ⚠️ Alerts & Notifications System

Keeps the user informed about their financial health.

*   **📬 Delivery:** Push notifications sent to the device + saved in the in-app **Notifications Page**.
*   **🎛️ Filtering:** Users can filter their notification history by:
    *   📅 Week
    *   🗓️ Month
    *   🏷️ Category
*   **🚨 Triggers:** Automated warnings triggered when a category budget is nearing its limit or has been exceeded.
