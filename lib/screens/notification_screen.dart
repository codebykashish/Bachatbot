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
  String _filterDate = 'Month';
  final TextEditingController _searchController = TextEditingController();

  static const List<String> _categories = ['All', 'Food', 'Transport', 'Rent', 'Education', 'Shopping', 'Health', 'Entertainment', 'Bills', 'Other'];
  static const List<String> _dateFilters = ['Today', 'Week', 'Month'];

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
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      String endpoint = '/alerts?monthKey=$monthKey';
      if (_filterCategory != 'All') endpoint += '&category=$_filterCategory';

      final res = await ApiService.get(endpoint);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() => _alerts = res['data']?['alerts'] ?? res['data'] ?? []);
        NotificationScreen.unreadCount.value = _alerts.where((a) => a['isRead'] != true).length;
      }
    } catch (_) {
      // show stub if API not ready
      if (mounted) {
        setState(() => _alerts = _stubAlerts());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Stub alerts for when API isn't available yet
  List<Map<String, dynamic>> _stubAlerts() => [
    {
      'id': '1',
      'message': 'You spent Rs 450 on Food this month.',
      'category': 'Food',
      'date': DateTime.now().toIso8601String(),
      'isRead': false,
    },
    {
      'id': '2',
      'message': 'Shopping budget is 103% over limit!',
      'category': 'Shopping',
      'date': DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
      'isRead': false,
    },
    {
      'id': '3',
      'message': 'You saved Rs 240 this month! Great job.',
      'category': 'Other',
      'date': DateTime.now().subtract(const Duration(days: 2)).toIso8601String(),
      'isRead': true,
    },
  ];

  List<dynamic> get _filteredAlerts {
    final query = _searchController.text.toLowerCase();
    return _alerts.where((a) {
      final msg = (a['message'] ?? '').toString().toLowerCase();
      final cat = (a['category'] ?? '').toString();
      final matchesSearch = query.isEmpty || msg.contains(query);
      final matchesCat = _filterCategory == 'All' || cat == _filterCategory;
      // date filter
      final dateStr = a['date'] ?? a['createdAt'] ?? '';
      DateTime? date;
      try { date = DateTime.parse(dateStr); } catch (_) {}
      bool matchesDate = true;
      if (date != null) {
        final now = DateTime.now();
        if (_filterDate == 'Today') {
          matchesDate = date.year == now.year && date.month == now.month && date.day == now.day;
        } else if (_filterDate == 'Week') {
          matchesDate = now.difference(date).inDays <= 7;
        } else {
          matchesDate = date.year == now.year && date.month == now.month;
        }
      }
      return matchesSearch && matchesCat && matchesDate;
    }).toList();
  }

  String _relativeDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final date = DateTime.parse(dateStr);
      final diff = DateTime.now().difference(date);
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
    };
    return map[cat] ?? const Color(0xFFFFCA28);
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
    final filtered = _filteredAlerts.reversed.toList();

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
                // Category + Date filters
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _filterCategory,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFFF6F7F9),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        ),
                        style: const TextStyle(fontSize: 13, color: Colors.black87),
                        items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                        onChanged: (v) {
                          if (v != null) setState(() { _filterCategory = v; _fetchAlerts(); });
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _filterDate,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFFF6F7F9),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        ),
                        style: const TextStyle(fontSize: 13, color: Colors.black87),
                        items: _dateFilters.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                        onChanged: (v) { if (v != null) setState(() => _filterDate = v); },
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
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.notifications_none, size: 64, color: Colors.grey.shade300),
                              const SizedBox(height: 16),
                              const Text('No notifications', style: TextStyle(color: Colors.grey, fontSize: 15)),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (ctx, i) {
                            final alert = filtered[i];
                            final isRead = alert['isRead'] == true;
                            final cat = alert['category'] ?? 'Other';
                            final date = alert['date'] ?? alert['createdAt'] ?? '';
                            final originalIndex = _alerts.indexOf(alert);

                            return Container(
                              decoration: BoxDecoration(
                                color: isRead ? Colors.white : const Color(0xFFEAFAF3),
                                borderRadius: BorderRadius.circular(14),
                                border: isRead
                                    ? Border.all(color: Colors.grey.shade200)
                                    : Border.all(color: _primary.withOpacity(0.2)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.04),
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
                                    color: _catColor(cat).withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(Icons.notifications, color: _catColor(cat), size: 20),
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
                                          color: _catColor(cat).withOpacity(0.12),
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
}
