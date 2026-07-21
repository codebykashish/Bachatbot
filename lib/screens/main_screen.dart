import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/notification_sync_service.dart';
import '../services/sms_sync_service.dart';
import '../services/month_event_service.dart';
import '../services/alert_popup_service.dart';
import '../services/activity_feed_service.dart';
import '../services/push_notification_service.dart';
import '../services/behavior_preview_service.dart';
import '../widgets/slide_up_route.dart';
import '../api_service.dart';
import 'home_screen.dart';
import 'categories_screen.dart';
import 'chatbot_page.dart';
import 'activity_feed_screen.dart';
import 'behavior_screen.dart';
import 'profile_screen.dart';
import 'reports_screen.dart';
import 'goals_screen.dart';

class MainScreen extends StatefulWidget {
  final String firstName;
  final bool showTour;

  const MainScreen({super.key, required this.firstName, this.showTour = false});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  static const Color _primary = Color(0xFF2DBE7F);

  int _currentIndex = 0;

  final _homeKey       = GlobalKey<HomeScreenState>();
  final _categoriesKey = GlobalKey<CategoriesScreenState>();
  final _reportsKey    = GlobalKey<ReportsScreenState>();
  final _profileKey    = GlobalKey<ProfileScreenState>();

  // Keys for spotlight positioning
  final _fabKey        = GlobalKey();
  final _bottomNavKey  = GlobalKey();

  // ── Tour state ────────────────────────────────────────────────────────────
  bool _tourActive = false;
  int  _tourStep   = 0;

  late final AnimationController _tourFadeCtrl;
  late final Animation<double>   _tourFadeAnim;
  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;

  static const List<_TourStep> _tourSteps = [
    _TourStep(
      icon: Icons.waving_hand_outlined,
      title: 'Welcome to BachatBot!',
      body: 'Quick 5-step tour — tap each highlighted element to continue, or press Next to skip ahead.',
      targetType: _TargetType.none,
    ),
    _TourStep(
      icon: Icons.visibility_outlined,
      title: 'Show / hide your amounts',
      body: 'Tap the eye icon to toggle your balance and spending amounts on or off.',
      targetType: _TargetType.eyeIcon,
    ),
    _TourStep(
      icon: Icons.grid_view_outlined,
      title: 'Set your budgets here',
      body: 'Tap the Categories tab — add monthly spending limits for Food, Transport, Shopping, and more.',
      targetType: _TargetType.navCategories,
    ),
    _TourStep(
      icon: Icons.smart_toy_outlined,
      title: 'Log expenses by chatting',
      body: 'Tap the green robot button and type something like "Momo 250" or "Bus 40". BachatBot saves it instantly.',
      targetType: _TargetType.fab,
    ),
    _TourStep(
      icon: Icons.insert_chart_outlined,
      title: 'Check your monthly report',
      body: 'Tap the Reports tab to see your income, spending, and savings — with a Low / Medium / High status.',
      targetType: _TargetType.navReports,
    ),
    _TourStep(
      icon: Icons.person_outline_rounded,
      title: 'Manage your profile',
      body: 'Tap Profile to edit your info, update income, view FAQs, or reach out to us.',
      targetType: _TargetType.navProfile,
    ),
  ];

