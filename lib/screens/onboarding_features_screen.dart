import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/onboarding_model.dart';
import '../widgets/feature_page.dart';

class OnboardingFeaturesScreen extends StatefulWidget {
  const OnboardingFeaturesScreen({super.key});

  @override
  State<OnboardingFeaturesScreen> createState() => _OnboardingFeaturesScreenState();
}

class _OnboardingFeaturesScreenState extends State<OnboardingFeaturesScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<OnboardingModel> _features = const [
    OnboardingModel(
      title: OnboardingStrings.feature1Title,
      description: OnboardingStrings.feature1Desc,
      icon: Icons.chat_bubble_outline,
    ),
    OnboardingModel(
      title: OnboardingStrings.feature2Title,
      description: OnboardingStrings.feature2Desc,
      icon: Icons.pie_chart_outline,
    ),
    OnboardingModel(
      title: OnboardingStrings.feature3Title,
      description: OnboardingStrings.feature3Desc,
      icon: Icons.analytics_outlined,
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _completeOnboarding() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('onboarding_done', true);
    } catch (e) {
      debugPrint('[OnboardingFeaturesScreen] Error saving onboarding state: $e');
    }
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/signup');
    }
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
    });
  }

  void _nextPage() {
    if (_currentPage < _features.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _completeOnboarding();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isLandscape = mediaQuery.orientation == Orientation.landscape;
    const primaryColor = Color(0xFF2DBD7F);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar: Skip Button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Align(
                alignment: Alignment.topRight,
                child: _currentPage < _features.length - 1
                    ? TextButton(
                        onPressed: _completeOnboarding,
                        style: TextButton.styleFrom(
                          foregroundColor: primaryColor,
                        ),
                        child: Text(
                          OnboardingStrings.skip,
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : const SizedBox(height: 48), // Empty space to keep layout alignment on last page
              ),
            ),

            // Swipeable Pages
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                itemCount: _features.length,
                itemBuilder: (context, index) {
                  return FeaturePage(model: _features[index]);
                },
              ),
            ),

            // Bottom Navigation Area
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
              child: isLandscape
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildDotIndicators(),
                        _buildActionButton(),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildDotIndicators(),
                        const SizedBox(height: 32),
                        _buildActionButton(),
                        const SizedBox(height: 8),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // Dot Indicators matching requirements
  Widget _buildDotIndicators() {
    const primaryColor = Color(0xFF2DBD7F);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        _features.length,
        (index) {
          final isSelected = index == _currentPage;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.symmetric(horizontal: 4.0),
            height: 8,
            width: isSelected ? 24 : 8,
            decoration: BoxDecoration(
              color: isSelected ? primaryColor : Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          );
        },
      ),
    );
  }

  // Next / Let's Go Action Button
  Widget _buildActionButton() {
    const primaryColor = Color(0xFF2DBD7F);
    final isLastPage = _currentPage == _features.length - 1;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: _nextPage,
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
          isLastPage ? OnboardingStrings.letsGo : OnboardingStrings.next,
          style: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
