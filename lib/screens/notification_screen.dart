import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

IconData _categoryIcon(String? category) {
  switch (category?.toLowerCase()) {
    case 'food':
      return Icons.restaurant_outlined;
    case 'transport':
      return Icons.directions_bus_outlined;
    case 'rent':
      return Icons.home_outlined;
    case 'shopping':
      return Icons.shopping_bag_outlined;
    case 'health':
      return Icons.local_hospital_outlined;
    case 'education':
      return Icons.school_outlined;
    case 'bills':
      return Icons.receipt_long_outlined;
    case 'entertainment':
      return Icons.movie_outlined;
    default:
      return Icons.category_outlined;
  }
}

String _formatAlertTime(String? isoString) {
  if (isoString == null || isoString.isEmpty) return '';
  final dt = DateTime.tryParse(isoString)?.toLocal();
  if (dt == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final dtDay = DateTime(dt.year, dt.month, dt.day);
  final timeStr = DateFormat('h:mm a').format(dt);
  if (dtDay == today) return 'Today, $timeStr';
  if (dtDay == yesterday) return 'Yesterday, $timeStr';
  if (today.difference(dtDay).inDays < 7) {
    return '${DateFormat('EEE').format(dt)}, $timeStr';
  }
  return '${DateFormat('MMM d').format(dt)}, $timeStr';
}

// ── AlertCard ────────────────────────────────────────────────────────────────

class _AlertCard extends StatelessWidget {
  final Map<String, dynamic> alert;

  const _AlertCard({required this.alert});

  @override
  Widget build(BuildContext context) {
    final isRead = alert['isRead'] == true;
    final rawType = (alert['type'] as String?)?.toLowerCase() ?? 'expense';
    final category = (alert['category'] as String?) ?? 'Other';
    final amount = (alert['amount'] as num?)?.toDouble() ?? 0;
    final note = (alert['message'] as String?) ??
        (alert['note'] as String?) ??
        '';
    final createdAt =
        ((alert['createdAt'] ?? alert['date']) as Object?)?.toString();

    final isBudget = rawType.contains('budget');
    final isIncome = rawType == 'income';

    // ── Title ──
    final String title;
    if (isBudget) {
      title = 'Budget Update';
    } else if (isIncome) {
      title = 'Income';
    } else {
      title = category;
    }

    // ── Circle icon ──
    final Widget circleIcon;
    if (isBudget) {
      circleIcon = CircleAvatar(
        backgroundColor: Colors.blue.shade50,
        child: const Icon(Icons.account_balance_wallet_outlined,
            color: Colors.blue, size: 20),
      );
    } else if (isIncome) {
      circleIcon = CircleAvatar(
        backgroundColor: Colors.green.shade50,
        child: const Icon(Icons.arrow_downward_rounded,
            color: Colors.green, size: 20),
      );
    } else {
      circleIcon = CircleAvatar(
        backgroundColor: Colors.red.shade50,
        child: Icon(_categoryIcon(category),
            color: Colors.red.shade400, size: 20),
      );
    }

    // ── Amount ──
    final String amountStr;
    final Color amountColor;
    if (amount == 0) {
      amountStr = '';
      amountColor = Colors.grey;
    } else if (isIncome) {
      amountStr = '+Rs ${amount.toInt()}';
      amountColor = Colors.green.shade700;
    } else if (isBudget) {
      amountStr = 'Rs ${amount.toInt()}';
      amountColor = Colors.blue;
    } else {
      amountStr = '-Rs ${amount.toInt()}';
      amountColor = Colors.red.shade600;
    }

    return Stack(
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: isRead ? Colors.white : Colors.green.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isRead ? Colors.grey.shade200 : Colors.green.shade200,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 40, height: 40, child: circleIcon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade800,
                        ),
                      ),
                      if (note.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          note,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        _formatAlertTime(createdAt),
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                ),
                if (amountStr.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    amountStr,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: amountColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!isRead)
          Positioned(
            top: 8,
            right: 20,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

// ── NotificationScreen ───────────────────────────────────────────────────────

class NotificationScreen extends StatefulWidget {
  final String initialType;
  final String? initialCategory;
  final String initialDateRange;

  const NotificationScreen({
    super.key,
    this.initialType = 'all',
    this.initialCategory,
    this.initialDateRange = 'all',
  });

  static ValueNotifier<int> unreadCount = ValueNotifier(0);

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  late String _selectedType;
  late String _selectedTime;
  String? _selectedCategory;
  List<dynamic> _alerts = [];
  bool _isLoading = false;

  static const List<Map<String, String>> _timeFilters = [
    {'label': 'All Time', 'value': 'all'},
    {'label': 'Today', 'value': 'today'},
    {'label': 'Yesterday', 'value': 'yesterday'},
    {'label': 'This Week', 'value': 'week'},
    {'label': 'This Month', 'value': 'month'},
    {'label': 'Last Week', 'value': 'last_week'},
  ];

  static const List<Map<String, String>> _catFilters = [
    {'label': 'All', 'emoji': ''},
    {'label': 'Food', 'emoji': '🍽'},
    {'label': 'Transport', 'emoji': '🚌'},
    {'label': 'Rent', 'emoji': '🏠'},
    {'label': 'Shopping', 'emoji': '🛍'},
    {'label': 'Health', 'emoji': '💊'},
    {'label': 'Education', 'emoji': '📚'},
    {'label': 'Bills', 'emoji': '⚡'},
    {'label': 'Entertainment', 'emoji': '🎬'},
    {'label': 'Others', 'emoji': '📦'},
  ];

  @override
  void initState() {
    super.initState();
    _selectedType = widget.initialType;
    _selectedCategory = widget.initialCategory;
    _selectedTime = widget.initialDateRange;
    _fetchAlerts();
  }

  Future<void> _fetchAlerts() async {
    setState(() => _isLoading = true);
    try {
      final params = <String, String>{};
      if (_selectedType != 'all') params['type'] = _selectedType;
      if (_selectedTime != 'all') params['dateRange'] = _selectedTime;
      if (_selectedType == 'expense' && _selectedCategory != null) {
        params['category'] = _selectedCategory!;
      }

      final queryString = params.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final endpoint =
          '/alerts${queryString.isNotEmpty ? '?$queryString' : ''}';

      final res = await ApiService.get(endpoint);
      if (!mounted) return;

      if (res['success'] == true) {
        final raw = res['data']?['alerts'] ?? res['data'] ?? [];
        final sorted = List<dynamic>.from(raw);
        sorted.sort((a, b) {
          final da = a['createdAt'] ?? a['date'] ?? '';
          final db = b['createdAt'] ?? b['date'] ?? '';
          return db.toString().compareTo(da.toString());
        });
        setState(() => _alerts = sorted);
        NotificationScreen.unreadCount.value =
            _alerts.where((a) => a['isRead'] != true).length;
      }
    } catch (e) {
      debugPrint('[NotificationScreen] error: $e');
      if (mounted) setState(() => _alerts = []);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _markAllRead() async {
    final unread = _alerts.where((a) => a['isRead'] != true).toList();
    if (unread.isEmpty) return;
    try {
      await Future.wait(
        unread.map((a) {
          final id = a['id'] ?? a['_id'] ?? '';
          return ApiService.patch('/alerts/$id/read', {});
        }),
      );
    } catch (e) {
      debugPrint('[NotificationScreen] markAllRead error: $e');
    }
    await _fetchAlerts();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All caught up!'),
          backgroundColor: _primary,
        ),
      );
    }
  }

  void _setType(String type) {
    if (_selectedType == type) return;
    setState(() {
      _selectedType = type;
      if (type != 'expense') _selectedCategory = null;
    });
    _fetchAlerts();
  }

  void _setTime(String time) {
    if (_selectedTime == time) return;
    setState(() => _selectedTime = time);
    _fetchAlerts();
  }

  void _setCategory(String? cat) {
    if (_selectedCategory == cat) return;
    setState(() => _selectedCategory = cat);
    _fetchAlerts();
  }

  Widget _typePill(String label, String value) {
    final selected = _selectedType == value;
    return GestureDetector(
      onTap: () => _setType(value),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? Colors.green : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: selected ? Colors.white : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  Widget _choiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.green.shade50 : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? Colors.green : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.green : Colors.grey,
            fontWeight:
                selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = _alerts.any((a) => a['isRead'] != true);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Activity',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          if (hasUnread)
            TextButton(
              onPressed: _markAllRead,
              child: const Text(
                'Mark all read',
                style: TextStyle(color: _primary, fontSize: 12),
              ),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Filter panel ─────────────────────────────────────────────────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row 1: Type pills
                Row(
                  children: [
                    _typePill('All', 'all'),
                    const SizedBox(width: 8),
                    _typePill('Expense', 'expense'),
                    const SizedBox(width: 8),
                    _typePill('Income', 'income'),
                  ],
                ),
                const SizedBox(height: 10),

                // Row 2: Time chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _timeFilters.map((f) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _choiceChip(
                          label: f['label']!,
                          selected: _selectedTime == f['value'],
                          onTap: () => _setTime(f['value']!),
                        ),
                      );
                    }).toList(),
                  ),
                ),

                // Row 3: Category chips (expense only)
                if (_selectedType == 'expense') ...[
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _catFilters.map((f) {
                        final lbl = f['label']!;
                        final emoji = f['emoji']!;
                        final catVal = lbl == 'All' ? null : lbl;
                        final chipLabel =
                            emoji.isEmpty ? lbl : '$emoji $lbl';
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _choiceChip(
                            label: chipLabel,
                            selected: _selectedCategory == catVal,
                            onTap: () => _setCategory(catVal),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),

          Divider(color: Colors.grey.shade200, height: 1),

          // ── Feed ─────────────────────────────────────────────────────────
          Expanded(
            child: RefreshIndicator(
              color: _primary,
              onRefresh: _fetchAlerts,
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: _primary))
                  : _alerts.isEmpty
                      ? ListView(
                          children: [
                            SizedBox(
                              height:
                                  MediaQuery.of(context).size.height * 0.4,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.notifications_none_outlined,
                                    size: 64,
                                    color: Colors.grey.shade300,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'No activity yet',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey.shade400,
                                    ),
                                  ),
                                  Text(
                                    'Your transactions will appear here',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade300,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _alerts.length,
                          itemBuilder: (ctx, i) => _AlertCard(
                            alert: _alerts[i] as Map<String, dynamic>,
                          ),
                        ),
            ),
          ),
        ],
      ),
    );
  }
}
