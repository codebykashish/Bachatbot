import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/onboarding_model.dart';
import 'onboarding_features_screen.dart';

class GetStartedScreen extends StatefulWidget {
  const GetStartedScreen({super.key});

  @override
  State<GetStartedScreen> createState() => _GetStartedScreenState();
}

class _GetStartedScreenState extends State<GetStartedScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 0.15),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.9, curve: Curves.easeOutCubic)),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isLandscape = mediaQuery.orientation == Orientation.landscape;
    final screenHeight = mediaQuery.size.height;
    final screenWidth = mediaQuery.size.width;

    const primaryColor = Color(0xFF2DBD7F); // Branding Color
    const deepGreen = Color(0xFF1B5E20); // Deep green for text

    // Responsive sizing
    final illustrationSize = isLandscape ? screenHeight * 0.35 : screenWidth * 0.65;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.4),
              radius: 1.2,
              colors: [
                primaryColor.withValues(alpha: 0.06),
                Colors.white,
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: _slideAnimation,
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(height: isLandscape ? 10 : screenHeight * 0.08),
                            // Large Creative Money Flow Illustration
                            Container(
                              width: illustrationSize,
                              height: illustrationSize,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: primaryColor.withValues(alpha: 0.05),
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Floating circles behind
                                  Positioned(
                                    left: illustrationSize * 0.1,
                                    top: illustrationSize * 0.1,
                                    child: CircleAvatar(
                                      radius: illustrationSize * 0.08,
                                      backgroundColor: const Color(0xFFFFB300).withValues(alpha: 0.15),
                                      child: const Icon(Icons.attach_money, color: Color(0xFFFFB300)),
                                    ),
                                  ),
                                  Positioned(
                                    right: illustrationSize * 0.12,
                                    bottom: illustrationSize * 0.15,
                                    child: CircleAvatar(
                                      radius: illustrationSize * 0.07,
                                      backgroundColor: primaryColor.withValues(alpha: 0.15),
                                      child: const Icon(Icons.trending_up, color: primaryColor),
                                    ),
                                  ),
                                  // Hand holding phone representation
                                  Icon(
                                    Icons.phone_android_rounded,
                                    size: illustrationSize * 0.55,
                                    color: Colors.grey.shade800,
                                  ),
                                  Positioned(
                                    top: illustrationSize * 0.32,
                                    child: Icon(
                                      Icons.touch_app_rounded,
                                      size: illustrationSize * 0.2,
                                      color: primaryColor,
                                    ),
                                  ),
                                  // Floating coins/dollars
                                  Positioned(
                                    top: illustrationSize * 0.18,
                                    right: illustrationSize * 0.18,
                                    child: const Icon(
                                      Icons.monetization_on_rounded,
                                      color: Color(0xFFFFB300),
                                      size: 32,
                                    ),
                                  ),
                                  Positioned(
                                    bottom: illustrationSize * 0.28,
                                    left: illustrationSize * 0.15,
                                    child: const Icon(
                                      Icons.savings_rounded,
                                      color: Color(0xFFFFB300),
                                      size: 36,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: screenHeight * 0.06),
                            // Bold Title
                            Text(
                              OnboardingStrings.getStartedTitle,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: deepGreen,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Subtitle
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0),
                              child: Text(
                                OnboardingStrings.getStartedSubtitle,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  color: Colors.grey.shade600,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Action Buttons at Bottom
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Get Started Button
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                PageRouteBuilder(
                                  pageBuilder: (context, animation, secondaryAnimation) => const OnboardingFeaturesScreen(),
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
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryColor,
                              foregroundColor: Colors.white,
                              elevation: 2,
                              shadowColor: primaryColor.withValues(alpha: 0.3),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Text(
                              OnboardingStrings.getStartedButton,
                              style: GoogleFonts.poppins(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Already have account -> Sign In
                        TextButton(
                          onPressed: () {
                            Navigator.pushReplacementNamed(context, '/login');
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: primaryColor,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          child: Text(
                            OnboardingStrings.alreadyHaveAccount,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
