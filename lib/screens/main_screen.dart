import 'package:flutter/material.dart';
import '../services/notification_sync_service.dart';
import '../services/month_event_service.dart';
import 'home_screen.dart';
import 'categories_screen.dart';
import 'chatbot_page.dart';
import 'notification_screen.dart';
import 'profile_screen.dart';
import 'reports_screen.dart';

class MainScreen extends StatefulWidget {
  final String firstName;
  final bool showTour;

  const MainScreen({super.key, required this.firstName, this.showTour = false});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  int _currentIndex = 0;

  // Keys so we can call refresh on each tab without re-creating widgets
  final _homeKey = GlobalKey<HomeScreenState>();
  final _categoriesKey = GlobalKey<CategoriesScreenState>();
  final _reportsKey = GlobalKey<ReportsScreenState>();
  final _profileKey = GlobalKey<ProfileScreenState>();

  // ── Month event banner ──────────────────────────────────────────────────
  MonthEvent? _activeBanner;
  late final VoidCallback _monthBannerListener;

  String get _appBarTitle {
    switch (_currentIndex) {
      case 0:
        return 'BachatBot';
      case 1:
        return 'Categories';
      case 2:
        return 'Reports';
      case 3:
        return 'Profile';
      default:
        return 'BachatBot';
    }
  }

  @override
  void initState() {
    super.initState();
    // Initialize real notification sync listener (Android only)
    NotificationSyncService().init();
    // Initialize month event polling service
    MonthEventService().init();
    // Listen for month events to show in-app banners
    _monthBannerListener = () {
      final event = MonthEventService.eventNotifier.value;
      if (event != null && mounted) {
        setState(() => _activeBanner = event);
        // Auto-dismiss after 8 seconds
        Future.delayed(const Duration(seconds: 8), () {
          if (mounted) setState(() => _activeBanner = null);
        });
      }
    };
    MonthEventService.eventNotifier.addListener(_monthBannerListener);
  }

  @override
  void dispose() {
    MonthEventService.eventNotifier.removeListener(_monthBannerListener);
    super.dispose();
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
      _profileKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      // ── Single AppBar (no child screen has its own) ───────────────────────
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: _currentIndex > 0
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.black87),
                onPressed: () => setState(() => _currentIndex = 0),
              )
            : null,
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
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: [
              HomeScreen(
                key: _homeKey,
                firstName: widget.firstName,
                showTour: widget.showTour,
                onSeeAllCategories: () => setState(() => _currentIndex = 1),
                onViewFullReports: () => setState(() => _currentIndex = 2),
              ),
              CategoriesScreen(key: _categoriesKey),
              ReportsScreen(key: _reportsKey),
              ProfileScreen(key: _profileKey),
            ],
          ),
          // ── Month event in-app banner ─────────────────────────────────
          if (_activeBanner != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildMonthBanner(_activeBanner!),
            ),
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
        type: BottomNavigationBarType.fixed,
        onTap: (i) {
          setState(() => _currentIndex = i);
          if (i == 0) {
            _homeKey.currentState?.refresh();
          } else if (i == 1) {
            _categoriesKey.currentState?.refresh();
          } else if (i == 2) {
            _reportsKey.currentState?.refresh();
          } else if (i == 3) {
            _profileKey.currentState?.refresh();
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
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Profile'),
        ],
      ),
    );
  }

  // ── Month event banner widget ───────────────────────────────────────────

  Widget _buildMonthBanner(MonthEvent event) {
    final isPreMonth = event.type == MonthEventType.preNewMonth;
    final bannerColor =
        isPreMonth ? const Color(0xFF4F6CFF) : const Color(0xFF2DBE7F);
    final title = isPreMonth ? 'Naya mahina aaudaichha' : 'Naya mahina suru bhayo!';
    final body = isPreMonth
        ? 'Agami mahina ko budget herera set / update garnu hola.'
        : 'Paila ko mahina ko kharcha ko base ma timro yo mahina ko budget set gariyeko chha.';

    return Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: bannerColor,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: bannerColor.withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              isPreMonth
                  ? Icons.calendar_month_outlined
                  : Icons.celebration_outlined,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.88),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => setState(() => _activeBanner = null),
            ),
          ],
        ),
      ),
    );
  }
}
