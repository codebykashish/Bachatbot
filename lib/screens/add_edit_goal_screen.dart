import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../models/goal.dart';
import '../widgets/goal_pie_chart.dart';

/// Reusable create/edit form for a savings goal — used both as a normal
/// pushed screen (editing an existing goal from the Goals list) and as
/// the optional final step of onboarding (showSkip: true, onSkip/onDone
/// wired to move onboarding forward either way).
///
/// A two-step flow: "what are you saving for" (name + quick-pick chips),
/// then "how much / how long / priority" with a live summary and a
/// donut chart -- same shape as the reference goal-setting flow, adapted
/// to this app's own model (priority, no interest-rate concept).
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

  static const List<String> _quickPicks = [
    'Vacation', 'Education', 'Travelling', 'Renovation', 'Emergency Fund',
    'Retirement', 'Wedding', 'Fitness Goals', 'Debt Freedom',
    'Child Education', 'Holiday Gifts', 'Personal Development',
  ];

  final _pageController = PageController();
  int _page = 0;

  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  int _timeframeMonths = 3;
  int _priority = 1;

  bool _isSaving = false;

  bool get _isEditing => widget.existingGoal != null;

  double get _amount => double.tryParse(_amountController.text) ?? 0;

  double get _monthlyTarget {
    if (_timeframeMonths <= 0) return 0;
    return _amount / _timeframeMonths;
  }

  DateTime get _targetDate {
    final now = DateTime.now();
    return DateTime(now.year, now.month + _timeframeMonths, now.day);
  }

  @override
  void initState() {
    super.initState();
    final g = widget.existingGoal;
    if (g != null) {
      _nameController.text = g.name;
      _amountController.text = g.targetAmount.toInt().toString();
      _timeframeMonths = g.timeframeMonths;
      _priority = g.priority;
      // Editing an existing goal — skip straight to the amount/timeframe
      // step; the quick-pick name screen is only useful when starting fresh.
      _page = 1;
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _goToDetails() {
    if (_nameController.text.trim().isEmpty) {
      _showError('Give your goal a name.');
      return;
    }
    setState(() => _page = 1);
    _pageController.animateToPage(1, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
  }

  void _backToName() {
    setState(() => _page = 0);
    _pageController.animateToPage(0, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final amount = _amount;

    if (name.isEmpty) {
      _showError('Give your goal a name.');
      return;
    }
    if (amount <= 0) {
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
          'priority': _priority,
        });
      } else {
        await ApiService.post('/goals', {
          'name': name,
          'targetAmount': amount,
          'timeframeMonths': _timeframeMonths,
          'priority': _priority,
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
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 20, 0),
              child: Row(
                children: [
                  if (_page == 1 && !_isEditing)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                      onPressed: _backToName,
                    )
                  else if (!widget.showSkip)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    )
                  else
                    const SizedBox(width: 8),
                  if (!_isEditing)
                    Row(
                      children: List.generate(2, (i) => AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            width: i == _page ? 22 : 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              color: i <= _page ? _primary : Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          )),
                    ),
                  const Spacer(),
                  if (widget.showSkip)
                    TextButton(
                      onPressed: widget.onSkip == null ? null : () => widget.onSkip!(context),
                      child: const Text('Skip for now', style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildNameStep(),
                  _buildDetailsStep(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Step 0: "What are you saving for?" ───────────────────────────────

  Widget _buildNameStep() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('What are you\nsaving for?',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.black87, height: 1.25)),
          const SizedBox(height: 6),
          Text('Give it a name, or pick a quick idea below.', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          const SizedBox(height: 24),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: 'e.g. Trip to Pokhara',
              hintStyle: TextStyle(fontSize: 15, color: Colors.grey.shade400, fontWeight: FontWeight.normal),
              filled: true,
              fillColor: const Color(0xFFF6F7F9),
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _primary, width: 1.5)),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 10,
                children: _quickPicks.map((label) {
                  final selected = _nameController.text.trim().toLowerCase() == label.toLowerCase();
                  return GestureDetector(
                    onTap: () => setState(() => _nameController.text = label),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: selected ? _primary.withValues(alpha: 0.12) : const Color(0xFFF6F7F9),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: selected ? _primary : Colors.grey.shade200),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? _primary : Colors.black87),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _goToDetails,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Continue  →', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Step 1: amount, timeframe, priority, live summary ─────────────────

  Widget _buildDetailsStep() {
    final remaining = (_amount - 0).clamp(0.0, double.infinity); // new goal — nothing saved yet
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How much do you\nwant to save?',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.black87, height: 1.25)),
          const SizedBox(height: 4),
          Text(_nameController.text.trim().isEmpty ? 'For your goal' : 'For "${_nameController.text.trim()}"',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          const SizedBox(height: 20),

          // The big editable number -- this IS the amount input.
          Center(
            child: IntrinsicWidth(
              child: TextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: _primary),
                decoration: const InputDecoration(
                  prefixText: 'Rs ',
                  prefixStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _primary),
                  hintText: '0',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Center(child: Divider(height: 1, indent: 60, endIndent: 60)),
          const SizedBox(height: 24),

          _label('WHEN DO YOU WANT TO REACH YOUR GOAL?'),
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
                child: Text('$_timeframeMonths mo', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 12),

          _label('WHICH GOAL DO YOU WANT FUNDED FIRST?'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F7F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _priority == 1
                        ? 'Top priority — funded before lower-priority goals'
                        : 'Priority $_priority — funded after higher-priority goals',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: _priority <= 1 ? null : () => setState(() => _priority--),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: _primary,
                  visualDensity: VisualDensity.compact,
                ),
                SizedBox(width: 20, child: Text('$_priority', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(
                  onPressed: _priority >= 10 ? null : () => setState(() => _priority++),
                  icon: const Icon(Icons.add_circle_outline),
                  color: _primary,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Summary: donut + the two numbers that actually matter here
          // (no "interest rate" — this app doesn't project one).
          if (_amount > 0)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  GoalPieChart(saved: 0, remaining: remaining, size: 84),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _summaryRow('Monthly target', 'Rs ${_monthlyTarget.toStringAsFixed(0)}'),
                        const SizedBox(height: 8),
                        _summaryRow('Reach goal by', DateFormat('MMM d, yyyy').format(_targetDate)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isSaving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _isSaving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(_isEditing ? 'Save Changes' : 'Add Goal', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87)),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black54, letterSpacing: 0.4)),
      );
}
