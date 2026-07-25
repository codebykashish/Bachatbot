# BachatBot 💰

BachatBot is an AI-powered personal finance and expense-tracking application built specifically for the Nepali context. It allows users to track their expenses, set budgets, and achieve savings goals simply by chatting with an AI in Romanized Nepali (e.g., "500 momo ma khaye"). It also smartly reads bank and wallet notifications (eSewa, Khalti) to help automate expense tracking!

## 🌟 Key Features

- **Conversational Tracking**: Just tell the bot what you spent in natural language (Nepali, Roman Nepali, or English) — e.g., "Momo 250", "spent 500 on food".
- **Notification Sync**: Smartly reads bank and wallet SMS/notifications (eSewa, Khalti) to automate expense logging.
- **Financial & Behavior Engines**: It doesn't just track numbers. The app understands if your budget is on track, builds habits via streaks and milestones, and gives actionable advice.
- **Weekly Reflections**: Get a personalized, human-like summary of your weekly money habits instead of just raw charts.

## 🏗️ Architecture & Tech Stack

This project is divided into two main components:
- `frontend/` - The Flutter mobile application (Android/iOS) where the user interacts with the chatbot and dashboard.
- `backend/` - The FastAPI Python server that handles the Gemini AI logic, financial engine, and talks to the Firebase database.

**Core Technologies:**
- **Frontend**: Flutter (Dart)
- **Backend**: FastAPI (Python)
- **Database**: Google Firestore (NoSQL)
- **Authentication**: Firebase Authentication
- **AI / LLM**: Google Gemini (`google-generativeai`)
- **Push Notifications**: Firebase Cloud Messaging (FCM)
- **Background Jobs**: APScheduler (for monthly rollovers, daily snapshots)

> 💡 **Want to dive deeper?** Check out the comprehensive [Project Development Details](./project_developement_details.md) documentation for an in-depth look at the architecture, database schema, and internal systems!

---

## Requirements

Before starting, make sure you have the following installed on your computer:

**For Frontend:**
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (v3.0 or higher recommended)
- Dart SDK (comes with Flutter)

**For Backend:**
- [Python 3.10+](https://www.python.org/downloads/)
- All the required Python libraries are listed inside `backend/requirements.txt` (this includes FastAPI, Uvicorn, Firebase Admin, and Google Generative AI).

---

## Backend Setup (Python / FastAPI)

1. Open your terminal and navigate to the backend folder:
   ```bash
   cd backend
   ```

2. (Optional but recommended) Create and activate a virtual environment so you don't mess up your global Python packages:
   ```bash
   python -m venv venv
   # To activate on Windows:
   venv\Scripts\activate
   # To activate on Mac/Linux:
   source venv/bin/activate
   ```

3. Install all the required Python packages:
   ```bash
   pip install -r requirements.txt
   ```

4. Start the backend server:
   ```bash
   uvicorn main:app --reload
   ```
   *The server will usually start at `http://localhost:8000`.*

---

## Frontend Setup (Flutter)

1. Open a new terminal and navigate to the frontend folder:
   ```bash
   cd frontend
   ```

2. Download all the required Flutter packages:
   ```bash
   flutter pub get
   ```

3. Make sure you have a mobile emulator running (or a real phone plugged in), then run the app:
   ```bash
   flutter run
   ```

---

## Environment Variables & Secrets

For the app to work, it needs to connect to Google Gemini (for the AI) and Firebase (for the database). You must keep these secret!

### 1. Backend `.env` file
Create a file named `.env` inside the `backend/` folder and add your API keys:
```env
# Your Google Gemini API Key for the AI Chatbot
GEMINI_API_KEY=your_actual_api_key_here
```

### 2. Firebase Database Keys
- **Backend:** You need a file named `serviceAccountKey.json` (downloaded from your Firebase Project Settings). Place it directly inside the `backend/` folder.
- **Frontend:** You need a file named `google-services.json` (also from Firebase). Place it inside `frontend/android/app/`.

---

## Deployment

When you are ready to share BachatBot with the world:

- **Backend:** You can deploy the FastAPI code for free on platforms like **Render**, **Railway**, or **Vercel**. Just connect your GitHub repository to them. The start command will usually be: `uvicorn main:app --host 0.0.0.0 --port 8000`.
- **Frontend:** You can build an Android app (APK) to share with your friends or upload to the Play Store by running:
  ```bash
  cd frontend
  flutter build apk
  ```
  This will generate a `.apk` file that can be installed on any Android phone.
