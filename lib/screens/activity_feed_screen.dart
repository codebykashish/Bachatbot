import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../services/activity_feed_service.dart';
import '../widgets/chat_fab.dart';
import '../widgets/categorize_transaction_dialog.dart';
import 'category_detail_page.dart';
import 'income_page.dart';

/// Phase 13.2b (redesigned per real usage feedback) — the single unified
/// "everything the system told you" feed, merging two collections that
/// used to sit behind two separate screens:
///
///  - users/{uid}/alerts — the legacy system. Every transaction already
///    creates a low-severity entry here (routes/chat.py's "Rs X <cat>
///    expense saved" alerts), alongside budget-threshold alerts and
///    pending-transaction confirmations.
///  - users/{uid}/generatedNotifications — the new Notification Engine
///    (Phase 5), reserved for things worth interrupting attention for.
///
/// Both live-listened by ActivityFeedService (a persistent, app-lifetime
/// singleton). Visual design deliberately calm (Facebook-style): white
/// rows by default, a light tinted background + small dot for unread
/// items only, reverting to plain white once read — never a saturated
/// red/orange card, which real feedback flagged as feeling alarming
/// for routine activity.
class ActivityFeedScreen extends StatefulWidget {
  /// Deep-link filters — mirrors the old NotificationScreen's
  /// initialType/initialDateRange, for the several cards elsewhere in
  /// the app ("This Month Expense", "My Income" bell, "Today's
  /// activity") that used to open that screen pre-filtered.
  /// [initialFilter]: 'transactions' | 'alerts' | 'notifications' | null (all)
  /// [initialDateFilter]: 'today' | 'yesterday' | 'week' | 'month' | null (all time)
  final String? initialFilter;
  final String? initialDateFilter;

  const ActivityFeedScreen({super.key, this.initialFilter, this.initialDateFilter});

  @override
  State<ActivityFeedScreen> createState() => _ActivityFeedScreenState();
}

enum _TypeFilter { all, transactions, alerts, notifications }

const _transactionAlertTypes = {'expense', 'income'};

class _ActivityFeedScreenState extends State<ActivityFeedScreen> {
  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _unreadTint = Color(0xFFEAF7F0);

  static const Map<String, Color> _priorityColors = {
    'Critical': Color(0xFFE0223B),
    'High': Color(0xFFE67E22),
    'Normal': Color(0xFF2B6CB0),
    'Low': Color(0xFF8A8F98),
  };

  static const List<Map<String, String>> _dateFilters = [
    {'label': 'All Time', 'value': 'all'},
    {'label': 'Today', 'value': 'today'},
    {'label': 'Yesterday', 'value': 'yesterday'},
    {'label': 'This Week', 'value': 'week'},
    {'label': 'This Month', 'value': 'month'},
  ];

  static const List<String> _categories = [
    'Food', 'Transport', 'Rent', 'Shopping', 'Health',
    'Education', 'Bills', 'Entertainment', 'Others',
  ];

  _TypeFilter _typeFilter = _TypeFilter.all;
  String _dateFilter = 'all';
  String? _categoryFilter;
  final TextEditingController _searchController = TextEditingController();
  String _search = '';

  static const Map<String, _TypeFilter> _filterByName = {
    'transactions': _TypeFilter.transactions,
    'alerts': _TypeFilter.alerts,
    'notifications': _TypeFilter.notifications,
  };

