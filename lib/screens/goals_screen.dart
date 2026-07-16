import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/goal.dart';
import '../widgets/goal_pie_chart.dart';
import 'add_edit_goal_screen.dart';

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  List<Goal> _goals = [];
  double _availableToSave = 0;

  @override
  void initState() {
    super.initState();
    _fetchGoals();
  }

  Future<void> _fetchGoals() async {
    setState(() => _isLoading = true);
    try {
      final res = await ApiService.get('/goals');
      if (!mounted) return;
      if (res['success'] == true) {
        final list = (res['data']?['goals'] as List? ?? [])
            .map((g) => Goal.fromJson(g as Map<String, dynamic>))
            .toList();
        setState(() {
          _goals = list;
          _availableToSave = (res['data']?['availableToSave'] ?? 0).toDouble();
        });
      }
    } catch (e) {
      debugPrint('[GoalsScreen] fetch error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addGoal() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AddEditGoalScreen()),
    );
    if (saved == true) _fetchGoals();
  }

  Future<void> _editGoal(Goal goal) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AddEditGoalScreen(existingGoal: goal)),
    );
    if (saved == true) _fetchGoals();
  }

  List<Goal> get _sortedGoals => [..._goals]..sort((a, b) => a.priority.compareTo(b.priority));

  Future<void> _changePriority(Goal goal, int delta) async {
    final newPriority = (goal.priority + delta).clamp(1, 10);
    if (newPriority == goal.priority) return;
    try {
      await ApiService.patch('/goals/${goal.id}', {'priority': newPriority});
      _fetchGoals();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not change priority: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _deleteGoal(Goal goal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Remove "${goal.name}"?'),
        content: const Text('This will delete the goal and its progress.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ApiService.delete('/goals/${goal.id}');
      _fetchGoals();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _showGoalDetail(Goal goal) {
    int localPriority = goal.priority;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
        padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.of(ctx).viewInsets.bottom),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(goal.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            GoalPieChart(saved: goal.savedSoFar, remaining: goal.remaining, size: 170),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _legendItem('Saved', 'Rs ${goal.savedSoFar.toInt()}', const Color(0xFF2DBE7F)),
                _legendItem('Remaining', 'Rs ${goal.remaining.toInt()}', const Color(0xFFE0E4E8)),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF6F7F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      localPriority == 1
                          ? 'Top priority — funded first'
                          : 'Priority $localPriority — funded after lower numbers',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    onPressed: localPriority <= 1
                        ? null
                        : () async {
                            setSheetState(() => localPriority--);
                            await _changePriority(goal, -1);
                          },
                    icon: const Icon(Icons.remove_circle_outline),
                    color: _primary,
                    visualDensity: VisualDensity.compact,
                  ),
                  SizedBox(
                    width: 20,
                    child: Text('$localPriority', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    onPressed: localPriority >= 10
                        ? null
                        : () async {
                            setSheetState(() => localPriority++);
                            await _changePriority(goal, 1);
                          },
                    icon: const Icon(Icons.add_circle_outline),
                    color: _primary,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Same number as another goal = grow side by side. Lower number = funded first.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 8),
            Text('Target: Rs ${goal.targetAmount.toInt()}', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            Text(
              'Rs ${goal.monthlyTarget.toStringAsFixed(0)}/month over ${goal.timeframeMonths} months',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 12),
            Text(
              'This grows automatically from your unused income — add more income to save faster.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400, fontStyle: FontStyle.italic),
            ),
          ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _legendItem(String label, String value, Color color) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Goals', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addGoal,
        backgroundColor: _primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: RefreshIndicator(
        color: _primary,
        onRefresh: _fetchGoals,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: _primary))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                children: [
                  _currentSavingsCard(),
                  if (_goals.length > 1) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 13, color: Colors.grey.shade400),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            'Same priority number = goals grow side by side. Lower number is funded first.',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_goals.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Column(
                        children: [
                          Icon(Icons.flag_outlined, size: 48, color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          Text(
                            'No goal set yet',
                            style: TextStyle(fontSize: 15, color: Colors.grey.shade500, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Your savings are growing on their own. Tap + to give\nsome of it a purpose, like a laptop or a trip.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade400),
                          ),
                        ],
                      ),
                    )
                  else
                    ..._sortedGoals.map(_goalCard),
                ],
              ),
      ),
    );
  }

  // The Savings Pool always exists, independent of whether the user has
  // named a goal for it — goals are just an optional label on part of it.
  Widget _currentSavingsCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_primary, _primary.withValues(alpha: 0.75)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: _primary.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.savings_outlined, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              const Text('Current Savings', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Rs ${_availableToSave.toInt()}',
            style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            _goals.isEmpty
                ? 'General savings — no goal attached yet'
                : 'Shared across ${_goals.length} goal${_goals.length == 1 ? '' : 's'} below',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _goalCard(Goal goal) {
    final isCompleted = goal.status == 'completed';
    final progress = (goal.percentComplete / 100).clamp(0.0, 1.0);

    return GestureDetector(
      onTap: () => _showGoalDetail(goal),
      child: Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.savings_outlined, color: _primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            goal.name,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isCompleted)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: _primary, borderRadius: BorderRadius.circular(6)),
                            child: const Text('DONE', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
                          ),
                      ],
                    ),
                    Text(
                      'Rs ${goal.savedSoFar.toInt()} / Rs ${goal.targetAmount.toInt()}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: Colors.grey.shade500, size: 20),
                onSelected: (v) {
                  if (v == 'edit') _editGoal(goal);
                  if (v == 'delete') _deleteGoal(goal);
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Priority ${goal.priority}',
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _primary),
                ),
              ),
              if (!isCompleted && goal.savedSoFar == 0 && _goals.any((g) => g.priority < goal.priority)) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Waiting on a higher-priority goal',
                    style: TextStyle(fontSize: 10.5, color: Colors.grey.shade400, fontStyle: FontStyle.italic),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
              color: isCompleted ? _primary : _primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${goal.percentComplete.toStringAsFixed(0)}% · Rs ${goal.monthlyTarget.toStringAsFixed(0)}/mo · ${goal.timeframeMonths} mo',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
      ),
    );
  }
}
