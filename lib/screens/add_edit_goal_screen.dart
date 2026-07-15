import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/goal.dart';

/// Reusable create/edit form for a savings goal — used both as a normal
/// pushed screen (editing an existing goal from the Goals list) and as an
/// optional onboarding step (showSkip: true, onSkip/onDone wired to move
/// onboarding forward either way).
class AddEditGoalScreen extends StatefulWidget {
  final Goal? existingGoal;
  final bool showSkip;
  // Takes this screen's own BuildContext — the caller that constructed this
  // widget may already be disposed (e.g. replaced via pushReplacement) by
  // the time the user acts, so navigating with ITS context would crash.
  final void Function(BuildContext context)? onSkip;
  final void Function(BuildContext context)? onDone;

  const AddEditGoalScreen({
    super.key,
    this.existingGoal,
    this.showSkip = false,
    this.onSkip,
    this.onDone,
  });

  @override
  State<AddEditGoalScreen> createState() => _AddEditGoalScreenState();
}

class _AddEditGoalScreenState extends State<AddEditGoalScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  int _timeframeMonths = 3;

  bool _isSaving = false;

  bool get _isEditing => widget.existingGoal != null;

  double get _monthlyTarget {
    final amount = double.tryParse(_amountController.text) ?? 0;
    if (_timeframeMonths <= 0) return 0;
    return amount / _timeframeMonths;
  }

  @override
  void initState() {
    super.initState();
    final g = widget.existingGoal;
    if (g != null) {
      _nameController.text = g.name;
      _amountController.text = g.targetAmount.toInt().toString();
      _timeframeMonths = g.timeframeMonths;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final amount = double.tryParse(_amountController.text.trim());

    if (name.isEmpty) {
      _showError('Give your goal a name.');
      return;
    }
    if (amount == null || amount <= 0) {
      _showError('Enter a valid amount.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      if (_isEditing) {
        await ApiService.patch('/goals/${widget.existingGoal!.id}', {
          'name': name,
          'targetAmount': amount,
          'timeframeMonths': _timeframeMonths,
        });
      } else {
        await ApiService.post('/goals', {
          'name': name,
          'targetAmount': amount,
          'timeframeMonths': _timeframeMonths,
        });
      }

      if (!mounted) return;
      if (widget.onDone != null) {
        widget.onDone!(context);
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      _showError('Could not save goal: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Goal' : 'New Savings Goal',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
        automaticallyImplyLeading: !widget.showSkip,
        actions: [
          if (widget.showSkip)
            TextButton(
              onPressed: widget.onSkip == null ? null : () => widget.onSkip!(context),
              child: const Text('Skip for now', style: TextStyle(color: Colors.grey, fontSize: 13)),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showSkip) ...[
              const Text(
                'Want to save toward something?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Could be a specific item, or just a savings target. Totally optional.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 20),
            ],

            _label('WHAT ARE YOU SAVING FOR?'),
            TextField(
              controller: _nameController,
              decoration: _inputDecoration('e.g. New phone, Trip to Pokhara, Emergency fund'),
            ),
            const SizedBox(height: 20),

            _label('HOW MUCH DOES IT COST?'),
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: _inputDecoration('e.g. 6000').copyWith(prefixText: 'Rs '),
            ),
            const SizedBox(height: 20),

            _label('HOW LONG TO SAVE IT?'),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _timeframeMonths.toDouble(),
                    min: 1,
                    max: 24,
                    divisions: 23,
                    activeColor: _primary,
                    label: '$_timeframeMonths mo',
                    onChanged: (v) => setState(() => _timeframeMonths = v.round()),
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '$_timeframeMonths mo',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (_monthlyTarget > 0)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _primary.withValues(alpha: 0.25)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.savings_outlined, color: _primary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'That\'s about Rs ${_monthlyTarget.toStringAsFixed(0)}/month to hit your goal.',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _primary),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : Text(_isEditing ? 'Save Changes' : 'Add Goal',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black54, letterSpacing: 0.4),
        ),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.all(14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade200)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade200)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _primary, width: 1.5)),
      );
}
