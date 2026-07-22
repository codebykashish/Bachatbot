import 'package:flutter/material.dart';
import '../api_service.dart';

class NotificationPreferencesScreen extends StatefulWidget {
  const NotificationPreferencesScreen({super.key});

  @override
  State<NotificationPreferencesScreen> createState() =>
      _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState
    extends State<NotificationPreferencesScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  static const List<_Category> _categories = [
    _Category(
      key: 'transactions',
      icon: '🔔',
      title: 'Transactions',
      subtitle: 'When a transaction is logged or confirmed',
    ),
    _Category(
      key: 'budgetAlerts',
      icon: '📊',
      title: 'Budget Alerts',
      subtitle: 'When you\'ve used up a category budget',
    ),
    _Category(
      key: 'financialHealth',
      icon: '❤️',
      title: 'Financial Health',
      subtitle: 'Important changes to your financial wellbeing',
    ),
    _Category(
      key: 'recovery',
      icon: '🛟',
      title: 'Recovery',
      subtitle: 'Updates when you\'re recovering from financial stress',
    ),
    _Category(
      key: 'streaks',
      icon: '🔥',
      title: 'Streaks & Progress',
      subtitle: 'Your financial habits and progress',
    ),
    _Category(
      key: 'milestones',
      icon: '🏆',
      title: 'Milestones',
      subtitle: 'Celebrate your achievements',
    ),
  ];

  bool _isLoading = true;
  bool _isSaving = false;
  Map<String, dynamic> _preferences = {};
  Map<String, bool> _notifications = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final res = await ApiService.get('/profile');
      final data = res['data'] as Map<String, dynamic>?;
      final prefs = (data?['preferences'] as Map<String, dynamic>?) ?? {};
      final notifications =
          (prefs['notifications'] as Map<String, dynamic>?) ?? {};
      if (mounted) {
        setState(() {
          _preferences = prefs;
          _notifications = {
            for (final c in _categories)
              c.key: notifications[c.key] as bool? ?? true,
          };
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[NotificationPreferencesScreen] Failed to load: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggle(String key, bool value) async {
    final previous = Map<String, bool>.from(_notifications);
    setState(() {
      _notifications[key] = value;
      _isSaving = true;
    });
    try {
      await ApiService.patch('/profile', {
        'preferences': {
          ..._preferences,
          'notifications': _notifications,
        },
      });
    } catch (e) {
      debugPrint('[NotificationPreferencesScreen] Failed to save: $e');
      if (mounted) {
        setState(() => _notifications = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: const Text('Notification Preferences'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF22252A),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Choose what BachatBot keeps you informed about.',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 16),
                ..._categories.map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _categoryCard(c),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF4E5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFF5C879)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 20, color: Color(0xFFB4770E)),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Some critical financial alerts will still be delivered '
                          'when they need your attention, even if a category is off.',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF8A5A0A),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _categoryCard(_Category c) {
    final value = _notifications[c.key] ?? true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeThumbColor: _primary,
        secondary: Text(c.icon, style: const TextStyle(fontSize: 22)),
        title: Text(c.title,
            style:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
        subtitle: Text(c.subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        value: value,
        onChanged: _isSaving ? null : (v) => _toggle(c.key, v),
      ),
    );
  }
}

class _Category {
  final String key;
  final String icon;
  final String title;
  final String subtitle;

  const _Category({
    required this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });
}
