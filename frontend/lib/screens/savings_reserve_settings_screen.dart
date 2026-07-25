import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import 'categories_screen.dart';

class SavingsReserveSettingsScreen extends StatefulWidget {
  const SavingsReserveSettingsScreen({super.key});

  @override
  State<SavingsReserveSettingsScreen> createState() =>
      _SavingsReserveSettingsScreenState();
}

class _SavingsReserveSettingsScreenState
    extends State<SavingsReserveSettingsScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  bool _isSaving = false;

  // Current values from API
  double _income = 0;
  double _currentReserve = 0;
  double _currentPct = 0;
  double _currentBudgetTotal = 0;
  double _unallocated = 0;

  // Selection state
  String _selected = 'custom'; // '5' | '10' | '15' | 'custom' | 'none'
  final _customController = TextEditingController();

  double get _newReserveAmount {
    if (_selected == 'none') return 0;
    if (_selected == 'custom') {
      return double.tryParse(_customController.text) ?? 0;
    }
    final pct = double.tryParse(_selected) ?? 0;
    return (_income * pct / 100).roundToDouble();
  }

  double get _availableForBudgeting =>
      (_income - _newReserveAmount).clamp(0, double.infinity);

  bool get _requiresBudgetAdjustment =>
      _currentBudgetTotal > _availableForBudgeting &&
      _newReserveAmount > _currentReserve;

  double get _budgetShortfall =>
      (_currentBudgetTotal - _availableForBudgeting).clamp(0, double.infinity);

  @override
  void initState() {
    super.initState();
    _loadCurrentReserve();
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentReserve() async {
    try {
      final res = await ApiService.get('/savings-reserve');
      if (!mounted) return;
      if (res['success'] == true) {
        final data = res['data'] as Map<String, dynamic>;
        final current = (data['reserveAmount'] as num?)?.toDouble() ?? 0;
        final pct = (data['reservePercentage'] as num?)?.toDouble() ?? 0;
        final income = (data['income'] as num?)?.toDouble() ?? 0;
        final budgetTotal =
            (data['budgetImpact']?['currentBudgetTotal'] as num?)?.toDouble() ?? 0;
        final unalloc =
            (data['budgetImpact']?['unallocated'] as num?)?.toDouble() ?? 0;
        setState(() {
          _income = income;
          _currentReserve = current;
          _currentPct = pct;
          _currentBudgetTotal = budgetTotal;
          _unallocated = unalloc;
          // Pre-fill the custom field with current value
          _customController.text = current > 0 ? current.toInt().toString() : '';
          // Pre-select closest tier or custom
          if (current == 0) {
            _selected = 'none';
          } else {
            final nearPct = _income > 0 ? (current / _income * 100) : 0;
            if ((nearPct - 5).abs() < 0.5) {
              _selected = '5';
            } else if ((nearPct - 10).abs() < 0.5) {
              _selected = '10';
            } else if ((nearPct - 15).abs() < 0.5) {
              _selected = '15';
            } else {
              _selected = 'custom';
            }
          }
        });
      }
    } catch (e) {
      debugPrint('[SavingsReserveSettings] load error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _save() async {
    final amount = _newReserveAmount;

    if (_selected == 'custom' && amount <= 0 && _selected != 'none') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid amount.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // ── Case A vs Case B ─────────────────────────────────────────────
    // unallocated = income - total category budgets already set
    final unallocated = (_income - _currentBudgetTotal).clamp(0.0, double.infinity);

    if (_requiresBudgetAdjustment && unallocated < amount - _currentReserve) {
      // Case B: reserve needs money from ALREADY-ALLOCATED budgets — must clear
      final proceed = await _showClearBudgetsDialog();
      if (proceed != true || !mounted) return;
      await _saveReserveAndClearBudgets(amount);
    } else {
      // Case A: reserve fits in unallocated room — save silently
      await _saveReserveQuietly(amount);
    }
  }

  Future<void> _saveReserveQuietly(double amount) async {
    setState(() => _isSaving = true);
    try {
      final pct = _income > 0
          ? double.parse((amount / _income * 100).toStringAsFixed(1))
          : 0.0;
      await ApiService.post('/savings-reserve', {
        'amount': amount,
        'percentage': pct,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(amount > 0
                ? 'Savings reserve set to Rs ${amount.toInt()}/month.'
                : 'Savings reserve removed.'),
            backgroundColor: _primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e'), backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveReserveAndClearBudgets(double amount) async {
    setState(() => _isSaving = true);
    try {
      final pct = _income > 0
          ? double.parse((amount / _income * 100).toStringAsFixed(1))
          : 0.0;
      // 1. Save the reserve
      await ApiService.post('/savings-reserve', {
        'amount': amount,
        'percentage': pct,
      });
      // 2. Clear all category budgets for this month
      await ApiService.delete('/budgets/clear-month');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Reserve set. Budgets cleared — reallocate from Rs ${((_income - amount)).toInt()} available.'),
            backgroundColor: _primary,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
        // Navigate to Categories screen so user can reallocate
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => const CategoriesScreen(showAppBar: true),
          ),
          (route) => route.isFirst,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<bool?> _showClearBudgetsDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Budgets will be reset'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Setting a reserve of Rs ${_newReserveAmount.toInt()}/month leaves only '
              'Rs ${(_income - _newReserveAmount).toInt()} for category budgets — '
              'Rs ${_budgetShortfall.toInt()} less than what you\'ve already allocated.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'All your current category budgets will be cleared. '
                      'You will be taken to the Budgets screen to reallocate.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade600,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear & Reallocate'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showBudgetImpactDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Budget adjustment needed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Increasing your reserve to Rs ${_newReserveAmount.toInt()} will leave '
              'Rs ${_budgetShortfall.toInt()} short for your current category budgets.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            _impactRow('Current reserve', 'Rs ${_currentReserve.toInt()}', Colors.grey),
            _impactRow('New reserve', 'Rs ${_newReserveAmount.toInt()}', _primary),
            _impactRow('Available for budgets', 'Rs ${_availableForBudgeting.toInt()}',
                _requiresBudgetAdjustment ? Colors.red : _primary),
            _impactRow('Current budget total', 'Rs ${_currentBudgetTotal.toInt()}', Colors.black87),
            if (_budgetShortfall > 0)
              _impactRow('Shortfall', 'Rs ${_budgetShortfall.toInt()}', Colors.red),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _primary, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm anyway'),
          ),
        ],
      ),
    );
  }

  Widget _impactRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600))),
          Text(value,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: valueColor)),
        ],
      ),
    );
  }

  void _pick(String value) {
    setState(() {
      _selected = value;
      if (value != 'custom' && value != 'none') {
        final pct = double.tryParse(value) ?? 0;
        _customController.text =
            (_income * pct / 100).toInt().toString();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Savings Reserve',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Current reserve info ────────────────────────────
                  if (_currentReserve > 0)
                    _infoCard(
                      '💰 Current Reserve',
                      'Rs ${_currentReserve.toInt()}/month  '
                      '(${_currentPct.toStringAsFixed(0)}% of income)',
                      _primary.withValues(alpha: 0.08),
                    )
                  else
                    _infoCard(
                      '💰 No reserve set',
                      'You are not currently protecting any savings.',
                      Colors.grey.shade50,
                    ),
                  const SizedBox(height: 24),

                  // ── Income line ─────────────────────────────────────
                  Text('Monthly Income: Rs ${_income.toInt()}',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 16),

                  // ── Option chips ─────────────────────────────────────
                  Text('Choose your reserve:',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _chip('5', '5%',
                          subtitle: 'Rs ${(_income * 0.05).toInt()}'),
                      _chip('10', '10%',
                          subtitle: 'Rs ${(_income * 0.10).toInt()}'),
                      _chip('15', '15%',
                          subtitle: 'Rs ${(_income * 0.15).toInt()}'),
                      _chip('custom', 'Custom'),
                      _chip('none', 'Remove reserve', isSkip: true),
                    ],
                  ),

                  // ── Custom input ─────────────────────────────────────
                  const SizedBox(height: 16),
                  TextField(
                    controller: _customController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(7),
                    ],
                    onChanged: (_) => setState(() => _selected = 'custom'),
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
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: _primary, width: 1.5),
                      ),
                    ),
                  ),

                  // ── Impact preview ───────────────────────────────────
                  if (_selected != 'none' && _newReserveAmount > 0) ...[
                    const SizedBox(height: 20),
                    _impactPreview(),
                  ],

                  const SizedBox(height: 32),

                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2.5),
                            )
                          : Text(
                              _selected == 'none'
                                  ? 'Remove Reserve'
                                  : 'Save Reserve',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _infoCard(String title, String subtitle, Color bg) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
          const SizedBox(height: 3),
          Text(subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
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

  Widget _impactPreview() {
    final reserve = _newReserveAmount;
    final budget = _availableForBudgeting;
    final needsAdjust = _requiresBudgetAdjustment;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: needsAdjust
            ? Colors.orange.shade50
            : _primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: needsAdjust
              ? Colors.orange.shade200
              : _primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            needsAdjust
                ? '⚠️ Budget adjustment needed'
                : '✅ Your new allocation',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: needsAdjust ? Colors.orange.shade700 : _primary),
          ),
          const SizedBox(height: 12),
          _impactRow('Savings Reserve', 'Rs ${reserve.toInt()}', _primary),
          _impactRow('Available for Budgets', 'Rs ${budget.toInt()}',
              needsAdjust ? Colors.red : Colors.black87),
          if (needsAdjust) ...[
            const Divider(height: 16),
            _impactRow(
                'Current budget total', 'Rs ${_currentBudgetTotal.toInt()}', Colors.black87),
            _impactRow('Shortfall', 'Rs ${_budgetShortfall.toInt()}', Colors.red),
            const SizedBox(height: 6),
            Text(
              'Your category budgets will need to be reduced by Rs ${_budgetShortfall.toInt()}.',
              style: TextStyle(fontSize: 11.5, color: Colors.orange.shade700),
            ),
          ],
        ],
      ),
    );
  }
}
