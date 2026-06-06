import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/onboarding_model.dart';
import 'get_started_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    
    // Fade-in animation setup
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );

    _animationController.forward();
    _startTimer();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _startTimer() {
    Timer(const Duration(seconds: 3), _checkOnboardingStatus);
  }

  Future<void> _checkOnboardingStatus() async {
    if (!mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final onboardingDone = prefs.getBool('onboarding_done') ?? false;

      if (!mounted) return;

      if (onboardingDone) {
        // Returning user -> Navigate to Login/Signup directly
        Navigator.pushReplacementNamed(context, '/login');
      } else {
        // First time user -> Navigate to Get Started screen
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) => const GetStartedScreen(),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              const begin = Offset(1.0, 0.0);
              const end = Offset.zero;
              const curve = Curves.easeInOutCubic;
              var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
              return SlideTransition(position: animation.drive(tween), child: child);
            },
            transitionDuration: const Duration(milliseconds: 600),
          ),
        );
      }
    } catch (e) {
      // Graceful fallback to Get Started Screen if SharedPreferences fails
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const GetStartedScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final logoSize = mediaQuery.size.width * 0.32;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1B5E20), // Deep Green representing growth
              Color(0xFF2DBD7F), // Branding Color #2DBD7F
              Color(0xFF4CAF50), // Secondary Light Green
            ],
            stops: [0.0, 0.6, 1.0],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // Logo and Title Center
              Center(
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Rounded Logo container with soft shadow
                      Container(
                        width: logoSize,
                        height: logoSize,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 25,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.asset(
                            'assets/images/expenseai_logo.png',
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              // Fallback Logo composition in case image is missing
                              return Stack(
                                alignment: Alignment.center,
                                children: [
                                  Icon(
                                    Icons.account_balance_wallet_rounded,
                                    size: logoSize * 0.45,
                                    color: const Color(0xFF2DBD7F),
                                  ),
                                  Positioned(
                                    right: 2,
                                    top: 2,
                                    child: Icon(
                                      Icons.smart_toy_rounded,
                                      size: logoSize * 0.28,
                                      color: const Color(0xFFFFB300),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // App Name
                      Text(
                        OnboardingStrings.appName,
                        style: GoogleFonts.poppins(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Tagline
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32.0),
                        child: Text(
                          OnboardingStrings.splashTagline,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            color: Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Loading indicator at bottom
              Positioned(
                bottom: 50,
                left: 0,
                right: 0,
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
