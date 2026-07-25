import 'package:flutter/material.dart';
import '../api_service.dart';
import 'income_onboarding_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final String firstName;
  const OnboardingScreen({super.key, required this.firstName,});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _monthlySpendController = TextEditingController();

  String _occupation = 'student';
  String _housingType = 'rent';
  bool _isLoading = false;

  final List<Map<String, dynamic>> _occupationOptions = [
    {
      'value': 'student',
      'label': 'Student',
      'icon': Icons.school_outlined,
    },
    {
      'value': 'employed',
      'label': 'Employed',
      'icon': Icons.work_outlined,
    },
    {
      'value': 'business',
      'label': 'Business',
      'icon': Icons.store_outlined,
    },
  ];

  final List<Map<String, dynamic>> _housingOptions = [
    {
      'value': 'rent',
      'label': 'Renting',
      'icon': Icons.home_outlined,
      'subtitle': 'I pay monthly rent',
    },
    {
      'value': 'own',
      'label': 'Own Home',
      'icon': Icons.house_outlined,
      'subtitle': 'I own my home',
    },
  ];

  @override
  void dispose() {
    _monthlySpendController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final spendText = _monthlySpendController.text.trim();
      final estimatedSpend =
          spendText.isNotEmpty ? double.tryParse(spendText) ?? 0.0 : 0.0;

      await ApiService.patch('/profile', {
        'onboarding': {
          'isCompleted': false,
          'occupation': _occupation,
          'housingType': _housingType,
          'estimatedMonthlySpend': estimatedSpend,
        }
      });

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => IncomeOnboardingScreen(firstName: widget.firstName),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save: $e'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),

                // Header
                const Icon(
                  Icons.waving_hand,
                  size: 48,
                  color: Color(0xFF2E7D32),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Let's set you up!",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2E7D32),
                  ),
                ),
                const Text(
                  'Tell us a bit about yourself so BachatBot\ncan give you better insights.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 36),

                // --- Occupation ---
                _sectionLabel('What do you do?'),
                const SizedBox(height: 12),
                ...(_occupationOptions.map((option) {
                  final isSelected = _occupation == option['value'];
                  return _buildSelectCard(
                    icon: option['icon'] as IconData,
                    label: option['label'] as String,
                    isSelected: isSelected,
                    onTap: () =>
                        setState(() => _occupation = option['value'] as String),
                  );
                })),
                const SizedBox(height: 28),

                // --- Housing ---
                _sectionLabel('Where do you live?'),
                const SizedBox(height: 12),
                ...(_housingOptions.map((option) {
                  final isSelected = _housingType == option['value'];
                  return _buildSelectCard(
                    icon: option['icon'] as IconData,
                    label: option['label'] as String,
                    subtitle: option['subtitle'] as String,
                    isSelected: isSelected,
                    onTap: () => setState(
                        () => _housingType = option['value'] as String),
                  );
                })),
                const SizedBox(height: 28),

                // --- Monthly Spend ---
                _sectionLabel('Estimated monthly spending (Rs)'),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _monthlySpendController,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Monthly Spend',
                    prefixIcon: Icon(Icons.currency_rupee),
                    hintText: 'e.g. 15000',
                    helperText: 'How much do you usually spend per month?',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter your estimated monthly spending';
                    }
                    final parsed = double.tryParse(value.trim());
                    if (parsed == null || parsed <= 0) {
                      return 'Please enter a valid amount';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 36),

                // Save Button
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _save,
                    icon: _isLoading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.arrow_forward),
                    label: Text(_isLoading ? 'Saving...' : "Let's Go!"),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Colors.black87,
      ),
    );
  }

  Widget _buildSelectCard({
    required IconData icon,
    required String label,
    String? subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF2E7D32).withValues(alpha: 0.08)
              : Colors.grey.shade50,
          border: Border.all(
            color: isSelected ? const Color(0xFF2E7D32) : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFF2E7D32) : Colors.grey,
              size: 26,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color:
                          isSelected ? const Color(0xFF2E7D32) : Colors.black87,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle,
                color: Color(0xFF2E7D32),
                size: 22,
              ),
          ],
        ),
      ),
    );
  }
}