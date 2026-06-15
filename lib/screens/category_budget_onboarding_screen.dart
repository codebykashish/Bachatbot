import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import 'main_screen.dart';

class CategoryBudgetOnboardingScreen extends StatefulWidget {
  final String firstName;
  final double totalIncome;

  const CategoryBudgetOnboardingScreen({
    super.key,
    required this.firstName,
    required this.totalIncome,
  });

  @override
  State<CategoryBudgetOnboardingScreen> createState() =>
      _CategoryBudgetOnboardingScreenState();
}

class _CategoryBudgetOnboardingScreenState
    extends State<CategoryBudgetOnboardingScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  static const List<Map<String, dynamic>> _allCategories = [
    {'name': 'Food',          'icon': Icons.restaurant,        'color': Color(0xFFFF7043)},
    {'name': 'Transport',     'icon': Icons.directions_car,    'color': Color(0xFF42A5F5)},
    {'name': 'Rent',          'icon': Icons.home,              'color': Color(0xFF26A69A)},
    {'name': 'Education',     'icon': Icons.school,            'color': Color(0xFF7E57C2)},
    {'name': 'Shopping',      'icon': Icons.shopping_bag,      'color': Color(0xFFAB47BC)},
    {'name': 'Health',        'icon': Icons.favorite,          'color': Color(0xFFEF5350)},
    {'name': 'Entertainment', 'icon': Icons.tv,                'color': Color(0xFF8D6E63)},
    {'name': 'Other',         'icon': Icons.category,          'color': Color(0xFFFFCA28)},
  ];

  // Step 0 = category selection, Step 1 = budget setting
  int _step = 0;
  bool _isSaving = false;

  // Which categories the user selected
  final Set<String> _selected = {};

  // Budget amounts per category (only for selected categories)
  final Map<String, TextEditingController> _budgetControllers = {};

  double get _totalBudgeted {
    double sum = 0;
    for (final name in _selected) {
      sum += double.tryParse(_budgetControllers[name]?.text ?? '') ?? 0;
    }
    return sum;
  }

  double get _remaining => widget.totalIncome - _totalBudgeted;

  @override
  void dispose() {
    for (final c in _budgetControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _toggleCategory(String name) {
    setState(() {
      if (_selected.contains(name)) {
        _selected.remove(name);
        _budgetControllers[name]?.dispose();
        _budgetControllers.remove(name);
      } else {
        _selected.add(name);
        _budgetControllers[name] = TextEditingController();
      }
    });
  }

  void _proceedToBudgets() {
    if (_selected.isEmpty) {
      _finishOnboarding();
      return;
    }
    setState(() => _step = 1);
  }

  Future<void> _finishOnboarding() async {
    setState(() => _isSaving = true);
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';

      // Save budgets for selected categories
      for (final name in _selected) {
        final amount = double.tryParse(_budgetControllers[name]?.text ?? '') ?? 0;
        if (amount > 0) {
          await ApiService.post('/budgets', {
            'category': name,
            'limit': amount,
            'monthKey': monthKey,
          });
        }
      }

      // Mark onboarding as complete
      await ApiService.patch('/profile', {
        'onboarding': {'isCompleted': true},
      });

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => MainScreen(
            firstName: widget.firstName,
            showTour: true,
          ),
        ),
        (route) => false,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save budgets: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _skipAll() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => MainScreen(
          firstName: widget.firstName,
          showTour: true,
        ),
      ),
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
            // Header bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  if (_step == 1)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                      onPressed: () => setState(() => _step = 0),
                      padding: EdgeInsets.zero,
                    ),
                  // Progress indicator (step 2 of 2 in budget flow, step 3 of full onboarding)
                  Row(
                    children: List.generate(2, (i) => AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: i == _step ? 22 : 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: i <= _step ? _primary : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    )),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _skipAll,
                    child: const Text('Skip', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _step == 0 ? _buildCategorySelector() : _buildBudgetSetter(),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Step 0: Category selection grid ─────────────────────────────────────

  Widget _buildCategorySelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Where do you\nspend money?',
            style: TextStyle(
              fontSize: 26, fontWeight: FontWeight.bold,
              color: Colors.black87, height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Select the categories you regularly spend on.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 24),

          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.9,
              ),
              itemCount: _allCategories.length,
              itemBuilder: (ctx, i) {
                final cat = _allCategories[i];
                final name = cat['name'] as String;
                final color = cat['color'] as Color;
                final icon = cat['icon'] as IconData;
                final selected = _selected.contains(name);
                return GestureDetector(
                  onTap: () => _toggleCategory(name),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    decoration: BoxDecoration(
                      color: selected ? color.withValues(alpha: 0.12) : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected ? color : Colors.grey.shade200,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(
                            color: selected ? color.withValues(alpha: 0.2) : color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(icon, color: color, size: 22),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: selected ? color : Colors.black87,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (selected)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Icon(Icons.check_circle, size: 14, color: _primary),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _proceedToBudgets,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  _selected.isEmpty ? 'Skip for now' : 'Set Budgets  →',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Step 1: Budget allocation ────────────────────────────────────────────

  Widget _buildBudgetSetter() {
    final remaining = _remaining;
    final isOverAllocated = widget.totalIncome > 0 && remaining < 0;

    return Column(
      children: [
        // Remaining balance banner
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isOverAllocated
                ? Colors.red.shade50
                : _primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isOverAllocated
                  ? Colors.red.shade200
                  : _primary.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Icon(
                isOverAllocated ? Icons.warning_amber_rounded : Icons.savings_outlined,
                color: isOverAllocated ? Colors.red : _primary,
                size: 22,
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.totalIncome > 0
                        ? 'Rs ${remaining.abs().toInt()} ${isOverAllocated ? 'over limit' : 'remaining'}'
                        : 'Set budgets for each category',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: isOverAllocated ? Colors.red : _primary,
                    ),
                  ),
                  if (widget.totalIncome > 0)
                    Text(
                      'from Rs ${widget.totalIncome.toInt()} total income',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Set a monthly budget for each category',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            children: _selected.map((name) {
              final meta = _allCategories.firstWhere((c) => c['name'] == name);
              final color = meta['color'] as Color;
              final icon = meta['icon'] as IconData;
              return _budgetRow(name, icon, color, _budgetControllers[name]!);
            }).toList(),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            children: [
              if (isOverAllocated)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'No more balance left. Reduce a budget or skip.',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade600),
                    textAlign: TextAlign.center,
                  ),
                ),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _finishOnboarding,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _isSaving
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                      : const Text('Done, Open App  🎉', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _budgetRow(String name, IconData icon, Color color, TextEditingController ctrl) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              controller: ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(7),
              ],
              onChanged: (_) => setState(() {}),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                prefixText: 'Rs ',
                prefixStyle: const TextStyle(fontSize: 12, color: Colors.black54),
                hintText: '0',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _primary, width: 1.5),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
