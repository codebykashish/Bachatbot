import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../main.dart';
import '../widgets/alert_banner.dart';

class _PendingCategoryAlerts {
  Map<String, dynamic>? expense;
  Map<String, dynamic>? rebalance;
  Timer? timer;
}

/// Watches users/{uid}/alerts in real time and, for alerts that matter
/// (budget threshold crossed, budget rebalanced/transferred), shows one
/// short, urgent on-screen banner AND fires a real Android notification.
///
/// A single overspend transaction can produce TWO Firestore alert docs
/// (an "expense" threshold alert + a "budget_rebalanced" transfer alert)
/// almost simultaneously. Both are buffered per-category for a short
/// window and merged into a single popup so the user sees one clean
/// alert instead of two overlapping ones.
///
/// Purely a display layer — does not read, write, or recompute any
/// budget/alert business logic. That all still lives in the backend.
/// Both underlying alert docs are left untouched in Firestore/Activity.
class AlertPopupService {
  static final AlertPopupService _instance = AlertPopupService._internal();

  factory AlertPopupService() => _instance;

  AlertPopupService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<QuerySnapshot>? _sub;
  bool _initialized = false;
  int _notifId = 1000;

  final Map<String, _PendingCategoryAlerts> _pendingByCategory = {};

  static const _mergeWindow = Duration(milliseconds: 700);
  static const _red = Color(0xFFE0223B);
  static const _orange = Color(0xFFE67E22);
  static const _blue = Color(0xFF2B6CB0);

