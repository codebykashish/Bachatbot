# BachatBot — Flutter Frontend

Nepal's first conversational AI expense tracker. Chat in Nepali, Roman Nepali, or English to log expenses, set budgets, and get monthly financial insights.

---

## Prerequisites

Before you can run this project, install the following:

| Tool | Version | Download |
|------|---------|----------|
| Flutter SDK | ≥ 3.0.0 | https://docs.flutter.dev/get-started/install |
| Dart SDK | ≥ 3.0.0 (bundled with Flutter) | — |
| Android Studio | Any recent | https://developer.android.com/studio |
| Java JDK | 17 recommended | https://adoptium.net |
| Git | Any | https://git-scm.com |

Verify your setup:
```bash
flutter doctor
```
All checkmarks should be green before continuing.

---

## 1. Clone the repository

```bash
git clone <repo-url>
cd bachatbot
```

---

## 2. Firebase setup

This project uses **Firebase Auth**, **Cloud Firestore**, and **Firebase Storage**.
You need to connect the app to your own Firebase project.

### 2a. Create a Firebase project

1. Go to https://console.firebase.google.com
2. Create a new project (e.g. `bachatbot-dev`)
3. Enable **Authentication** → Sign-in method → **Email/Password**
4. Enable **Cloud Firestore** (start in test mode for dev, production rules later)
5. Enable **Storage**

### 2b. Add the Android app

1. In Firebase Console → Project settings → Add app → Android
2. Use package name: `com.example.bachatbot_flutter`
   (check `android/app/build.gradle` for the actual `applicationId`)
3. Download `google-services.json`
4. Place it at: `android/app/google-services.json`

> **This file is gitignored and NOT included in the repo.**
> Every developer must download their own copy from Firebase Console.

### 2c. (iOS only) Add the iOS app

1. In Firebase Console → Add app → iOS
2. Use bundle ID from `ios/Runner.xcodeproj`
3. Download `GoogleService-Info.plist`
4. Place it at: `ios/Runner/GoogleService-Info.plist`

### 2d. Set Firebase Storage rules

In Firebase Console → Storage → Rules, paste:

```
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /profile_photos/{userId}.jpg {
      allow read: if true;
      allow write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

---

## 3. Configure the backend URL

Open `lib/api_service.dart` and update the `baseUrl`:

```dart
static const String baseUrl = "YOUR_BACKEND_URL_HERE";
```

| Environment | Value |
|-------------|-------|
| Android Emulator (local backend) | `http://10.0.2.2:3000` |
| Physical device (local backend) | `http://<your-wifi-ip>:3000` |
| Deployed backend (ngrok / cloud) | `https://your-ngrok-or-server-url` |

---

## 4. Install dependencies

```bash
flutter pub get
```

This installs all packages listed in `pubspec.yaml`.

---

## 5. Run the app

```bash
# List connected devices
flutter devices

# Run on a specific device
flutter run -d <device-id>

# Run in debug mode (default)
flutter run

# Run in release mode
flutter run --release
```

---

## 6. Build APK (Android)

```bash
# Debug APK
flutter build apk --debug

# Release APK (requires signing config)
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `firebase_core` | Firebase initialization |
| `firebase_auth` | Email/password authentication |
| `cloud_firestore` | Real-time database (notifications, month events) |
| `firebase_storage` | Profile photo uploads |
| `http` | REST API calls to the BachatBot backend |
| `fl_chart` | Bar charts on Reports and Home screen |
| `image_picker` | Profile photo — gallery or camera |
| `url_launcher` | mailto: and tel: links in Contact Us |
| `intl` | Date formatting on the Activity (notifications) page |
| `google_fonts` | Typography |
| `notification_listener_service` | Android SMS/notification parsing for expense sync |
| `shared_preferences` | Local key-value storage |

---

## Android permissions

The following permissions are declared in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE" />
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.CAMERA" />
```

`BIND_NOTIFICATION_LISTENER_SERVICE` requires the user to manually enable
**"Notification Access"** for BachatBot in Android Settings → Apps → Special App Access.
The app prompts for this on first launch.

---

## iOS permissions

Declared in `ios/Runner/Info.plist`:

| Key | Reason |
|-----|--------|
| `NSPhotoLibraryUsageDescription` | Upload profile photo from gallery |
| `NSCameraUsageDescription` | Take a profile photo |

---

## Project structure

```
lib/
├── main.dart                    # App entry point, Firebase init
├── api_service.dart             # All HTTP calls to the backend
├── screens/
│   ├── splash_screen.dart
│   ├── onboarding_screen.dart
│   ├── login_screen.dart
│   ├── signup_screen.dart
│   ├── main_screen.dart         # Bottom nav + FAB shell
│   ├── home_screen.dart         # Dashboard
│   ├── chat_screen.dart         # Chat with BachatBot AI
│   ├── categories_screen.dart   # Budget per category
│   ├── reports_screen.dart      # Monthly report + charts
│   ├── notification_screen.dart # Activity feed (alerts)
│   ├── profile_screen.dart      # User profile + settings
│   ├── edit_profile_screen.dart
│   ├── about_us_screen.dart
│   ├── faqs_screen.dart
│   ├── contact_us_screen.dart
│   ├── help_screen.dart
│   └── mock_notification_screen.dart  # Dev tool
├── widgets/
│   ├── balance_card.dart        # Income / expense summary cards
│   └── report_chart.dart        # Reusable bar chart
└── services/
    ├── notification_sync_service.dart
    └── month_event_service.dart
```

---

## Common issues

**`google-services.json` not found**
→ Download it from Firebase Console and place it at `android/app/google-services.json`.

**`Permission denied` on Firebase Storage upload**
→ Check Storage Rules (step 2d above). The authenticated user's UID must match the file path.

**App can't reach the backend**
→ Verify `baseUrl` in `api_service.dart`. On Android emulator use `10.0.2.2`, not `localhost`.

**`flutter pub get` fails with version conflicts**
→ Run `flutter upgrade` to update the Flutter SDK, then retry `flutter pub get`.

**Notification sync not working on Android**
→ Manually grant "Notification Access" in Android Settings → Apps → Special App Access → Notification Access → BachatBot.

---

## Team

**TEAM SANKALPA** — Sunway College, Nepal (2025)

| Name | Role |
|------|------|
| Kashish | Backend & AI Lead |
| Namrata | Flutter Frontend Lead |
| Luniva | Database & Architecture |
| Sabitra | DevOps & Testing |
