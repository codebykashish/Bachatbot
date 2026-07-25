import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// First-time user guide overlay.
/// When [showTour] is true (coming from onboarding), resets the done-flag and
/// always shows the tour, so new accounts always see the guide.
class AppTourOverlay extends StatefulWidget {
  final Widget child;
  final bool showTour;

  const AppTourOverlay({
    super.key,
    required this.child,
    this.showTour = false,
  });

  @override
  State<AppTourOverlay> createState() => _AppTourOverlayState();
}

class _AppTourOverlayState extends State<AppTourOverlay>
    with TickerProviderStateMixin {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _tourActive = false;
  int _step = 0;
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;
  late AnimationController _bounceCtrl;
  late Animation<double> _bounceAnim;

  static const List<_TourStep> _steps = [
    _TourStep(
      icon: Icons.waving_hand_outlined,
      title: 'Welcome to BachatBot!',
      description:
          'This is your financial dashboard — income, expenses, and savings all in one place. Let us show you around in 4 quick steps.',
      arrowDirection: ArrowDirection.none,
    ),
    _TourStep(
      icon: Icons.account_balance_wallet_outlined,
      title: 'Step 1 — Set your income',
      description:
          'Scroll down on this screen to find the Income card. Tap it to enter how much money you have this month. Budgets and savings depend on this.',
      arrowDirection: ArrowDirection.down,
    ),
    _TourStep(
      icon: Icons.grid_view_outlined,
      title: 'Step 2 — Set category budgets',
      description:
          'Tap the Categories tab in the navigation bar below. Add a monthly spending limit for Food, Transport, Shopping, and more.',
      arrowDirection: ArrowDirection.downLeft,
    ),
    _TourStep(
      icon: Icons.smart_toy_outlined,
      title: 'Step 3 — Log expenses by chat',
      description:
          'Tap the green robot button at the bottom right. Just type: "Momo 250" or "Bus 40" — BachatBot saves it instantly. No forms needed.',
      arrowDirection: ArrowDirection.downRight,
    ),
    _TourStep(
      icon: Icons.insert_chart_outlined,
      title: 'Step 4 — Check your reports',
      description:
          'Tap the Reports tab to see your monthly income, total expenses, and net savings — with a clear Low / Medium / High spending status.',
      arrowDirection: ArrowDirection.downCenter,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);

    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _bounceAnim = CurvedAnimation(parent: _bounceCtrl, curve: Curves.easeInOut);

    if (widget.showTour) {
      _checkAndStartTour();
    }
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _bounceCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkAndStartTour() async {
    final prefs = await SharedPreferences.getInstance();
    // Coming straight from onboarding — always show the tour for this fresh account
    if (widget.showTour) {
      await prefs.setBool('tour_done', false);
    }
    final done = prefs.getBool('tour_done') ?? false;
    if (!done && mounted) {
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) {
        setState(() => _tourActive = true);
        _fadeCtrl.forward();
      }
    }
  }

  Future<void> _completeTour() async {
    await _fadeCtrl.reverse();
    if (mounted) setState(() => _tourActive = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tour_done', true);
  }

  void _nextStep() {
    if (_step < _steps.length - 1) {
      setState(() => _step++);
    } else {
      _completeTour();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_tourActive) return widget.child;

    final step = _steps[_step];

    return Stack(
      children: [
        widget.child,
        // Semi-transparent overlay — keep it lighter so the UI is visible
        FadeTransition(
          opacity: _fadeAnim,
          child: GestureDetector(
            onTap: _nextStep,
            child: Container(color: Colors.black.withValues(alpha: 0.50)),
          ),
        ),
        // Bouncing direction arrow
        if (step.arrowDirection != ArrowDirection.none)
          _buildBouncingArrow(step.arrowDirection),
        // Tour card
        Positioned(
          left: 16,
          right: 16,
          bottom: 96,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: _buildTourCard(step),
          ),
        ),
      ],
    );
  }

  Widget _buildBouncingArrow(ArrowDirection dir) {
    final alignment = _arrowAlignment(dir);
    final icon = _arrowIcon(dir);

    return Positioned.fill(
      child: FadeTransition(
        opacity: _fadeAnim,
        child: Align(
          alignment: alignment,
          child: Padding(
            padding: _arrowPadding(dir),
            child: AnimatedBuilder(
              animation: _bounceAnim,
              builder: (_, __) {
                final offset = _bounceOffset(dir, _bounceAnim.value);
                return Transform.translate(
                  offset: offset,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.90),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _primary.withValues(alpha: 0.45),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(icon, color: Colors.white, size: 22),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Alignment _arrowAlignment(ArrowDirection dir) {
    switch (dir) {
      case ArrowDirection.down:
        return Alignment.bottomCenter;
      case ArrowDirection.downLeft:
        return Alignment.bottomLeft;
      case ArrowDirection.downRight:
        return Alignment.bottomRight;
      case ArrowDirection.downCenter:
        return Alignment.bottomCenter;
      default:
        return Alignment.bottomCenter;
    }
  }

  EdgeInsets _arrowPadding(ArrowDirection dir) {
    switch (dir) {
      case ArrowDirection.downLeft:
        return const EdgeInsets.only(left: 60, bottom: 165);
      case ArrowDirection.downRight:
        return const EdgeInsets.only(right: 16, bottom: 165);
      case ArrowDirection.downCenter:
        return const EdgeInsets.only(bottom: 165);
      default:
        return const EdgeInsets.only(bottom: 165);
    }
  }

  Offset _bounceOffset(ArrowDirection dir, double t) {
    final dy = 8.0 * t;
    switch (dir) {
      case ArrowDirection.downLeft:
        return Offset(-4.0 * t, dy);
      case ArrowDirection.downRight:
        return Offset(4.0 * t, dy);
      default:
        return Offset(0, dy);
    }
  }

  IconData _arrowIcon(ArrowDirection dir) {
    switch (dir) {
      case ArrowDirection.downLeft:
        return Icons.south_west;
      case ArrowDirection.downRight:
        return Icons.south_east;
      default:
        return Icons.arrow_downward;
    }
  }

  Widget _buildTourCard(_TourStep step) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _primary.withValues(alpha: 0.20), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: _primary.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Step dots + counter + skip
            Row(
              children: [
                Row(
                  children: List.generate(_steps.length, (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: i == _step ? 20 : 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: i == _step ? _primary : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  )),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_step + 1} / ${_steps.length}',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade400,
                      fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _completeTour,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Skip',
                      style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
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
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _primary.withValues(alpha: 0.15),
                        _primary.withValues(alpha: 0.06),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(step.icon, color: _primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    step.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              step.description,
              style: const TextStyle(
                  fontSize: 13.5, color: Colors.black54, height: 1.55),
            ),
            const SizedBox(height: 16),
            // Next / Done button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _nextStep,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13)),
                ),
                child: Text(
                  _step == _steps.length - 1 ? "Let's Go! 🚀" : 'Next  →',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum ArrowDirection { none, down, downLeft, downRight, downCenter }

class _TourStep {
  final IconData icon;
  final String title;
  final String description;
  final ArrowDirection arrowDirection;

  const _TourStep({
    required this.icon,
    required this.title,
    required this.description,
    required this.arrowDirection,
  });
}
