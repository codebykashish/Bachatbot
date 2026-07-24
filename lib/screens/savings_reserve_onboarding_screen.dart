import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import 'category_budget_onboarding_screen.dart';
import 'main_screen.dart';

class SavingsReserveOnboardingScreen extends StatefulWidget {
  final String firstName;
  final double totalIncome;

  const SavingsReserveOnboardingScreen({
    super.key,
    required this.firstName,
    required this.totalIncome,
  });

  @override
  State<SavingsReserveOnboardingScreen> createState() =>
      _SavingsReserveOnboardingScreenState();
}

class _SavingsReserveOnboardingScreenState
    extends State<SavingsReserveOnboardingScreen> {
  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _bg = Color(0xFFF6F7F9);

  // 'none' | '5' | '10' | '15' | 'custom'
  String _selected = 'none';
  final _customController = TextEditingController();
  bool _showCustom = false;
  bool _isLoading = false;

  double get _reserveAmount {
    if (_selected == 'custom') {
      return double.tryParse(_customController.text) ?? 0;
    }
    final pct = double.tryParse(_selected) ?? 0;
    return (widget.totalIncome * pct / 100).roundToDouble();
  }

  double get _availableForBudgeting =>
      (widget.totalIncome - _reserveAmount).clamp(0, double.infinity);

  void _pick(String value) {
    setState(() {
      _selected = value;
      _showCustom = value == 'custom';
    });
  }

  Future<void> _continue() async {
    // Skip: no reserve, go straight to categories
    if (_selected == 'none') {
      _goToCategories(0, 0);
      return;
    }

    final amount = _reserveAmount;
    if (_selected == 'custom' && amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid reserve amount.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (amount > widget.totalIncome) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reserve cannot exceed your total income.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final pct = widget.totalIncome > 0
          ? double.parse((amount / widget.totalIncome * 100).toStringAsFixed(1))
          : 0.0;
      await ApiService.post('/savings-reserve', {
        'amount': amount,
        'percentage': pct,
      });
      if (mounted) _goToCategories(amount, pct);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save reserve: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _goToCategories(double reserveAmount, double pct) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => CategoryBudgetOnboardingScreen(
          firstName: widget.firstName,
          totalIncome: widget.totalIncome,
          savingsReserve: reserveAmount,
        ),
      ),
    );
  }

  void _skipAll() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
          builder: (_) =>
              MainScreen(firstName: widget.firstName, showTour: true)),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                  ),
                  Row(
                    children: List.generate(
                      4,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: i == 1 ? 22 : 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: i <= 1 ? _primary : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _skipAll,
                    child: const Text('Skip',
                        style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ───────────────────────────────────────────
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: _primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.savings_outlined,
                          size: 30, color: _primary),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Reserve money\nfor savings?',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This amount will be protected every month before budgets are set.',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600, height: 1.5),
                    ),
                    const SizedBox(height: 28),

                    // ── Income line ──────────────────────────────────────
                    _incomeLine(),
                    const SizedBox(height: 24),

                    // ── Option chips ─────────────────────────────────────
                    Text('How much would you like to reserve?',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _chip('5', '5%',
                            subtitle: 'Rs ${(widget.totalIncome * 0.05).toInt()}'),
                        _chip('10', '10%',
                            subtitle: 'Rs ${(widget.totalIncome * 0.10).toInt()}'),
                        _chip('15', '15%',
                            subtitle: 'Rs ${(widget.totalIncome * 0.15).toInt()}'),
                        _chip('custom', 'Custom amount'),
                        _chip('none', 'Skip for now', isSkip: true),
                      ],
                    ),

                    // ── Custom input ─────────────────────────────────────
                    if (_showCustom) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _customController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(7),
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          prefixText: 'Rs  ',
                          hintText: 'Enter amount',
                          prefixStyle: const TextStyle(
                              color: Colors.black54, fontWeight: FontWeight.w500),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 13),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                BorderSide(color: Colors.grey.shade200),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                BorderSide(color: Colors.grey.shade200),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: _primary, width: 1.5),
                          ),
                        ),
                      ),
                    ],

                    // ── Allocation preview banner ─────────────────────────
                    if (_selected != 'none' && _reserveAmount > 0) ...[
                      const SizedBox(height: 24),
                      _allocationPreview(),
                    ],

                    const SizedBox(height: 32),

                    // ── Continue button ───────────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _continue,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2.5),
                              )
                            : Text(
                                _selected == 'none' ? 'Skip' : 'Continue',
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _incomeLine() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_balance_wallet_outlined,
              size: 18, color: _primary),
          const SizedBox(width: 10),
          Text(
            'Your income: Rs ${widget.totalIncome.toInt()}',
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87),
          ),
        ],
      ),
    );
  }

  Widget _chip(String value, String label,
      {String? subtitle, bool isSkip = false}) {
    final isSelected = _selected == value;
    return GestureDetector(
      onTap: () => _pick(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? (isSkip ? Colors.grey.shade100 : _primary)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? (isSkip ? Colors.grey.shade400 : _primary)
                : Colors.grey.shade200,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isSelected
                    ? (isSkip ? Colors.grey.shade700 : Colors.white)
                    : Colors.black87,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected ? Colors.white70 : Colors.grey.shade500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _allocationPreview() {
    final reserve = _reserveAmount;
    final budget = _availableForBudgeting;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_primary.withValues(alpha: 0.08), _primary.withValues(alpha: 0.03)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your monthly allocation',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600)),
          const SizedBox(height: 12),
          _allocationRow(
            Icons.savings_outlined,
            'Savings Reserve',
            'Rs ${reserve.toInt()}',
            _primary,
          ),
          const SizedBox(height: 8),
          _allocationRow(
            Icons.donut_large_outlined,
            'Available for Budgets',
            'Rs ${budget.toInt()}',
            const Color(0xFF1B8B8E),
          ),
        ],
      ),
    );
  }

  Widget _allocationRow(IconData icon, String label, String value, Color color) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label,
                style:
                    const TextStyle(fontSize: 13, color: Colors.black87))),
        Text(
          value,
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }
}
