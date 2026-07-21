import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../api_service.dart';
import '../services/behavior_preview_service.dart';
import '../widgets/hold_tooltip.dart';

/// Phase 13.3 — redesigned from a Duolingo-style reference, in our own
/// colors: a big streak hero, a real calendar of logged days (not just
/// a counter), a progress bar toward the next milestone, and short
/// copy everywhere — the fuller explanation lives in a press-and-hold
/// tooltip (HoldTooltip) instead of a permanent paragraph, since real
/// feedback was that the old version read as a wall of text.
///
/// Reads GET /behavior (summary/state/milestones) plus a direct,
/// read-only Firestore query against users/{uid}/transactions for the
/// displayed month, to know which specific days were logged — /behavior
/// only carries the current streak count, not which calendar days
/// built it.
class BehaviorScreen extends StatefulWidget {
  const BehaviorScreen({super.key});

  @override
  State<BehaviorScreen> createState() => _BehaviorScreenState();
}

class _BehaviorScreenState extends State<BehaviorScreen> {
  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _flame = Color(0xFFE67E22);

  static const List<int> _checkpoints = [7, 14, 30, 60, 90, 180, 365];

  static const Map<String, ({String emoji, String label, Color color})> _statusMeta = {
    'excellent': (emoji: '🌟', label: 'Excellent', color: Color(0xFF2DBE7F)),
    'good': (emoji: '🟢', label: 'Good', color: Color(0xFF2DBE7F)),
    'building': (emoji: '🟡', label: 'Building', color: Color(0xFFE67E22)),
    'needs_improvement': (emoji: '🔴', label: 'Needs Improvement', color: Color(0xFFE0223B)),
    'inactive': (emoji: '⚪', label: 'Just Getting Started', color: Color(0xFF8A8F98)),
  };

  static const Map<String, String> _statusTooltips = {
    'excellent': "You're logging, spending healthily, and saving — all at once. Keep doing exactly this.",
    'good': "At least one habit is going well right now. Keep it up.",
    'building': "You're still building your habits. Every logged expense helps.",
    'needs_improvement': "Spending or recovery has been rough lately. Check your categories below.",
    'inactive': "Welcome! Log a few expenses and this page will start filling in.",
  };

