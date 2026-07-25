import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingFeaturesScreen extends StatefulWidget {
  const OnboardingFeaturesScreen({super.key});

  @override
  State<OnboardingFeaturesScreen> createState() => _OnboardingFeaturesScreenState();
}

class _OnboardingFeaturesScreenState extends State<OnboardingFeaturesScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  static const int _pageCount = 3;
  static const Color _primary = Color(0xFF2DBE7F);

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
      debugPrint('[OnboardingFeaturesScreen] Error: $e');
    }
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/signup');
    }
  }

  void _nextPage() {
    if (_currentPage < _pageCount - 1) {
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
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Step counter
                  Text(
                    '${_currentPage + 1} / $_pageCount',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade400,
                    ),
                  ),
                  if (_currentPage < _pageCount - 1)
                    TextButton(
                      onPressed: _completeOnboarding,
                      style: TextButton.styleFrom(foregroundColor: _primary),
                      child: Text(
                        'Skip',
                        style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    )
                  else
                    const SizedBox(width: 64),
                ],
              ),
            ),

            // Swipeable pages
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: const [
                  _ChatFeaturePage(),
                  _BudgetFeaturePage(),
                  _ReportsFeaturePage(),
                ],
              ),
            ),

            // Bottom: dots + button
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _pageCount,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: i == _currentPage ? 24 : 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: i == _currentPage ? _primary : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _nextPage,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shadowColor: _primary.withValues(alpha: 0.3),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        _currentPage == _pageCount - 1 ? 'Get Started! 🚀' : 'Next →',
                        style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page 1: Chat to Track
// ─────────────────────────────────────────────────────────────────────────────

class _ChatFeaturePage extends StatelessWidget {
  const _ChatFeaturePage();

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF2DBE7F);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const SizedBox(height: 8),
          // Mock chat preview
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F7F9),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.07),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Chat header
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: primary.withValues(alpha: 0.15),
                      child: const Icon(Icons.smart_toy_outlined, color: primary, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'BachatBot',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    const Spacer(),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Color(0xFF4CAF50),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text('Online', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                  ],
                ),
                Divider(height: 20, color: Colors.grey.shade200),
                _chatBubble(isUser: true, text: 'Momo khayo 250 😋'),
                const SizedBox(height: 8),
                _chatBubble(
                  isUser: false,
                  text: '✓ Rs 250 Food ma save gareko!\nFood: Rs 2,250 / 5,000 (45%)',
                ),
                const SizedBox(height: 8),
                _chatBubble(isUser: true, text: 'Bus 40 gayo'),
                const SizedBox(height: 8),
                _chatBubble(isUser: false, text: '✓ Rs 40 Transport ma save bhayo!'),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Just chat, expenses tracked!',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1B5E20),
              height: 1.25,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Type naturally in any language — Nepali, Roman Nepali, or English. BachatBot understands and saves your expense instantly. No forms, no hassle.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 14, color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  static Widget _chatBubble({required bool isUser, required String text}) {
    const primary = Color(0xFF2DBE7F);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isUser ? primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 2),
            bottomRight: Radius.circular(isUser ? 2 : 14),
          ),
          boxShadow: [
            if (!isUser)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
          ],
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isUser ? Colors.white : Colors.black87,
            fontSize: 12,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page 2: Budget Alerts
// ─────────────────────────────────────────────────────────────────────────────

class _BudgetFeaturePage extends StatelessWidget {
  const _BudgetFeaturePage();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.07),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.grid_view_rounded, color: Color(0xFF2DBE7F), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'This Month\'s Budget',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _budgetRow(
                  emoji: '🍜',
                  label: 'Food',
                  spent: 2500,
                  limit: 5000,
                  color: const Color(0xFF2DBE7F),
                ),
                const SizedBox(height: 12),
                _budgetRow(
                  emoji: '🚌',
                  label: 'Transport',
                  spent: 800,
                  limit: 2000,
                  color: const Color(0xFF1B8B8E),
                ),
                const SizedBox(height: 12),
                _budgetRow(
                  emoji: '🛍',
                  label: 'Shopping',
                  spent: 3400,
                  limit: 3500,
                  color: const Color(0xFFFF6B35),
                  isWarning: true,
                ),
                const SizedBox(height: 16),
                // Alert chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFF9800).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFFF57C00), size: 15),
                      const SizedBox(width: 6),
                      Text(
                        'Shopping budget 97% full! ⚠️',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Set budgets, stress less!',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1B5E20),
              height: 1.25,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Set a monthly spending limit for each category. BachatBot alerts you before you overspend — stay in control, not in stress.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 14, color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  static Widget _budgetRow({
    required String emoji,
    required String label,
    required double spent,
    required double limit,
    required Color color,
    bool isWarning = false,
  }) {
    final pct = (spent / limit).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: Colors.black87),
              ),
            ),
            if (isWarning)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.warning_amber_rounded, color: Color(0xFFF57C00), size: 14),
              ),
            Text(
              'Rs ${spent.toInt()} / ${limit.toInt()}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            backgroundColor: Colors.grey.shade100,
            valueColor: AlwaysStoppedAnimation<Color>(
              isWarning ? const Color(0xFFFF6B35) : color,
            ),
            minHeight: 8,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page 3: Monthly Reports
// ─────────────────────────────────────────────────────────────────────────────

class _ReportsFeaturePage extends StatelessWidget {
  const _ReportsFeaturePage();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.07),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.insert_chart_outlined, color: Color(0xFF2DBE7F), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'This Month\'s Report',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _reportRow(
                  icon: Icons.arrow_downward_rounded,
                  color: const Color(0xFF2DBE7F),
                  label: 'Income received',
                  value: 'Rs 45,000',
                ),
                const SizedBox(height: 10),
                _reportRow(
                  icon: Icons.arrow_upward_rounded,
                  color: const Color(0xFFFF6B35),
                  label: 'Total spent',
                  value: 'Rs 28,500',
                ),
                const SizedBox(height: 10),
                _reportRow(
                  icon: Icons.savings_outlined,
                  color: const Color(0xFF1B8B8E),
                  label: 'Saved this month 🎉',
                  value: 'Rs 16,500',
                ),
                const SizedBox(height: 16),
                Divider(height: 1, color: Colors.grey.shade100),
                const SizedBox(height: 14),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.info_outline, size: 14, color: Colors.amber.shade800),
                      const SizedBox(width: 6),
                      Text(
                        'Spending Status: Medium 🟡',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'See where your money goes!',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1B5E20),
              height: 1.25,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Get a full monthly report — income earned, total expenses, and net savings. A clear Low / Medium / High spending status shows exactly how you\'re doing.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 14, color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  static Widget _reportRow({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
      ],
    );
  }
}
