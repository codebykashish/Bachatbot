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
        setState(() => _goals = list);
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
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
            : _goals.isEmpty
                ? ListView(
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.6,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.savings_outlined, size: 64, color: Colors.grey.shade300),
                            const SizedBox(height: 12),
                            Text('No goals yet', style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
                            const SizedBox(height: 4),
                            Text(
                              'Tap + to save toward something.',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                    itemCount: _goals.length,
                    itemBuilder: (context, i) => _goalCard(_goals[i]),
                  ),
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
          const SizedBox(height: 12),
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