  // ── Month event banner ────────────────────────────────────────────────────
  MonthEvent? _activeBanner;
  late final VoidCallback _monthBannerListener;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    _tourFadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _tourFadeAnim = CurvedAnimation(parent: _tourFadeCtrl, curve: Curves.easeInOut);

    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnim = CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut);

    NotificationSyncService().init();
    SmsSyncService().init();
    MonthEventService().init();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      AlertPopupService().init(uid);
      ActivityFeedService().init(uid);
      PushNotificationService().init();
      BehaviorPreviewService.refresh();
    }

    _checkPendingTransactionsAndNavigate();

    _monthBannerListener = () {
      final event = MonthEventService.eventNotifier.value;
      if (event != null && mounted) {
        setState(() => _activeBanner = event);
        Future.delayed(const Duration(seconds: 8), () {
          if (mounted) setState(() => _activeBanner = null);
        });
      }
    };
    MonthEventService.eventNotifier.addListener(_monthBannerListener);

    if (widget.showTour) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndStartTour());
    }
  }

  // Runs once per app open — if any SMS/notification-detected transaction
  // is still awaiting categorization, take the user straight to the
  // Activity screen so they know to check it, instead of leaving it
  // buried until they happen to tap the bell icon themselves.
  Future<void> _checkPendingTransactionsAndNavigate() async {
    try {
      final res = await ApiService.get('/alerts?isRead=false&limit=50');
      if (!mounted || res['success'] != true) return;

      final alerts = res['data']?['alerts'] as List? ?? [];
      final hasPending = alerts.any((a) => a['type'] == 'pending_transaction');
      if (!hasPending) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ActivityFeedScreen()),
        );
      });
    } catch (e) {
      debugPrint('[MainScreen] pending transaction check failed: $e');
    }
  }

  @override
  void dispose() {
    _tourFadeCtrl.dispose();
    _pulseCtrl.dispose();
    MonthEventService.eventNotifier.removeListener(_monthBannerListener);
    super.dispose();
  }

  // ── Tour helpers ──────────────────────────────────────────────────────────

  Future<void> _checkAndStartTour() async {
    final prefs = await SharedPreferences.getInstance();
    // Always show tour for a fresh account coming through onboarding
    await prefs.setBool('tour_done', false);
    await Future.delayed(const Duration(milliseconds: 1000));
    if (mounted) {
      setState(() {
        _tourActive = true;
        _tourStep   = 0;
      });
      _tourFadeCtrl.forward();
    }
  }

  void _tourAdvance() {
    if (_tourStep < _tourSteps.length - 1) {
      setState(() => _tourStep++);
    } else {
      _tourFinish();
    }
  }

  Future<void> _tourFinish() async {
    await _tourFadeCtrl.reverse();
    if (mounted) setState(() => _tourActive = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tour_done', true);
  }

  /// Returns the screen-space Rect for the element the current step highlights.
  Rect? _spotlightRect(BuildContext context) {
    final step = _tourSteps[_tourStep];
    switch (step.targetType) {
      case _TargetType.none:
        return null;

      case _TargetType.eyeIcon:
        final box = _homeKey.currentState?.eyeIconKey.currentContext
            ?.findRenderObject() as RenderBox?;
        if (box == null) return null;
        final pos = box.localToGlobal(Offset.zero);
        return (pos - const Offset(6, 6)) &
            Size(box.size.width + 12, box.size.height + 12);

      case _TargetType.fab:
        final box = _fabKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) return null;
        final pos = box.localToGlobal(Offset.zero);
        return (pos - const Offset(10, 10)) &
            Size(box.size.width + 20, box.size.height + 20);

      case _TargetType.navCategories:
        return _navItemRect(1, context);
      case _TargetType.navReports:
        return _navItemRect(2, context);
      case _TargetType.navProfile:
        return _navItemRect(3, context);
    }
  }

  Rect? _navItemRect(int tabIndex, BuildContext context) {
    final navBox = _bottomNavKey.currentContext?.findRenderObject() as RenderBox?;
    if (navBox == null) return null;
    final navPos  = navBox.localToGlobal(Offset.zero);
    final navSize = navBox.size;
    final itemW   = navSize.width / 4;
    return Rect.fromLTWH(navPos.dx + itemW * tabIndex, navPos.dy, itemW, navSize.height);
  }

  // ── Chat ──────────────────────────────────────────────────────────────────

  void _onChatRefreshNeeded({bool refreshHome = false, bool refreshCategories = false}) {
    if (refreshHome) _homeKey.currentState?.refresh();
    if (refreshCategories) _categoriesKey.currentState?.refresh();
    _reportsKey.currentState?.refresh();
  }

  Future<void> _openChat() async {
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ChatBotPage(onRefreshNeeded: _onChatRefreshNeeded),
      ),
    );
    if (sent == true && mounted) {
      _homeKey.currentState?.refresh();
      _categoriesKey.currentState?.refresh();
      _profileKey.currentState?.refresh();
      _reportsKey.currentState?.refresh();
    }
  }

  // ── App bar title ─────────────────────────────────────────────────────────

  String get _appBarTitle {
    switch (_currentIndex) {
      case 0: return 'BachatBot';
      case 1: return 'Categories';
      case 2: return 'Reports';
      case 3: return 'Profile';
      default: return 'BachatBot';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          backgroundColor: const Color(0xFFF6F7F9),
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
              GestureDetector(
                onTap: () => Navigator.push(context, slideUpRoute(const BehaviorScreen())),
                child: ValueListenableBuilder<int>(
                  valueListenable: BehaviorPreviewService.loggingStreak,
                  builder: (context, streak, child) => Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E8),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.local_fire_department, color: Color(0xFFE67E22), size: 18),
                        const SizedBox(width: 3),
                        Text(
                          '$streak',
                          style: const TextStyle(
                            color: Color(0xFFE67E22),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.savings_outlined, color: _primary, size: 20),
                ),
                tooltip: 'Goals',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const GoalsScreen()),
                ),
              ),
              IconButton(
                icon: ValueListenableBuilder<int>(
                  valueListenable: ActivityFeedService.unreadCount,
                  builder: (context, count, child) => Badge(
                    isLabelVisible: count > 0,
                    label: Text(count > 99 ? '99+' : count.toString()),
                    child: const Icon(Icons.notifications_none),
                  ),
                ),
                tooltip: 'Notifications',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ActivityFeedScreen()),
                ),
              ),
            ],
          ),
          body: Stack(
            children: [
              IndexedStack(
                index: _currentIndex,
                children: [
                  HomeScreen(
                    key: _homeKey,
                    firstName: widget.firstName,
                    showTour: false, // tour is now managed here
                    onSeeAllCategories: () => setState(() => _currentIndex = 1),
                    onViewFullReports:  () => setState(() => _currentIndex = 2),
                    onAddCategory: () {
                      setState(() => _currentIndex = 1);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _categoriesKey.currentState?.openAddSheet();
                      });
                    },
                    onEyeTapped: () {
                      if (_tourActive && _tourStep == 1) _tourAdvance();
                    },
                  ),
                  CategoriesScreen(key: _categoriesKey),
                  ReportsScreen(key: _reportsKey),
                  ProfileScreen(key: _profileKey),
                ],
              ),
              if (_activeBanner != null)
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: _buildMonthBanner(_activeBanner!),
                ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
          floatingActionButton: FloatingActionButton(
            key: _fabKey,
            backgroundColor: _primary,
            elevation: 4,
            tooltip: 'Chat with BachatBot',
            onPressed: () {
              if (_tourActive && _tourStep == 3) _tourAdvance();
              _openChat();
            },
            child: const Icon(Icons.smart_toy_outlined, color: Colors.white),
          ),
          bottomNavigationBar: BottomAppBar(
            key: _bottomNavKey,
            shape: const CircularNotchedRectangle(),
            notchMargin: 10,
            color: Colors.white,
            elevation: 8,
            padding: EdgeInsets.zero,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _navBarItem(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home', index: 0),
                _navBarItem(icon: Icons.grid_view_outlined, activeIcon: Icons.grid_view, label: 'Categories', index: 1),
                const SizedBox(width: 48), // room for the docked FAB's notch
                _navBarItem(icon: Icons.insert_chart_outlined, activeIcon: Icons.insert_chart, label: 'Reports', index: 2),
                _navBarItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'Profile', index: 3),
              ],
            ),
          ),
        ),

        // ── Spotlight tour overlay ────────────────────────────────────────
        if (_tourActive)
          FadeTransition(
            opacity: _tourFadeAnim,
            child: _buildTourOverlay(context),
          ),
      ],
    );
  }

  void _onNavTap(int i) {
    setState(() => _currentIndex = i);
    // Tour advancement for nav items
    if (_tourActive) {
      if (_tourStep == 2 && i == 1) Future.delayed(const Duration(milliseconds: 150), _tourAdvance);
      if (_tourStep == 4 && i == 2) Future.delayed(const Duration(milliseconds: 150), _tourAdvance);
      if (_tourStep == 5 && i == 3) Future.delayed(const Duration(milliseconds: 150), _tourAdvance);
    }
    if (i == 0) { _homeKey.currentState?.refresh(); }
    else if (i == 1) { _categoriesKey.currentState?.refresh(); }
    else if (i == 2) { _reportsKey.currentState?.refresh(); }
    else if (i == 3) { _profileKey.currentState?.refresh(); }
  }

  Widget _navBarItem({
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required int index,
  }) {
    final selected = _currentIndex == index;
    final color = selected ? _primary : Colors.grey;
    return InkWell(
      onTap: () => _onNavTap(index),
      customBorder: const RoundedRectangleBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected ? activeIcon : icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  // ── Tour overlay ──────────────────────────────────────────────────────────

  Widget _buildTourOverlay(BuildContext context) {
    final step      = _tourSteps[_tourStep];
    final spotlight = _spotlightRect(context);
    final size      = MediaQuery.of(context).size;

    // Position tour card above spotlight when spotlight is in the lower half
    final bool spotlightIsLow =
        spotlight != null && spotlight.top > size.height * 0.55;
    final double cardBottom =
        spotlightIsLow ? (size.height - spotlight.top + 12) : 90;

    return Stack(
      children: [
        // Dark overlay with spotlight hole — IgnorePointer so real widgets work
        IgnorePointer(
          child: CustomPaint(
            size: size,
            painter: _SpotlightPainter(spotlight: spotlight, pulse: _pulseAnim.value),
          ),
        ),

        // Pulsing ring around spotlight — purely decorative
        if (spotlight != null)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _pulseAnim,
              builder: (_, __) => CustomPaint(
                size: size,
                painter: _SpotlightPainter(spotlight: spotlight, pulse: _pulseAnim.value),
              ),
            ),
          ),

        // Tour card
        Positioned(
          left: 16,
          right: 16,
          bottom: cardBottom,
          child: Material(
            color: Colors.transparent,
            child: _buildTourCard(step, spotlight, size),
          ),
        ),
      ],
    );
  }

  Widget _buildTourCard(_TourStep step, Rect? spotlight, Size screenSize) {
    final isLast = _tourStep == _tourSteps.length - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _primary.withValues(alpha: 0.22), width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 32, offset: const Offset(0, 12)),
          BoxShadow(color: _primary.withValues(alpha: 0.10), blurRadius: 16, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Progress dots + counter + skip
          Row(
            children: [
              ...List.generate(_tourSteps.length, (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: i == _tourStep ? 20 : 6,
                height: 6,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: i == _tourStep ? _primary : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(3),
                ),
              )),
              const SizedBox(width: 8),
              Text(
                '${_tourStep + 1} / ${_tourSteps.length}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400, fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _tourFinish,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
                  child: Text('Skip', style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.w500)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Icon + title
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_primary.withValues(alpha: 0.15), _primary.withValues(alpha: 0.06)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(step.icon, color: _primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  step.title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87, height: 1.3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          Text(step.body, style: const TextStyle(fontSize: 13.5, color: Colors.black54, height: 1.55)),

          // "Tap the highlighted element" hint
          if (step.targetType != _TargetType.none) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, __) => Icon(
                    Icons.touch_app_outlined,
                    size: 14,
                    color: _primary.withValues(alpha: 0.5 + 0.5 * _pulseAnim.value),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  'Tap the highlighted area above',
                  style: TextStyle(fontSize: 11.5, color: _primary.withValues(alpha: 0.75), fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],

          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _tourAdvance,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
              ),
              child: Text(
                isLast ? "Let's Go! 🚀" : 'Next  →',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Month event banner ────────────────────────────────────────────────────

  Widget _buildMonthBanner(MonthEvent event) {
    final isPreMonth  = event.type == MonthEventType.preNewMonth;
    final bannerColor = isPreMonth ? const Color(0xFF4F6CFF) : _primary;
    final title = isPreMonth ? 'Naya mahina aaudaichha' : 'Naya mahina suru bhayo!';
    final body  = isPreMonth
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
          boxShadow: [BoxShadow(color: bannerColor.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: Row(
          children: [
            Icon(isPreMonth ? Icons.calendar_month_outlined : Icons.celebration_outlined, color: Colors.white, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(body, style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 12)),
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

// ── Spotlight painter ─────────────────────────────────────────────────────────

class _SpotlightPainter extends CustomPainter {
  final Rect? spotlight;
  final double pulse; // 0.0–1.0 for pulsing ring

  const _SpotlightPainter({this.spotlight, this.pulse = 0});

  @override
  void paint(Canvas canvas, Size size) {
    // Dark overlay with evenOdd cutout
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    if (spotlight != null) {
      final padded = spotlight!.inflate(10);
      path.addRRect(RRect.fromRectAndRadius(padded, const Radius.circular(18)));
      path.fillType = PathFillType.evenOdd;
    }

    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.62));

    // Green pulsing border around spotlight
    if (spotlight != null) {
      final ringInflate = 10.0 + 5.0 * pulse;
      final borderPaint = Paint()
        ..color = const Color(0xFF2DBE7F).withValues(alpha: 0.55 + 0.35 * pulse)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawRRect(
        RRect.fromRectAndRadius(spotlight!.inflate(ringInflate), const Radius.circular(20)),
        borderPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.spotlight != spotlight || old.pulse != pulse;
}

// ── Data classes ──────────────────────────────────────────────────────────────

enum _TargetType { none, eyeIcon, navCategories, navReports, navProfile, fab }

class _TourStep {
  final IconData  icon;
  final String    title;
  final String    body;
  final _TargetType targetType;

  const _TourStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.targetType,
  });
}
