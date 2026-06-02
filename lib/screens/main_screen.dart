import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../api_service.dart';
import '../services/notification_sync_service.dart';
import 'home_screen.dart';
import 'categories_screen.dart';
import 'chatbot_page.dart';
import 'login_screen.dart';
import 'notification_screen.dart';
import 'mock_notification_screen.dart';
import 'reports_screen.dart';

class MainScreen extends StatefulWidget {
  final String firstName;

  const MainScreen({super.key, required this.firstName});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  int _currentIndex = 0;
  bool _isLoggingOut = false;

  // Keys so we can call refresh on each tab without re-creating widgets
  final _homeKey = GlobalKey<HomeScreenState>();
  final _categoriesKey = GlobalKey<CategoriesScreenState>();

  String get _appBarTitle {
    switch (_currentIndex) {
      case 0:
        return 'BachatBot';
      case 1:
        return 'Categories';
      case 2:
        return 'Reports';
      default:
        return 'BachatBot';
    }
  }

  @override
  void initState() {
    super.initState();
    // Initialize real notification sync listener (Android only)
    NotificationSyncService().init();
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Logout', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoggingOut = true);
    try {
      // 1. Notify backend first — token is still valid at this point
      await ApiService.logout();
      // 2. Invalidate the client-side Firebase session
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Logout failed.'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoggingOut = false);
    }
  }

  /// Intent-based real-time refresh callback from chat.
  /// Called while chat is still open, immediately after bot responds.
  void _onChatRefreshNeeded({
    bool refreshHome = false,
    bool refreshCategories = false,
  }) {
    if (refreshHome) {
      _homeKey.currentState?.refresh();
    }
    if (refreshCategories) {
      _categoriesKey.currentState?.refresh();
    }
  }

  // Open chat; if a message was sent (returns true) → refresh home totals
  Future<void> _openChat() async {
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ChatBotPage(onRefreshNeeded: _onChatRefreshNeeded),
      ),
    );
    // Also refresh on pop as a safety net
    if (sent == true && mounted) {
      _homeKey.currentState?.refresh();
      _categoriesKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName ?? 'User';
    final email = user?.email ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      // ── Drawer ───────────────────────────────────────────────────────────
      drawer: Drawer(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              decoration: const BoxDecoration(color: _primary),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, size: 40, color: _primary),
              ),
              accountName: Text(displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              accountEmail: Text(email),
            ),
            ListTile(
              leading:
                  Icon(Icons.home, color: _currentIndex == 0 ? _primary : null),
              title: const Text('Home'),
              selected: _currentIndex == 0,
              selectedColor: _primary,
              onTap: () {
                setState(() => _currentIndex = 0);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.grid_view,
                  color: _currentIndex == 1 ? _primary : null),
              title: const Text('Categories'),
              selected: _currentIndex == 1,
              selectedColor: _primary,
              onTap: () {
                setState(() => _currentIndex = 1);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.insert_chart,
                  color: _currentIndex == 2 ? _primary : null),
              title: const Text('Reports'),
              selected: _currentIndex == 2,
              selectedColor: _primary,
              onTap: () {
                setState(() => _currentIndex = 2);
                Navigator.pop(context);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined,
                  color: Color(0xFF2DBE7F)),
              title: const Text('Test Mock Notification',
                  style: TextStyle(color: Color(0xFF2DBE7F))),
              subtitle: const Text('Dev only', style: TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const MockNotificationScreen()),
                );
              },
            ),
            const Divider(),
            ListTile(
              leading: _isLoggingOut
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.logout, color: Colors.red),
              title: const Text('Logout', style: TextStyle(color: Colors.red)),
              onTap: _isLoggingOut ? null : _logout,
            ),
          ],
        ),
      ),
      // ── Single AppBar (no child screen has its own) ───────────────────────
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        title: Text(
          _appBarTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _currentIndex == 0 ? _primary : Colors.black87,
            fontSize: 20,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            icon: ValueListenableBuilder<int>(
              valueListenable: NotificationScreen.unreadCount,
              builder: (context, count, child) {
                return Badge(
                  isLabelVisible: count > 0,
                  label: Text(count > 99 ? '99+' : count.toString()),
                  child: const Icon(Icons.notifications_none),
                );
              },
            ),
            tooltip: 'Notifications',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationScreen()),
            ),
          ),
        ],
      ),
      // ── IndexedStack keeps each tab's scroll/state alive ─────────────────
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(key: _homeKey, firstName: widget.firstName),
          CategoriesScreen(key: _categoriesKey),
          const ReportsScreen(),
        ],
      ),
      // ── FAB → chat ────────────────────────────────────────────────────────
      floatingActionButton: FloatingActionButton(
        backgroundColor: _primary,
        tooltip: 'Chat with BachatBot',
        onPressed: _openChat,
        child: const Icon(Icons.smart_toy_outlined, color: Colors.white),
      ),
      // ── Bottom nav ────────────────────────────────────────────────────────
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: _primary,
        unselectedItemColor: Colors.grey,
        backgroundColor: Colors.white,
        elevation: 8,
        onTap: (i) {
          setState(() => _currentIndex = i);
          // LIVE UPDATES SYNCHRONIZATION:
          // When switching tabs, we trigger a real-time data refresh on the active screen
          // to ensure that the monthly bar chart and financial summary cards are always
          // perfectly in sync with the latest transaction/budget database records.
          if (i == 0) {
            _homeKey.currentState?.refresh();
          } else if (i == 1) {
            _categoriesKey.currentState?.refresh();
          }
        },
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(Icons.grid_view_outlined),
              activeIcon: Icon(Icons.grid_view),
              label: 'Categories'),
          BottomNavigationBarItem(
              icon: Icon(Icons.insert_chart_outlined),
              activeIcon: Icon(Icons.insert_chart),
              label: 'Reports'),
        ],
      ),
    );
  }
}
