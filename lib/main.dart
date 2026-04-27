import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/signup_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_screen.dart';
import 'api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // TEMP: Force login screen for testing (remove later)
  await FirebaseAuth.instance.signOut();

  runApp(const MyApp());
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/signup': (context) => const SignupScreen(),
        '/onboarding': (context) => const OnboardingScreen(),
        '/home': (context) => const HomeScreen(),
      },
      home: const AuthWrapper(),
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
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (!snapshot.hasData || snapshot.data == null) {
          return const LoginScreen();
        }
        return const ProfileChecker();
      },
    );
  }
}

class ProfileChecker extends StatefulWidget {
  const ProfileChecker({super.key});

  @override
  State<ProfileChecker> createState() => _ProfileCheckerState();
}

class _ProfileCheckerState extends State<ProfileChecker> {
  @override
  void initState() {
    super.initState();
    checkProfile();
  }

  Future<void> checkProfile() async {
    try {
      print("GET /profile...");
      final response = await ApiService.get("/profile");
      print("Profile response: $response");

      final onboarding = response['data']['onboarding'] ?? {};
      final isCompleted = onboarding['isCompleted'] ?? false;

      print("Onboarding completed: $isCompleted");

      if (!mounted) return;

      if (isCompleted) {
        Navigator.pushReplacementNamed(context, '/home');
      } else {
        Navigator.pushReplacementNamed(context, '/onboarding');
      }
    } catch (e) {
      print("Profile error: $e");
      // Fallback to home
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("Loading..."),
          ],
        ),
      ),
    );
  }
}