import 'package:flutter/material.dart';
import '../api_service.dart';
import '../theme/health_theme.dart';
import 'goals_screen.dart';

/// "Your Week in Money" — Phase 22's dedicated screen, distinct from
/// Reports ("what is my data") and Health ("how am I doing right now").
/// Answers "what did I learn about my money this week." Reads the
/// already-composed reflection from GET /weekly-reflection -- no
/// calculation, no interpretation happens here, this screen only
/// renders backend-composed text with the app's existing HealthTheme
/// visual language.
class WeeklyReflectionScreen extends StatefulWidget {
  const WeeklyReflectionScreen({super.key});

  @override
  State<WeeklyReflectionScreen> createState() => _WeeklyReflectionScreenState();
}

class _WeeklyReflectionScreenState extends State<WeeklyReflectionScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  Map<String, dynamic>? _reflection;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _isLoading = true);
    try {
      final res = await ApiService.get('/weekly-reflection');
      if (!mounted) return;
      setState(() {
        _reflection = res['success'] == true ? (res['data'] as Map<String, dynamic>?) : null;
      });
    } catch (e) {
      debugPrint('[WeeklyReflectionScreen] fetch error: $e');
      if (mounted) setState(() => _reflection = null);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDateRange(String? weekStart, String? weekEnd) {
    if (weekStart == null || weekEnd == null) return '';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    DateTime? start, end;
    try {
      start = DateTime.parse(weekStart);
      end = DateTime.parse(weekEnd);
    } catch (_) {
      return '';
    }
    final startLabel = '${months[start.month - 1]} ${start.day}';
    final endLabel = start.month == end.month
        ? '${end.day}'
        : '${months[end.month - 1]} ${end.day}';
    return '$startLabel – $endLabel';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Your Week in Money', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              color: _primary,
              onRefresh: _fetch,
              child: _reflection == null ? _buildEmptyState() : _buildReflection(_reflection!),
            ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.auto_awesome_outlined, size: 56, color: Colors.grey.shade300),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            "No reflection yet",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            "Your first weekly reflection will show up once you've completed a full week on BachatBot.",
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildReflection(Map<String, dynamic> reflection) {
    final highlights = (reflection['highlights'] as List?) ?? [];
    final concerns = (reflection['concerns'] as List?) ?? [];
    final pattern = reflection['pattern'] as Map<String, dynamic>?;
    final goalContext = reflection['goalContext'] as Map<String, dynamic>?;
    final nextStep = reflection['nextStep'] as Map<String, dynamic>?;
    final greenTheme = HealthTheme.forStatus('green');
    final amberTheme = HealthTheme.forStatus('amber');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          _formatDateRange(reflection['weekStart'] as String?, reflection['weekEnd'] as String?),
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          (reflection['opening'] as String?) ?? '',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87, height: 1.3),
        ),
        const SizedBox(height: 24),

        if (highlights.isNotEmpty)
          _section(
            emoji: '✨',
            title: 'What went well',
            theme: greenTheme,
            items: highlights.map((h) => (h as Map<String, dynamic>)['text'] as String? ?? '').toList(),
          ),

        if (concerns.isNotEmpty)
          _section(
            emoji: '👀',
            title: 'Worth keeping an eye on',
            theme: amberTheme,
            items: concerns.map((c) => (c as Map<String, dynamic>)['text'] as String? ?? '').toList(),
          ),

        if (pattern != null)
          _section(
            emoji: '🔎',
            title: 'Something we noticed',
            theme: amberTheme,
            items: [pattern['text'] as String? ?? ''],
          ),

        if (goalContext != null)
          _section(
            emoji: '🎯',
            title: 'Your ${((goalContext['goalName'] as String?) ?? 'goal').isEmpty ? 'goal' : (goalContext['goalName'] as String).capitalizeFirst()} goal',
            theme: goalContext['type'] == 'GOAL_AT_RISK' ? amberTheme : greenTheme,
            items: [goalContext['text'] as String? ?? ''],
            trailingAction: TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GoalsScreen())),
              child: const Text('View Goal', style: TextStyle(color: _primary, fontWeight: FontWeight.w600)),
            ),
          ),

        if (nextStep != null)
          _section(
            emoji: '💡',
            title: 'Your next step',
            theme: greenTheme,
            items: [nextStep['text'] as String? ?? ''],
            filled: true,
          ),
      ],
    );
  }

  Widget _section({
    required String emoji,
    required String title,
    required HealthTheme theme,
    required List<String> items,
    Widget? trailingAction,
    bool filled = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: filled ? theme.cardTint : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: filled ? theme.accent.withValues(alpha: 0.3) : Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...items.where((t) => t.isNotEmpty).map((text) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(text, style: const TextStyle(fontSize: 13.5, color: Colors.black87, height: 1.4)),
              )),
          if (trailingAction != null) ...[
            const SizedBox(height: 4),
            Align(alignment: Alignment.centerLeft, child: trailingAction),
          ],
        ],
      ),
    );
  }
}

extension _StringCasing on String {
  String capitalizeFirst() => isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}