  bool _isLoading = true;
  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _state;
  List<dynamic> _milestones = [];

  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  Set<int> _loggedDays = {};
  bool _calendarLoading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
    _fetchCalendarMonth(_calendarMonth);
  }

  Future<void> _fetch() async {
    setState(() => _isLoading = true);
    try {
      final res = await ApiService.get('/behavior');
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          _summary = res['data']?['summary'] as Map<String, dynamic>?;
          _state = res['data']?['state'] as Map<String, dynamic>?;
          _milestones = res['data']?['milestones'] as List? ?? [];
        });
      }
    } catch (e) {
      debugPrint('[BehaviorScreen] /behavior error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
      BehaviorPreviewService.refresh();
    }
  }

  Future<void> _fetchCalendarMonth(DateTime month) async {
    setState(() => _calendarLoading = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _calendarLoading = false);
      return;
    }
    final monthKey = '${month.year}-${month.month.toString().padLeft(2, '0')}';
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .where('monthKey', isEqualTo: monthKey)
          .get();
      final days = <int>{};
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['isDeleted'] == true) continue;
        final createdAt = data['createdAt'];
        if (createdAt is Timestamp) days.add(createdAt.toDate().day);
      }
      if (mounted) setState(() => _loggedDays = days);
    } catch (e) {
      debugPrint('[BehaviorScreen] calendar fetch error: $e');
    } finally {
      if (mounted) setState(() => _calendarLoading = false);
    }
  }

  void _changeMonth(int delta) {
    final next = DateTime(_calendarMonth.year, _calendarMonth.month + delta);
    setState(() => _calendarMonth = next);
    _fetchCalendarMonth(next);
  }

  int get _loggingStreak => (_state?['logging']?['currentStreak'] as num?)?.toInt() ?? 0;
  int get _bestLoggingStreak => (_state?['logging']?['bestStreak'] as num?)?.toInt() ?? 0;

  int get _nextCheckpoint {
    for (final c in _checkpoints) {
      if (_loggingStreak < c) return c;
    }
    return _checkpoints.last;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: Colors.black87,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Streak', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              onRefresh: () async {
                await _fetch();
                await _fetchCalendarMonth(_calendarMonth);
              },
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _buildHero(),
                  const SizedBox(height: 20),
                  _buildStreakGoal(),
                  const SizedBox(height: 28),
                  const Text('Streak Calendar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  _buildCalendar(),
                  const SizedBox(height: 28),
                  _buildStatusCard(),
                  const SizedBox(height: 24),
                  const Text('Other Streaks', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  _buildOtherStreaks(),
                  const SizedBox(height: 24),
                  const Text('Milestones', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  _buildMilestones(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
    );
  }

  Widget _buildHero() {
    return Center(
      child: Column(
        children: [
          const Icon(Icons.local_fire_department, color: _flame, size: 84),
          Transform.translate(
            offset: const Offset(0, -18),
            child: Text(
              '$_loggingStreak',
              style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: Colors.black87),
            ),
          ),
          Text(
            'day streak!',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildStreakGoal() {
    final target = _nextCheckpoint;
    final progress = (_loggingStreak / target).clamp(0.0, 1.0);
    return HoldTooltip(
      message: 'Log at least one expense every day to keep this going. Miss a day and it resets to 1.',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F7F9),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Next goal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Text('$_loggingStreak / $target days', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 10,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation(_flame),
              ),
            ),
            const SizedBox(height: 6),
            Text('Best ever: $_bestLoggingStreak days', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendar() {
    final year = _calendarMonth.year;
    final month = _calendarMonth.month;
    final firstDay = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final leadingBlanks = firstDay.weekday % 7; // Sunday-first grid
    final now = DateTime.now();
    const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFF6F7F9), borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _changeMonth(-1)),
              Text('${monthNames[month - 1]} $year', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _changeMonth(1)),
            ],
          ),
          if (_calendarLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(color: _primary),
            )
          else
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final d in ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
                  Center(child: Text(d, style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.bold))),
                for (int i = 0; i < leadingBlanks; i++) const SizedBox.shrink(),
                for (int day = 1; day <= daysInMonth; day++)
                  _buildDayCell(day, isToday: year == now.year && month == now.month && day == now.day),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDayCell(int day, {required bool isToday}) {
    final logged = _loggedDays.contains(day);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Container(
        decoration: BoxDecoration(
          color: logged ? _flame : Colors.transparent,
          shape: BoxShape.circle,
          border: isToday ? Border.all(color: _primary, width: 2) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          '$day',
          style: TextStyle(
            fontSize: 12,
            fontWeight: logged || isToday ? FontWeight.bold : FontWeight.normal,
            color: logged ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final status = _summary?['status'] as String? ?? 'inactive';
    final meta = _statusMeta[status] ?? _statusMeta['inactive']!;
    final tooltip = _statusTooltips[status] ?? _statusTooltips['inactive']!;

    return HoldTooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: meta.color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Text(meta.emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(meta.label, style: TextStyle(fontWeight: FontWeight.bold, color: meta.color, fontSize: 15)),
            ),
            Icon(Icons.touch_app_outlined, color: Colors.grey.shade400, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildOtherStreaks() {
    final spending = _state?['spending'] as Map<String, dynamic>? ?? {};
    final saving = _state?['saving'] as Map<String, dynamic>? ?? {};
    final recovery = _state?['recovery'] as Map<String, dynamic>? ?? {};

    final rows = [
      (
        icon: Icons.favorite,
        color: _primary,
        label: 'Healthy spending',
        value: spending['currentHealthyStreak'] ?? 0,
        tooltip: "Stay within a healthy spending pace each day to grow this. One overspent day resets it.",
      ),
      (
        icon: Icons.savings,
        color: const Color(0xFF2B6CB0),
        label: 'Saving (months)',
        value: saving['currentProtectionStreak'] ?? 0,
        tooltip: "End a month having saved more than you spent to grow this. Checked once a month.",
      ),
      (
        icon: Icons.trending_up,
        color: Colors.grey.shade600,
        label: 'Recovery',
        value: recovery['currentStreak'] ?? 0,
        tooltip: "Counts recovery plans you finished successfully in a row, without one becoming impossible.",
      ),
    ];

    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade200)),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey.shade100),
            HoldTooltip(
              message: rows[i].tooltip,
              child: ListTile(
                leading: Icon(rows[i].icon, color: rows[i].color, size: 22),
                title: Text(rows[i].label, style: const TextStyle(fontSize: 14)),
                trailing: Text('${rows[i].value}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMilestones() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _milestones.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.15,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemBuilder: (context, index) {
        final m = _milestones[index] as Map<String, dynamic>;
        final unlocked = m['unlocked'] == true;
        final unlockedAt = m['unlockedAt'] as String?;
        final tooltip = unlocked
            ? '${m['description']}${unlockedAt != null ? " — unlocked $unlockedAt" : ""}'
            : 'Locked. ${m['description']}';

        return HoldTooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: unlocked ? Colors.white : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: unlocked ? _flame.withValues(alpha: 0.3) : Colors.grey.shade300),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  unlocked ? Icons.emoji_events : Icons.lock_outline,
                  color: unlocked ? _flame : Colors.grey.shade400,
                  size: 30,
                ),
                const SizedBox(height: 8),
                Text(
                  m['title'] as String? ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: unlocked ? Colors.black87 : Colors.grey.shade500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