  Future<void> init(String uid) async {
    if (_initialized) return;
    _initialized = true;

    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      ),
    );

    // Only react to alerts created from this moment onward — avoid
    // replaying the user's entire alert history every time the app opens.
    final startTime = Timestamp.now();

    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .where('createdAt', isGreaterThan: startTime)
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        _bufferAlert(change.doc.data());
      }
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    for (final p in _pendingByCategory.values) {
      p.timer?.cancel();
    }
    _pendingByCategory.clear();
    _initialized = false;
  }

  void _bufferAlert(Map<String, dynamic>? data) {
    if (data == null) return;

    final type = data['type'] as String? ?? '';
    final severity = data['severity'] as String? ?? 'low';
    final message = data['message'] as String? ?? '';
    if (message.isEmpty) return;

    // Standalone alert — not paired with anything else, so skip the
    // merge-buffer entirely and emit immediately.
    if (type == 'pending_transaction') {
      _emitPendingTransaction(data);
      return;
    }

    final isUrgent = severity == 'medium' ||
        severity == 'high' ||
        type == 'budget_rebalanced';
    if (!isUrgent) return;

    final category = data['category'] as String? ?? 'Budget';
    final pending = _pendingByCategory.putIfAbsent(
      category,
      () => _PendingCategoryAlerts(),
    );

    if (type == 'budget_rebalanced') {
      pending.rebalance = data;
    } else {
      pending.expense = data;
    }

    // Restart the merge window each time a related alert arrives for the
    // same category, so both parts of the same event land together.
    pending.timer?.cancel();
    pending.timer = Timer(_mergeWindow, () => _flush(category));
  }

  void _flush(String category) {
    final pending = _pendingByCategory.remove(category);
    if (pending == null) return;

    if (pending.rebalance != null) {
      _emitRebalanced(category, pending.rebalance!, pending.expense);
    } else if (pending.expense != null) {
      _emitExpenseOnly(category, pending.expense!);
    }
  }

  int _daysLeftInMonth() {
    final now = DateTime.now();
    final firstOfNextMonth = DateTime(now.year, now.month + 1, 1);
    return firstOfNextMonth.difference(DateTime(now.year, now.month, now.day)).inDays;
  }

  String? _extractPercent(String message) {
    return RegExp(r'(\d+)%').firstMatch(message)?.group(1);
  }

  void _emitPendingTransaction(Map<String, dynamic> data) {
    final message = data['message'] as String? ?? 'A transaction was detected. Tap to categorize.';

    _emit(
      title: '🔔 Transaction Detected',
      message: message,
      color: _blue,
      icon: Icons.receipt_long_rounded,
    );
  }

  void _emitExpenseOnly(String category, Map<String, dynamic> expense) {
    final message = expense['message'] as String? ?? '';
    final percent = _extractPercent(message);
    final daysLeft = _daysLeftInMonth();

    final short = percent != null
        ? '$category: $percent% of budget used. $daysLeft days left this month.'
        : '$category budget almost used up. $daysLeft days left this month.';

    _emit(
      title: '🚨 Budget Alert',
      message: short,
      color: _red,
      icon: Icons.warning_amber_rounded,
    );
  }

  void _emitRebalanced(
    String category,
    Map<String, dynamic> rebalance,
    Map<String, dynamic>? expense,
  ) {
    final rMsg = rebalance['message'] as String? ?? '';
    final overspend =
        RegExp(r'exceeded by Rs\s?([\d,]+)').firstMatch(rMsg)?.group(1);
    final sources = RegExp(r'Auto-adjusted:\s*(.+?)\s*transferred')
        .firstMatch(rMsg)
        ?.group(1);
    final percent = expense != null
        ? _extractPercent(expense['message'] as String? ?? '')
        : null;
    final daysLeft = _daysLeftInMonth();

    final buffer = StringBuffer('$category is over budget');
    if (percent != null) buffer.write(' ($percent% used)');
    if (overspend != null) buffer.write(' by Rs $overspend');
    buffer.write('.');
    if (sources != null) buffer.write(' $sources moved to cover it.');
    buffer.write(' $daysLeft days left this month.');

    _emit(
      title: '⚠️ Budget Adjusted',
      message: buffer.toString(),
      color: _orange,
      icon: Icons.swap_horiz_rounded,
    );
  }

  // The in-app full-width banner (_showBanner) was deliberately dropped —
  // real usage showed it as a redundant "double" of the system push
  // below, which already reliably reaches the user (even backgrounded)
  // without needing an on-screen overlay too. In its place: a center
  // pop-up the user must actually acknowledge (tap "Got it") — real
  // feedback was that a system push alone is too easy to swipe away
  // without registering "I'm overspending." _showBanner/AlertBanner are
  // left in place, unused, rather than deleted — reversible if this
  // needs revisiting.
  void _emit({
    required String title,
    required String message,
    required Color color,
    required IconData icon,
  }) {
    _showSystemNotification(title: title, message: message, color: color);
    _enqueueCenterAlert(title: title, message: message, color: color, icon: icon);
  }

  final List<Map<String, dynamic>> _centerAlertQueue = [];
  bool _isShowingCenterAlert = false;

  // Queued, not fired immediately — two budget alerts landing within
  // the same second (a common case: expense + rebalance) must show one
  // at a time, never stacked dialogs fighting for the same screen.
  void _enqueueCenterAlert({
    required String title,
    required String message,
    required Color color,
    required IconData icon,
  }) {
    _centerAlertQueue.add({'title': title, 'message': message, 'color': color, 'icon': icon});
    _processCenterAlertQueue();
  }

  Future<void> _processCenterAlertQueue() async {
    if (_isShowingCenterAlert || _centerAlertQueue.isEmpty) return;
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;

    _isShowingCenterAlert = true;
    final next = _centerAlertQueue.removeAt(0);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: (next['color'] as Color).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(next['icon'] as IconData, color: next['color'] as Color, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              next['title'] as String,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: Colors.black87),
            ),
            const SizedBox(height: 8),
            Text(
              next['message'] as String,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.4),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actionsPadding: const EdgeInsets.only(bottom: 16),
        actions: [
          SizedBox(
            width: 160,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: next['color'] as Color,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );

    _isShowingCenterAlert = false;
    _processCenterAlertQueue();
  }

  void _showBanner({
    required String title,
    required String message,
    required Color color,
    required IconData icon,
  }) {
    final overlayState = rootNavigatorKey.currentState?.overlay;
    if (overlayState == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Material(
          color: Colors.transparent,
          child: AlertBanner(
            title: title,
            message: message,
            color: color,
            icon: icon,
            onDismiss: () {
              if (entry.mounted) entry.remove();
            },
          ),
        ),
      ),
    );

    overlayState.insert(entry);
  }

  Future<void> _showSystemNotification({
    required String title,
    required String message,
    required Color color,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'budget_alerts',
      'Budget Alerts',
      channelDescription: 'Urgent budget threshold and transfer alerts',
      importance: Importance.max,
      priority: Priority.high,
      color: color,
    );

    await _notifications.show(
      _notifId++,
      title,
      message,
      NotificationDetails(android: androidDetails),
    );
  }
}