  @override
  void initState() {
    super.initState();
    _typeFilter = _filterByName[widget.initialFilter] ?? _TypeFilter.all;
    _dateFilter = widget.initialDateFilter ?? 'all';
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _hasActiveFilters => _typeFilter != _TypeFilter.all || _dateFilter != 'all' || _categoryFilter != null;

  List<Map<String, dynamic>> _merged() {
    final alerts = ActivityFeedService.alerts.value;
    final notifications = ActivityFeedService.notifications.value
        .where((n) => n['status'] != 'Dismissed')
        .toList();

    List<Map<String, dynamic>> items;
    switch (_typeFilter) {
      case _TypeFilter.transactions:
        items = alerts.where((a) => _transactionAlertTypes.contains((a['type'] as String?)?.toLowerCase())).toList();
        break;
      case _TypeFilter.alerts:
        items = alerts.where((a) => !_transactionAlertTypes.contains((a['type'] as String?)?.toLowerCase())).toList();
        break;
      case _TypeFilter.notifications:
        items = notifications;
        break;
      case _TypeFilter.all:
        items = [...alerts, ...notifications];
    }

    if (_categoryFilter != null) {
      items = items.where((i) => i['category'] == _categoryFilter).toList();
    }

    if (_dateFilter != 'all') {
      final now = DateTime.now();
      items = items.where((i) {
        final t = _timeOf(i);
        switch (_dateFilter) {
          case 'today':
            return t.year == now.year && t.month == now.month && t.day == now.day;
          case 'yesterday':
            final y = now.subtract(const Duration(days: 1));
            return t.year == y.year && t.month == y.month && t.day == y.day;
          case 'week':
            return now.difference(t).inDays < 7;
          case 'month':
            return t.year == now.year && t.month == now.month;
          default:
            return true;
        }
      }).toList();
    }

    if (_search.trim().isNotEmpty) {
      final q = _search.trim().toLowerCase();
      items = items.where((i) {
        final text = [i['message'], i['title'], i['body'], i['category']]
            .where((v) => v != null)
            .join(' ')
            .toLowerCase();
        return text.contains(q);
      }).toList();
    }

    items.sort((a, b) => _timeOf(b).compareTo(_timeOf(a)));
    return items;
  }

  DateTime _timeOf(Map<String, dynamic> item) {
    final raw = item['createdAt'];
    if (raw is Timestamp) return raw.toDate();
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  // ── Alert-sourced item handling ──────────────────────────────────────

  Future<void> _onAlertTap(Map<String, dynamic> alert) async {
    if (alert['isRead'] != true) {
      final id = alert['id'] as String? ?? '';
      try {
        await ApiService.patch('/alerts/$id/read', {});
      } catch (e) {
        debugPrint('[ActivityFeed] markRead (alert) error: $e');
      }
    }
    if (!mounted) return;

    final type = (alert['type'] as String?)?.toLowerCase() ?? '';
    final cat = alert['category'] as String?;

    if (type == 'pending_transaction') {
      final transactionId = alert['relatedTransactionId'] as String?;
      if (transactionId != null) {
        await showCategorizeTransactionDialog(
          context,
          transactionId: transactionId,
          amount: (alert['amount'] as num?)?.toDouble() ?? 0,
          sourceApp: alert['sourceApp'] as String? ?? 'Unknown',
        );
      }
      return;
    }

    if (type == 'income') {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const IncomePage()));
    } else if (cat != null && cat.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => CategoryDetailPage(category: cat)),
      );
    }
  }

  // ── Notification-sourced item handling ───────────────────────────────

  Future<void> _markNotificationRead(String eventId) async {
    try {
      await ApiService.post('/notifications/$eventId/read', {});
    } catch (e) {
      debugPrint('[ActivityFeed] markRead (notification) error: $e');
    }
  }

  Future<void> _dismissNotification(String eventId) async {
    try {
      await ApiService.post('/notifications/$eventId/dismiss', {});
    } catch (e) {
      debugPrint('[ActivityFeed] dismiss (notification) error: $e');
    }
  }

  void _showNotificationDetail(Map<String, dynamic> n) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(n['title'] as String? ?? ''),
        content: Text(n['body'] as String? ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text((n['cta'] as String?)?.isNotEmpty == true
                ? n['cta'] as String
                : 'Close'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) => DateFormat('MMM d, h:mm a').format(t);

  // ── Row icon/tint per item kind — subtle, never a saturated full-row color ──

  ({IconData icon, Color tint}) _alertVisual(Map<String, dynamic> alert) {
    final type = (alert['type'] as String?)?.toLowerCase() ?? '';
    final severity = (alert['severity'] as String?)?.toLowerCase() ?? 'low';
    if (type == 'pending_transaction') return (icon: Icons.receipt_long_rounded, tint: const Color(0xFF2B6CB0));
    if (type == 'income') return (icon: Icons.arrow_downward_rounded, tint: _primary);
    if (type == 'budget_rebalanced') return (icon: Icons.swap_horiz_rounded, tint: const Color(0xFFE67E22));
    if (severity == 'medium' || severity == 'high') return (icon: Icons.warning_amber_rounded, tint: const Color(0xFFE67E22));
    return (icon: Icons.receipt_outlined, tint: Colors.grey.shade500);
  }

  Widget _rowShell({
    required bool unread,
    required Widget child,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: unread ? _unreadTint : Colors.white,
      child: child,
    );
  }

  Widget _buildAlertTile(Map<String, dynamic> alert) {
    final visual = _alertVisual(alert);
    final unread = alert['isRead'] != true;
    final message = alert['message'] as String? ?? alert['note'] as String? ?? '';
    final amount = (alert['amount'] as num?)?.toDouble();
    final type = (alert['type'] as String?)?.toLowerCase() ?? '';
    final isExpense = type == 'expense';
    final isIncome = type == 'income';

    return _rowShell(
      unread: unread,
      child: ListTile(
        onTap: () => _onAlertTap(alert),
        leading: CircleAvatar(
          backgroundColor: visual.tint.withValues(alpha: 0.12),
          child: Icon(visual.icon, color: visual.tint, size: 20),
        ),
        title: Text(
          message,
          style: TextStyle(
            fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
            color: Colors.black87,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          _formatTime(_timeOf(alert)),
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (amount != null && (isExpense || isIncome))
              Text(
                '${isIncome ? '+' : '-'}Rs ${amount.toStringAsFixed(0)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: isIncome ? _primary : Colors.black87,
                ),
              ),
            if (unread)
              Container(
                margin: const EdgeInsets.only(top: 4),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: _primary, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationTile(Map<String, dynamic> n) {
    final eventId = n['eventId'] as String? ?? '';
    final unread = n['status'] == 'Created' || n['status'] == 'Delivered';
    final color = _priorityColors[n['priority'] as String?] ?? _priorityColors['Normal']!;

    return Dismissible(
      key: ValueKey('notif:$eventId'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red.shade400,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _dismissNotification(eventId),
      child: _rowShell(
        unread: unread,
        child: ListTile(
          onTap: () {
            if (unread) _markNotificationRead(eventId);
            _showNotificationDetail(n);
          },
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(Icons.notifications, color: color, size: 20),
          ),
          title: Text(
            n['title'] as String? ?? '',
            style: TextStyle(
              fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
              color: Colors.black87,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            n['body'] as String? ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_formatTime(_timeOf(n)), style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              if (unread)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: _primary, shape: BoxShape.circle),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Filter bottom sheet ───────────────────────────────────────────────

  void _openFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) {
        _TypeFilter tempType = _typeFilter;
        String tempDate = _dateFilter;
        String? tempCategory = _categoryFilter;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Filter Activity', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      TextButton(
                        onPressed: () => setSheetState(() {
                          tempType = _TypeFilter.all;
                          tempDate = 'all';
                          tempCategory = null;
                        }),
                        child: const Text('Reset', style: TextStyle(color: Colors.grey)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Type', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<_TypeFilter>(
                    initialValue: tempType,
                    decoration: _dropdownDecoration(),
                    items: const [
                      DropdownMenuItem(value: _TypeFilter.all, child: Text('All')),
                      DropdownMenuItem(value: _TypeFilter.transactions, child: Text('Transactions')),
                      DropdownMenuItem(value: _TypeFilter.alerts, child: Text('Alerts')),
                      DropdownMenuItem(value: _TypeFilter.notifications, child: Text('Notifications')),
                    ],
                    onChanged: (v) => setSheetState(() => tempType = v ?? _TypeFilter.all),
                  ),
                  const SizedBox(height: 16),
                  const Text('Category', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    initialValue: tempCategory,
                    decoration: _dropdownDecoration(),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All Categories')),
                      ..._categories.map((c) => DropdownMenuItem<String?>(value: c, child: Text(c))),
                    ],
                    onChanged: (v) => setSheetState(() => tempCategory = v),
                  ),
                  const SizedBox(height: 16),
                  const Text('Date Range', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: tempDate,
                    decoration: _dropdownDecoration(),
                    items: _dateFilters
                        .map((f) => DropdownMenuItem(value: f['value'], child: Text(f['label']!)))
                        .toList(),
                    onChanged: (v) => setSheetState(() => tempDate = v ?? 'all'),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        setState(() {
                          _typeFilter = tempType;
                          _dateFilter = tempDate;
                          _categoryFilter = tempCategory;
                        });
                        Navigator.pop(sheetContext);
                      },
                      child: const Text('Apply Filters', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  InputDecoration _dropdownDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: const Color(0xFFF6F7F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Activity', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.tune_rounded),
                tooltip: 'Filter',
                onPressed: _openFilterSheet,
              ),
              if (_hasActiveFilters)
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: _primary, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search activity',
                hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                prefixIcon: Icon(Icons.search, color: Colors.grey.shade500, size: 20),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close, color: Colors.grey.shade500, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _search = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFFF6F7F9),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          Expanded(
            child: ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: ActivityFeedService.alerts,
              builder: (context, _, __) {
                return ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable: ActivityFeedService.notifications,
                  builder: (context, __, ___) {
                    final items = _merged();
                    if (items.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.notifications_none_outlined,
                                size: 56, color: Colors.grey.shade300),
                            const SizedBox(height: 12),
                            Text('No activity yet',
                                style: TextStyle(fontSize: 15, color: Colors.grey.shade400)),
                          ],
                        ),
                      );
                    }
                    return ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade100, indent: 72),
                      itemBuilder: (ctx, i) {
                        final item = items[i];
                        if (item['_source'] == 'notification') {
                          return _buildNotificationTile(item);
                        }
                        return _buildAlertTile(item);
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: const ChatFab(),
    );
  }
}
