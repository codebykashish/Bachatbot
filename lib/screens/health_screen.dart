import 'package:flutter/material.dart';
import '../api_service.dart';
import '../widgets/hold_tooltip.dart';

/// Phase 13.4 — the dedicated Health screen, opened from Home's Health
/// badge (previously just a static, non-tappable line). Owns
/// everything Health/Recommendation/Recovery/Risk-related — moved out
/// of ReportsScreen so that screen stays focused on income/spending/
/// savings, and this one answers "am I okay, and what should I do."
///
/// Reads GET /financial-health, /financial-recommendations, and
/// /financial-metrics (for recoveryPlan only) — all three already
/// existed, computed fresh on request, never recomputed here.
class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _amber = Color(0xFFE67E22);
  static const Color _red = Color(0xFFE0223B);

  bool _isLoading = true;
  Map<String, dynamic>? _overallHealth;
  Map<String, dynamic> _categoryHealth = {};
  List<dynamic> _riskFlags = [];
  Map<String, dynamic>? _primaryRecommendation;
  Map<String, dynamic>? _recoveryPlan;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        ApiService.get('/financial-health'),
        ApiService.get('/financial-recommendations'),
        ApiService.get('/financial-metrics'),
      ]);
      final healthRes = results[0];
      final recRes = results[1];
      final metricsRes = results[2];
      if (!mounted) return;

      setState(() {
        _overallHealth = healthRes['success'] == true
            ? (healthRes['data']?['overallHealth'] as Map<String, dynamic>?)
            : null;
        _categoryHealth = healthRes['success'] == true
            ? (healthRes['data']?['categoryHealth'] as Map<String, dynamic>? ?? {})
            : {};
        _riskFlags = healthRes['success'] == true
            ? (healthRes['data']?['riskFlags'] as List? ?? [])
            : [];
        _primaryRecommendation = recRes['success'] == true
            ? (recRes['data']?['primaryRecommendation'] as Map<String, dynamic>?)
            : null;
        _recoveryPlan = metricsRes['success'] == true
            ? (metricsRes['data']?['recoveryPlan'] as Map<String, dynamic>?)
            : null;
      });
    } catch (e) {
      debugPrint('[HealthScreen] fetch error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Color/copy helpers ────────────────────────────────────────────────

  Color _statusColor(String? status) {
    switch (status) {
      case 'red':
        return _red;
      case 'amber':
        return _amber;
      default:
        return _primary;
    }
  }

  ({String emoji, String label}) _statusMeta(String? status) {
    switch (status) {
      case 'red':
        return (emoji: '🔴', label: 'Needs attention now');
      case 'amber':
        return (emoji: '🟡', label: 'Stable but needs attention');
      default:
        return (emoji: '🟢', label: 'Looking good');
    }
  }

  String _categoryTooltip(String? reasonCode) {
    switch (reasonCode) {
      case 'CATEGORY_EXHAUSTED':
        return "This category's budget is fully used up for the month.";
      case 'CATEGORY_HIGH_PRESSURE':
        return "Getting close to this category's limit — worth watching.";
      case 'CATEGORY_RECOVERABLE':
        return "Under some pressure, but still fixable this month.";
      case 'LOW_MATERIALITY':
        return "Not enough spending yet in this category to judge.";
      default:
        return "This category is in good shape.";
    }
  }

  String _recommendationMessage(Map<String, dynamic> rec) {
    final code = rec['code'] as String?;
    final category = rec['category'] as String?;
    final actionValue = rec['actionValue'];
    final actionUnit = rec['actionUnit'] as String?;
    final amount = (actionValue is num) ? actionValue.round() : null;
    final perDay = actionUnit == 'per_day' && amount != null ? 'Rs $amount/day' : null;

    switch (code) {
      case 'STOP_CATEGORY_SPENDING':
        return 'Your $category budget is used up — try to avoid more $category spending this month.';
      case 'REDUCE_CATEGORY_SPENDING':
        return perDay != null
            ? 'Try keeping $category spending around $perDay for the rest of the month.'
            : 'Try reducing $category spending for the rest of the month.';
      case 'MONITOR_CATEGORY_SPENDING':
        return 'Keep an eye on $category spending — it\'s trending toward pressure.';
      case 'LIMIT_DAILY_SPENDING':
        return perDay != null
            ? 'Try to spend no more than $perDay for the rest of the month.'
            : 'Try to limit your daily spending for the rest of the month.';
      case 'START_RECOVERY_PLAN':
        return 'Your savings are trending negative — worth reviewing your spending this week.';
      case 'ACCEPT_REDUCED_SAVINGS':
        return "Full recovery isn't possible this month — reducing spending now still helps.";
      case 'REVIEW_MULTIPLE_CATEGORIES':
        return "Several categories are under pressure — worth a full review.";
      case 'SLOW_SPENDING_PACE':
        return "You're spending faster than planned — slowing down this week will help.";
      case 'KEEP_CURRENT_HABITS':
      default:
        return "You're on track. Keep your current pace.";
    }
  }

  Color _recommendationColor(String? type) {
    switch (type) {
      case 'stop':
      case 'recover':
        return _red;
      case 'reduce':
        return _amber;
      case 'monitor':
        return Colors.amber.shade700;
      default:
        return _primary;
    }
  }

  Color _riskSeverityColor(String? severity) {
    switch (severity) {
      case 'critical':
        return const Color(0xFFB00020);
      case 'high':
        return _red;
      case 'medium':
        return _amber;
      case 'low':
        return Colors.amber.shade700;
      default:
        return Colors.grey.shade600;
    }
  }

  String _riskLabel(Map<String, dynamic> flag) {
    final code = (flag['code'] as String?) ?? '';
    final category = flag['category'] as String?;
    const labels = {
      'PROJECTED_DEFICIT': 'Your month is projected to end in a deficit',
      'RECOVERY_IMPOSSIBLE': "This month's overspend can no longer be fully recovered",
      'CATEGORY_EXHAUSTED': 'budget is fully used up',
      'RECOVERY_NEEDED': "You're behind pace — a recovery plan is active",
      'MULTIPLE_CATEGORIES_PRESSURED': 'Several categories are under pressure',
      'CATEGORY_HIGH_PRESSURE': 'is close to its limit',
      'SPENDING_TOO_FAST': "You're spending faster than planned",
      'CATEGORY_RECOVERABLE': 'needs some attention, but is fixable',
    };
    final label = labels[code] ?? code;
    return category != null && label.startsWith(RegExp('[a-z]')) ? '$category $label' : label;
  }

  @override
  Widget build(BuildContext context) {
    final status = _overallHealth?['status'] as String?;
    final meta = _statusMeta(status);
    final color = _statusColor(status);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: Colors.black87,
        title: const Text('Financial Health', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              onRefresh: _fetch,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _buildHero(meta, color),
                  const SizedBox(height: 24),
                  if (_primaryRecommendation != null) ...[
                    const Text('What To Do Next', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildRecommendationCard(),
                    const SizedBox(height: 24),
                  ],
                  if (_recoveryPlan != null) ...[
                    const Text('Recovery Plan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildRecoveryPlanCard(),
                    const SizedBox(height: 24),
                  ],
                  if (_categoryHealth.isNotEmpty) ...[
                    const Text('By Category', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildCategoryBreakdown(),
                    const SizedBox(height: 24),
                  ],
                  if (_riskFlags.isNotEmpty) ...[
                    const Text('Risks to Watch', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildRiskFlags(),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildHero(({String emoji, String label}) meta, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(meta.emoji, style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 10),
          Text(meta.label, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildRecommendationCard() {
    final rec = _primaryRecommendation!;
    final color = _recommendationColor(rec['type'] as String?);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.arrow_circle_right_outlined, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(_recommendationMessage(rec), style: const TextStyle(fontSize: 13.5, color: Colors.black87, height: 1.4)),
          ),
        ],
      ),
    );
  }

  Widget _buildRecoveryPlanCard() {
    final plan = _recoveryPlan!;
    final dailyTarget = (plan['dailyTarget'] as num?)?.toInt() ?? 0;
    final durationDays = (plan['durationDays'] as num?)?.toInt() ?? 0;
    final recoveryPossible = plan['recoveryPossible'] as bool? ?? true;
    final affected = (plan['affectedCategories'] as List?)?.cast<String>() ?? [];

    final message = recoveryPossible
        ? 'Try Rs $dailyTarget/day for the next $durationDays days to finish the month comfortably.'
        : "This month can't be fully recovered, but spending less now still helps.";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline, color: _amber, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: const TextStyle(fontSize: 13.5, color: Colors.black87, height: 1.4)),
                if (affected.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Watch: ${affected.join(', ')}', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBreakdown() {
    final entries = _categoryHealth.entries.toList();
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: entries.map((entry) {
        final health = entry.value as Map<String, dynamic>;
        final status = health['status'] as String?;
        final reasons = health['reasons'] as List? ?? [];
        final reasonCode = reasons.isNotEmpty ? (reasons[0] as Map)['code'] as String? : null;
        final color = _statusColor(status);

        return HoldTooltip(
          message: _categoryTooltip(reasonCode),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text(entry.key, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildRiskFlags() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          for (int i = 0; i < _riskFlags.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey.shade100),
            ListTile(
              leading: Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _riskSeverityColor((_riskFlags[i] as Map)['severity'] as String?),
                ),
              ),
              title: Text(_riskLabel(_riskFlags[i] as Map<String, dynamic>), style: const TextStyle(fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }
}
