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
                            SizedBox(height: isLandscape ? 10 : screenHeight * 0.06),
                            // Mini chat preview
                            Container(
                              width: illustrationSize * 1.15,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: [
                                  BoxShadow(
                                    color: primaryColor.withValues(alpha: 0.12),
                                    blurRadius: 24,
                                    offset: const Offset(0, 8),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                                border: Border.all(color: primaryColor.withValues(alpha: 0.1)),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 14,
                                        backgroundColor: primaryColor.withValues(alpha: 0.12),
                                        child: const Icon(Icons.smart_toy_outlined, color: primaryColor, size: 16),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'BachatBot',
                                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12),
                                      ),
                                      const Spacer(),
                                      Container(
                                        width: 7, height: 7,
                                        decoration: const BoxDecoration(color: Color(0xFF4CAF50), shape: BoxShape.circle),
                                      ),
                                      const SizedBox(width: 5),
                                      Text('Online', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                                    ],
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    child: Divider(height: 1, color: Colors.grey.shade100),
                                  ),
                                  _chatBubble(isUser: true, text: 'Momo khayo 250 😋', primaryColor: primaryColor),
                                  const SizedBox(height: 7),
                                  _chatBubble(isUser: false, text: '✓ Rs 250 Food ma save bhayo!\nFood: Rs 2,250 / 5,000 (45%)', primaryColor: primaryColor),
                                  const SizedBox(height: 7),
                                  _chatBubble(isUser: true, text: 'Bus 40 gayo', primaryColor: primaryColor),
                                  const SizedBox(height: 7),
                                  _chatBubble(isUser: false, text: '✓ Rs 40 Transport ma save bhayo!', primaryColor: primaryColor),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            // Value badges
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _valueBadge('⚡', '5 seconds', primaryColor),
                                const SizedBox(width: 8),
                                _valueBadge('💬', 'Nepali OK', primaryColor),
                                const SizedBox(width: 8),
                                _valueBadge('🆓', 'Free', primaryColor),
                              ],
                            ),
                            SizedBox(height: screenHeight * 0.04),
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

  Widget _chatBubble({required bool isUser, required String text, required Color primaryColor}) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: isUser ? primaryColor : const Color(0xFFF6F7F9),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isUser ? 12 : 2),
            bottomRight: Radius.circular(isUser ? 2 : 12),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isUser ? Colors.white : Colors.black87,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _valueBadge(String emoji, String label, Color primaryColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: primaryColor.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1B5E20),
            ),
          ),
        ],
      ),
    );
  }
}
