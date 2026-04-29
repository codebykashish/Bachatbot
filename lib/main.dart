import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BachatBot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
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
          return const _SplashScreen();
        }
        if (!snapshot.hasData || snapshot.data == null) {
          return const LoginScreen();
        }
        return const ProfileChecker();
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF2E7D32),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.savings, size: 80, color: Colors.white),
            SizedBox(height: 16),
            Text('BachatBot', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
            SizedBox(height: 32),
            CircularProgressIndicator(color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class ProfileChecker extends StatefulWidget {
  const ProfileChecker({super.key});

  @override
  State<ProfileChecker> createState() => _ProfileCheckerState();
}

class _ProfileCheckerState extends State<ProfileChecker> {
  String _status = "Authenticating...";

  @override
  void initState() {
    super.initState();
    _checkProfileSafely();
  }

  Future<void> _checkProfileSafely() async {
    try {
      setState(() => _status = "Getting fresh token...");
      await Future.delayed(const Duration(milliseconds: 600));

      final response = await ApiService.get("/profile");
      print("📡 PROFILE RESPONSE: $response");

      if (!mounted) return;

      if (response['success'] == true) {
        final onboarding = response['data']?['onboarding'] ?? {};
        final isCompleted = onboarding['isCompleted'] ?? false;

        if (isCompleted) {
          setState(() => _status = "Going to Home Screen...");
          _navigateTo(const HomeScreen());
        } else {
          setState(() => _status = "Going to Onboarding...");
          _navigateTo(const OnboardingScreen());
        }
      } else {
        setState(() => _status = "No profile found → Onboarding");
        _navigateTo(const OnboardingScreen());
      }
    } catch (e) {
      print("❌ PROFILE CHECKER ERROR: $e");
      if (!mounted) return;

      setState(() => _status = "Connection error.\nGoing to Home Screen...");

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _navigateTo(const HomeScreen());
    }
  }

  void _navigateTo(Widget screen) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2E7D32),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.savings, size: 80, color: Colors.white),
            const SizedBox(height: 24),
            const Text('BachatBot', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 40),
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                _status,
                style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}