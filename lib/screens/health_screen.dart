import 'package:flutter/material.dart';
import '../api_service.dart';
import '../theme/health_theme.dart';
import '../widgets/hold_tooltip.dart';

/// Phase 13.11 — refined onto the shared HealthTheme (this screen
/// predates that class, from Phase 13.4, and had its own separate
/// color logic until now — the same "one signal, one place" fix
/// already applied to the ambient overlay, Categories, and Reports).
///
/// The screen that answers, in order: what's my health, why am I here,
/// what's causing it, what should I do, how do I recover. Owns
/// everything Health/Recommendation/Recovery/Risk-related.
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

  // ── Copy helpers — plain-English mappings over already-computed codes,
  // never a new judgment. Color always comes from HealthTheme now, never
  // a locally-redefined value. ─────────────────────────────────────────

  ({String emoji, String label}) _statusMeta(String? status) {
    switch (status) {
      case 'red':
        return (emoji: '🔴', label: 'Needs your attention');
      case 'amber':
        return (emoji: '🟡', label: 'Stable, but worth a look');
      default:
        return (emoji: '🟢', label: "You're in good shape");
    }
  }

  // The hero's "why am I here" line -- primaryReason is already the
  // single most important true fact (Health Engine's own priority
  // order), just given a plain sentence instead of a raw code.
  String _overallReasonSentence(String? status, String? code) {
    switch (code) {
      case 'PROJECTED_DEFICIT':
        return "You're on track to spend more than you earn this month.";
      case 'RECOVERY_IMPOSSIBLE':
        return "This month's overspending can no longer be fully fixed.";
      case 'RECOVERY_NEEDED':
        return "You're behind pace, but a recovery plan is already helping.";
      case 'MULTIPLE_CATEGORIES_PRESSURED':
        return "A few categories are close to their limit at once.";
      case 'CATEGORY_HIGH_PRESSURE':
        return "One category is close to its limit.";
      case 'SPENDING_TOO_FAST':
        return "You're spending faster than planned this month.";
      default:
        return status == 'red' || status == 'amber'
            ? "Something needs a closer look this month."
            : "Nothing needs your attention right now.";
    }
  }

  String _categoryStatusLabel(String? status) {
    switch (status) {
      case 'red':
        return 'Over budget';
      case 'amber':
        return 'Near limit';
      default:
        return 'On track';
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

  ({String headline, String detail}) _recommendationCopy(Map<String, dynamic> rec) {
    final code = rec['code'] as String?;
    final category = rec['category'] as String?;
    final actionValue = rec['actionValue'];
    final actionUnit = rec['actionUnit'] as String?;
    final amount = (actionValue is num) ? actionValue.round() : null;
    final perDay = actionUnit == 'per_day' && amount != null ? 'Rs $amount/day' : null;

    switch (code) {
      case 'STOP_CATEGORY_SPENDING':
        return (
          headline: 'Your $category budget is used up',
          detail: 'Try to avoid more $category spending this month.',
        );
      case 'REDUCE_CATEGORY_SPENDING':
        return (
          headline: 'Ease up on $category',
          detail: perDay != null
              ? 'Try keeping it around $perDay for the rest of the month.'
              : 'Try spending less on it for the rest of the month.',
        );
      case 'MONITOR_CATEGORY_SPENDING':
        return (headline: 'Keep an eye on $category', detail: "It's trending toward pressure.");
      case 'LIMIT_DAILY_SPENDING':
        return (
          headline: 'Slow your daily spending',
          detail: perDay != null ? 'Try to stay under $perDay a day.' : 'Try to spend a bit less each day.',
        );
      case 'START_RECOVERY_PLAN':
        return (headline: 'Your savings need a boost', detail: 'Worth reviewing your spending this week.');
      case 'ACCEPT_REDUCED_SAVINGS':
        return (headline: "Full recovery isn't possible", detail: 'Spending less now still helps.');
      case 'REVIEW_MULTIPLE_CATEGORIES':
        return (headline: 'A few categories need attention', detail: 'Worth a full review.');
      case 'SLOW_SPENDING_PACE':
        return (headline: "You're spending faster than planned", detail: 'Slowing down this week will help.');
      case 'KEEP_CURRENT_HABITS':
      default:
        return (headline: "You're on track", detail: 'Keep your current pace.');
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
    final theme = HealthTheme.forStatus(status);
    final meta = _statusMeta(status);
    final primaryReason = _overallHealth?['primaryReason'] as Map<String, dynamic>?;

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
                  _buildHero(meta, theme, _overallReasonSentence(status, primaryReason?['code'] as String?)),
                  const SizedBox(height: 24),
                  if (_categoryHealth.isNotEmpty) ...[
                    const Text("What's affecting it", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildCategoryBreakdown(),
                    const SizedBox(height: 24),
                  ],
                  if (_primaryRecommendation != null) ...[
                    const Text('What to do next', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildRecommendationCard(),
                    const SizedBox(height: 24),
                  ],
                  if (_recoveryPlan != null) ...[
                    const Text('How to recover', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildRecoveryPlanCard(),
                    const SizedBox(height: 24),
                  ],
                  if (_riskFlags.isNotEmpty) ...[
                    const Text('Risks to watch', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildRiskFlags(),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildHero(({String emoji, String label}) meta, HealthTheme theme, String reason) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: theme.cardTint,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Text(meta.emoji, style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 10),
          Text(meta.label, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: theme.statusColor)),
          const SizedBox(height: 6),
          Text(
            reason,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendationCard() {
    final rec = _primaryRecommendation!;
    final theme = HealthTheme.forStatus(_overallHealth?['status'] as String?);
    final copy = _recommendationCopy(rec);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.arrow_circle_right_outlined, color: theme.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(copy.headline, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: theme.statusColor)),
                const SizedBox(height: 3),
                Text(copy.detail, style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.4)),
              ],
            ),
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
    final theme = HealthTheme.forStatus('amber');

    final message = recoveryPossible
        ? 'Try Rs $dailyTarget/day for the next $durationDays days to finish the month comfortably.'
        : "This month can't be fully recovered, but spending less now still helps.";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, color: theme.accent, size: 22),
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

  // Real list with an always-visible status label (not color-only,
  // not hidden behind a hold), plus a hold-tooltip for the fuller
  // "why" -- color/label/tooltip together, per the frozen "color is
  // never the only signal" principle.
  Widget _buildCategoryBreakdown() {
    final entries = _categoryHealth.entries.toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          for (int i = 0; i < entries.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey.shade100),
            Builder(builder: (context) {
              final entry = entries[i];
              final health = entry.value as Map<String, dynamic>;
              final status = health['status'] as String?;
              final reasons = health['reasons'] as List? ?? [];
              final reasonCode = reasons.isNotEmpty ? (reasons[0] as Map)['code'] as String? : null;
              final theme = HealthTheme.forStatus(status);

              return HoldTooltip(
                message: _categoryTooltip(reasonCode),
                child: ListTile(
                  leading: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
                  ),
                  title: Text(entry.key, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  trailing: Text(
                    _categoryStatusLabel(status),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: theme.statusColor),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
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
                  color: HealthTheme.forStatus(
                    (_riskFlags[i] as Map)['severity'] == 'critical' || (_riskFlags[i] as Map)['severity'] == 'high'
                        ? 'red'
                        : 'amber',
                  ).accent,
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
