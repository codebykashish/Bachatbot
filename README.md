# BachatBot 💰

BachatBot is an intelligent, AI-powered personal finance and expense-tracking application built specifically for the Nepali context. Track expenses, set budgets, and achieve savings goals simply by chatting with an AI in Romanized Nepali (e.g., "500 momo ma khaye"). 

Beyond just logging numbers, BachatBot acts as your personal **Smart Insights Engine**, offering smart insights, recovery plans when you overspend, and personalized weekly reviews.

---

## 🌟 Key Features

- **Conversational Tracking**: Tell the bot what you spent in natural language (Nepali, Roman Nepali, or English) — e.g., "Momo 250", "spent 500 on food".
- **Smart Insights Engine (New!)**: A smart dashboard that tracks your spending pace, analyzes your pure savings, and warns you if you are at risk of overspending.
- **Dynamic Recovery Plans**: If you overspend, the AI calculates exactly how much you should limit your daily spending to get back on track by the end of the month.
- **Weekly Reflections**: Every week, get a personalized, human-like summary of your money habits ("Your Week in Money") highlighting wins, unusual patterns, and next steps.
- **Notification Sync**: Smartly reads bank and wallet SMS/notifications (eSewa, Khalti) to automate expense logging.

---

## 🏗️ Architecture & Tech Stack

This project is divided into two main components:
- `frontend/` - The Flutter mobile application (Android/iOS) where the user interacts with the chatbot and dashboard.
- `backend/` - The FastAPI Python server that handles the Gemini AI logic, the financial engine, and talks to the Firebase database.

**Core Technologies:**
- **Frontend**: Flutter (Dart)
- **Backend**: FastAPI (Python)
- **Database**: Google Firestore (NoSQL)
- **Authentication**: Firebase Authentication
- **AI / LLM**: Google Gemini
- **Background Jobs**: APScheduler (for monthly rollovers, weekly insights)

> 💡 **Want to dive deeper?** Check out the comprehensive [Project Development Details](./project_developement_details.md) documentation for an in-depth look at the architecture, database schema, and internal systems!

---

## ⚙️ Setup & Installation

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (v3.0+)
- [Python 3.10+](https://www.python.org/downloads/)
- A Firebase Project (with Firestore and Authentication enabled)
- A Google Gemini API Key

### 1. Environment Variables & Secrets
You must keep your API keys and database credentials secure:

- **Backend `.env`**: Create `.env` inside the `backend/` folder:
  ```env
  GEMINI_API_KEY=your_actual_api_key_here
  ```
- **Backend Firebase Key**: Download `serviceAccountKey.json` from your Firebase Project Settings and place it directly inside `backend/`.
- **Frontend Firebase Key**: Download `google-services.json` from Firebase and place it inside `frontend/android/app/`.

### 2. Backend Setup (Python / FastAPI)
Open your terminal and navigate to the backend folder:
```bash
cd backend
python -m venv venv

# Activate (Windows): venv\Scripts\activate
# Activate (Mac/Linux): source venv/bin/activate

# Install required Python packages from requirements.txt
pip install -r requirements.txt
uvicorn main:app --reload
```
*The server will start at `http://localhost:8000`.*

### 3. Frontend Setup (Flutter)
Open a new terminal and navigate to the frontend folder:
```bash
cd frontend

# Download all required Flutter packages from pubspec.yaml
flutter pub get

flutter run
```
*(Ensure you have a mobile emulator running or an Android phone plugged in via USB debugging).*

---

## 🚀 Deployment

- **Backend**: Deploy the FastAPI server on platforms like **Render**, **Railway**, or **Vercel** by connecting your GitHub repository. (Start command: `uvicorn main:app --host 0.0.0.0 --port 8000`).
- **Frontend**: Build a release APK for Android devices:
  ```bash
  cd frontend
  flutter build apk
  ```
  The generated `.apk` file can be distributed and installed on Android phones.
