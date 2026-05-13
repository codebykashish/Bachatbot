import 'package:flutter/material.dart';
import '../api_service.dart';

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  static ValueNotifier<int> unreadCount = ValueNotifier(0);

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  List<dynamic> _alerts = [];

  String _filterCategory = 'All';
  String _filterDateRange = 'All';
  final TextEditingController _searchController = TextEditingController();

  static const List<String> _categories = [
    'All', 'Food', 'Transport', 'Rent', 'Education',
    'Shopping', 'Health', 'Entertainment', 'Bills', 'Salary', 'Other',
  ];

  static const List<String> _dateFilters = ['All', 'Today', 'This Week', 'This Month'];

  @override
  void initState() {
    super.initState();
    _fetchAlerts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchAlerts() async {
    setState(() => _isLoading = true);
    try {
      // Build query params for GET /alerts
      final params = <String, String>{};
      if (_filterCategory != 'All') {
        params['category'] = _filterCategory;
      }
      if (_filterDateRange != 'All') {
        params['dateRange'] = _filterDateRange;
      }

      final queryString = params.entries
          .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final endpoint = '/alerts${queryString.isNotEmpty ? '?$queryString' : ''}';

      debugPrint('[NotificationScreen] fetching: $endpoint');
      final res = await ApiService.get(endpoint);
      if (!mounted) return;
      debugPrint('[NotificationScreen] response: ${res['success']}');

      if (res['success'] == true) {
        final rawAlerts = res['data']?['alerts'] ?? res['data'] ?? [];
        // Sort newest-first by createdAt
        final sortedAlerts = List<dynamic>.from(rawAlerts);
        sortedAlerts.sort((a, b) {
          final dateA = a['createdAt'] ?? a['date'] ?? '';
          final dateB = b['createdAt'] ?? b['date'] ?? '';
          return dateB.toString().compareTo(dateA.toString());
        });
        setState(() => _alerts = sortedAlerts);
        NotificationScreen.unreadCount.value = _alerts.where((a) => a['isRead'] != true).length;
      }
    } catch (e) {
      debugPrint('[NotificationScreen] error: $e');
      // Keep empty list on failure
      if (mounted) {
        setState(() => _alerts = []);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<dynamic> get _filteredAlerts {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) return _alerts;

    return _alerts.where((a) {
      final msg = (a['message'] ?? '').toString().toLowerCase();
      return msg.contains(query);
    }).toList();
  }

  String _relativeDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      final date = DateTime.parse(dateStr);
      final diff = DateTime.now().difference(date);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays == 1) return 'Yesterday';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${date.day}/${date.month}/${date.year}';
    } catch (_) {
      return dateStr;
    }
  }

  Color _catColor(String cat) {
    const map = {
      'Food': Color(0xFFFF7043),
      'Transport': Color(0xFF42A5F5),
      'Rent': Color(0xFF26A69A),
      'Education': Color(0xFF7E57C2),
      'Shopping': Color(0xFFAB47BC),
      'Health': Color(0xFFEF5350),
      'Entertainment': Color(0xFF8D6E63),
      'Bills': Color(0xFF78909C),
      'Salary': Color(0xFF66BB6A),
    };
    return map[cat] ?? const Color(0xFFFFCA28);
  }

  IconData _catIcon(String cat) {
    const map = {
      'Food': Icons.restaurant,
      'Transport': Icons.directions_car,
      'Rent': Icons.home,
      'Education': Icons.school,
      'Shopping': Icons.shopping_bag,
      'Health': Icons.favorite,
      'Entertainment': Icons.tv,
      'Bills': Icons.receipt_long,
      'Salary': Icons.account_balance_wallet,
    };
    return map[cat] ?? Icons.notifications;
  }

  void _toggleRead(int index) {
    setState(() {
      final item = Map<String, dynamic>.from(_alerts[index]);
      item['isRead'] = !(item['isRead'] == true);
      _alerts[index] = item;
    });
    NotificationScreen.unreadCount.value = _alerts.where((a) => a['isRead'] != true).length;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredAlerts;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          if (_alerts.any((a) => a['isRead'] != true))
            TextButton(
              onPressed: () => setState(() {
                _alerts = _alerts.map((a) {
                  final m = Map<String, dynamic>.from(a);
                  m['isRead'] = true;
                  return m;
                }).toList();
                NotificationScreen.unreadCount.value = 0;
              }),
              child: const Text('Mark all read', style: TextStyle(color: Color(0xFF2DBE7F), fontSize: 12)),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Filter bar ──────────────────────────────────────────────────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                // Search
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search notifications...',
                    hintStyle: const TextStyle(fontSize: 13),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    filled: true,
                    fillColor: const Color(0xFFF6F7F9),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 10),
                // Category + Date range filters
                Row(
                  children: [
                    Expanded(
                      child: _buildDropdown(
                        value: _filterCategory,
                        items: _categories,
                        onChanged: (v) {
                          setState(() => _filterCategory = v);
                          _fetchAlerts();
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildDropdown(
                        value: _filterDateRange,
                        items: _dateFilters,
                        onChanged: (v) {
                          setState(() => _filterDateRange = v);
                          _fetchAlerts();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── List ────────────────────────────────────────────────────────
          Expanded(
            child: RefreshIndicator(
              color: _primary,
              onRefresh: _fetchAlerts,
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF2DBE7F)))
                  : filtered.isEmpty
                      ? ListView(
                          // Wrap in ListView for RefreshIndicator to work
                          children: [
                            SizedBox(
                              height: MediaQuery.of(context).size.height * 0.4,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.notifications_none, size: 64, color: Colors.grey.shade300),
                                  const SizedBox(height: 16),
                                  const Text('No notifications', style: TextStyle(color: Colors.grey, fontSize: 15)),
                                  const SizedBox(height: 8),
                                  Text(
                                    _filterCategory != 'All' || _filterDateRange != 'All'
                                        ? 'Try changing your filters.'
                                        : 'Alerts will appear here when you log expenses.',
                                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (ctx, i) {
                            final alert = filtered[i];
                            final isRead = alert['isRead'] == true;
                            final cat = alert['category'] ?? 'Other';
                            final date = alert['createdAt'] ?? alert['date'] ?? '';
                            final originalIndex = _alerts.indexOf(alert);

                            return Container(
                              decoration: BoxDecoration(
                                color: isRead ? Colors.white : const Color(0xFFEAFAF3),
                                borderRadius: BorderRadius.circular(14),
                                border: isRead
                                    ? Border.all(color: Colors.grey.shade200)
                                    : Border.all(color: _primary.withValues(alpha: 0.2)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                                leading: Container(
                                  width: 40, height: 40,
                                  decoration: BoxDecoration(
                                    color: _catColor(cat).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(_catIcon(cat), color: _catColor(cat), size: 20),
                                ),
                                title: Text(
                                  alert['message'] ?? '',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isRead ? FontWeight.normal : FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: _catColor(cat).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(cat, style: TextStyle(fontSize: 10, color: _catColor(cat), fontWeight: FontWeight.w600)),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(_relativeDate(date), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                    ],
                                  ),
                                ),
                                trailing: Checkbox(
                                  value: isRead,
                                  activeColor: _primary,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                  onChanged: (_) {
                                    if (originalIndex >= 0) _toggleRead(originalIndex);
                                  },
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ),
        ],
      ),
    );
  }

  /// Reusable dropdown that avoids the DropdownButtonFormField deprecation
  /// and the initialValue vs value confusion.
  Widget _buildDropdown({
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          style: const TextStyle(fontSize: 13, color: Colors.black87),
          items: items.map((item) => DropdownMenuItem(
            value: item,
            child: Text(item),
          )).toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
