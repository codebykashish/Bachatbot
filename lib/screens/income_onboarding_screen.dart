import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import 'category_budget_onboarding_screen.dart';
import 'main_screen.dart';

class IncomeOnboardingScreen extends StatefulWidget {
  final String firstName;
  const IncomeOnboardingScreen({super.key, required this.firstName});

  @override
  State<IncomeOnboardingScreen> createState() => _IncomeOnboardingScreenState();
}

class _IncomeOnboardingScreenState extends State<IncomeOnboardingScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  final _pageController = PageController();
  int _currentPage = 0;
  bool _isLoading = false;

  final _inHandController = TextEditingController();
  final _inBankController = TextEditingController();
  final _onlineBankingController = TextEditingController();

  double get _totalIncome {
    final a = double.tryParse(_inHandController.text) ?? 0;
    final b = double.tryParse(_inBankController.text) ?? 0;
    final c = double.tryParse(_onlineBankingController.text) ?? 0;
    return a + b + c;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _inHandController.dispose();
    _inBankController.dispose();
    _onlineBankingController.dispose();
    super.dispose();
  }

  void _goToInputPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
    setState(() => _currentPage = 1);
  }

  Future<void> _saveAndContinue() async {
    final inHand = double.tryParse(_inHandController.text) ?? 0;
    final inBank = double.tryParse(_inBankController.text) ?? 0;
    final online = double.tryParse(_onlineBankingController.text) ?? 0;

    if (inHand + inBank + online <= 0) {
      _navigateToCategories(0, 0, 0);
      return;
    }

    setState(() => _isLoading = true);
    try {
      await ApiService.post('/income', {
        'inHand': inHand,
        'inBank': inBank,
        'onlineBanking': online,
      });
      if (mounted) _navigateToCategories(inHand, inBank, online);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _navigateToCategories(double inHand, double inBank, double online) {
    final totalIncome = inHand + inBank + online;
    // The savings-goal step lives at the end of CategoryBudgetOnboarding-
    // Screen's own flow (its "savings intro" step) -- it used to also show
    // here, right after income, which meant the user saw it twice before
    // ever reaching category budgeting. Go straight there now.
    _goToCategoryBudgets(context, totalIncome);
  }

  void _goToCategoryBudgets(BuildContext ctx, double totalIncome) {
    Navigator.pushReplacement(
      ctx,
      MaterialPageRoute(
        builder: (_) => CategoryBudgetOnboardingScreen(
          firstName: widget.firstName,
          totalIncome: totalIncome,
        ),
      ),
    );
  }

  void _skipAll() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => MainScreen(firstName: widget.firstName, showTour: true)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar: progress dots + skip
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  ...List.generate(2, (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: i == _currentPage ? 22 : 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: i <= _currentPage ? _primary : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  )),
                  const Spacer(),
                  TextButton(
                    onPressed: _skipAll,
                    child: const Text('Skip', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildTrustPage(),
                  _buildIncomeInputPage(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Page 1: Trust / Privacy intro ────────────────────────────────────────

  Widget _buildTrustPage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_outline_rounded, size: 48, color: _primary),
          ),
          const SizedBox(height: 32),
          const Text(
            'Your money,\nyour privacy',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'BachatBot never shares your financial data. Your income details stay private — never sold, never shared.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey, height: 1.6),
          ),
          const SizedBox(height: 28),
          _trustPoint(Icons.security_outlined, 'Bank-level secure storage'),
          _trustPoint(Icons.visibility_off_outlined, 'Visible only to you'),
          _trustPoint(Icons.edit_outlined, 'Update it anytime'),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _goToInputPage,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text(
                "Let's Begin",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _trustPoint(IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: _primary),
          ),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 14, color: Colors.black87)),
        ],
      ),
    );
  }

  // ─── Page 2: Income sources input ─────────────────────────────────────────

  Widget _buildIncomeInputPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'How much do you\nhave right now?',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "Don't worry — you can change this anytime from your income page.",
            style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.5),
          ),
          const SizedBox(height: 32),

          _incomeField(
            controller: _inHandController,
            icon: Icons.wallet_outlined,
            label: 'Cash in Hand',
            hint: 'e.g. 2000',
            accent: const Color(0xFF2DBE7F),
          ),
          const SizedBox(height: 18),
          _incomeField(
            controller: _inBankController,
            icon: Icons.account_balance_outlined,
            label: 'In Bank Account',
            hint: 'e.g. 15000',
            accent: const Color(0xFF1B8B8E),
          ),
          const SizedBox(height: 18),
          _incomeField(
            controller: _onlineBankingController,
            icon: Icons.phone_android_outlined,
            label: 'Online Banking (eSewa / Khalti)',
            hint: 'e.g. 3000',
            accent: const Color(0xFF7E57C2),
          ),

          const SizedBox(height: 24),

          // Live total banner
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 250),
            crossFadeState: _totalIncome > 0
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calculate_outlined, color: _primary, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'Total: Rs ${_totalIncome.toInt()}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: _primary,
                    ),
                  ),
                ],
              ),
            ),
            secondChild: const SizedBox.shrink(),
          ),

          const SizedBox(height: 32),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _saveAndContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                    )
                  : const Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
          if (_totalIncome == 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TextButton(
                  onPressed: _skipAll,
                  child: const Text(
                    'Skip for now',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _incomeField({
    required TextEditingController controller,
    required IconData icon,
    required String label,
    required String hint,
    required Color accent,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(icon, size: 15, color: accent),
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(7),
          ],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: hint,
            prefixText: 'Rs  ',
            prefixStyle: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w500),
            filled: true,
            fillColor: Colors.grey.shade50,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
