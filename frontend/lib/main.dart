
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // Import Cloud Firestore
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/email_signup_page.dart';
import 'screens/main_screen.dart';
import 'screens/splash_screen.dart';
import 'api_service.dart';
import 'services/push_notification_service.dart';
import 'widgets/ambient_status_overlay.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // ENABLE FIRESTORE OFFLINE PERSISTENCE:q
  // Configure Firestore settings to enable offline local caching and unlimited cache size.
  // This allows local reads and writes to work seamlessly without network connectivity.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'BachatBot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2DBD7F)),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
      routes: {
        '/login': (context) => const LoginScreen(),
        '/signup': (context) => const EmailSignupPage(),
      },
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            const Positioned.fill(child: AmbientStatusOverlay()),
          ],
        );
      },
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF2DBE7F),
            body: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          );
        }
        if (snapshot.hasData && snapshot.data != null) {
          return FutureBuilder<dynamic>(
            future: ApiService.get('/profile'),
            builder: (context, profileSnapshot) {
              if (profileSnapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  backgroundColor: Color(0xFF2DBE7F),
                  body: Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                );
              }
              String firstName = 'User';
              if (profileSnapshot.hasData) {
                final res = profileSnapshot.data;
                if (res != null && res['success'] == true && res['data'] != null) {
                  firstName = res['data']['firstName'] as String? ?? 'User';
                }
              }
              return MainScreen(firstName: firstName);
            },
          );
        }
        return const LoginScreen();
      },
    );
  }
}
