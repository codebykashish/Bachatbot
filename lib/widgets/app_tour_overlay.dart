import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A simple first-time user guide overlay.
/// Wraps the home screen content and shows a sequential spotlight tour
/// when [showTour] is true and SharedPreferences 'tour_done' is not set.
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
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _tourActive = false;
  int _step = 0;
  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  static const List<_TourStep> _steps = [
    _TourStep(
      icon: Icons.dashboard_outlined,
      title: 'Your Dashboard',
      description:
          'Welcome! This is your financial hub — see your savings, income, and expenses at a glance.',
      arrowDirection: ArrowDirection.none,
    ),
    _TourStep(
      icon: Icons.visibility_off_outlined,
      title: 'Hide Your Amounts',
      description:
          'Tap the eye icon (top right of the summary) to show or hide your amounts for privacy.',
      arrowDirection: ArrowDirection.up,
    ),
    _TourStep(
      icon: Icons.grid_view_outlined,
      title: 'Category Budgets',
      description:
          'Scroll down to see your spending categories. Tap any category to set a budget or log an expense.',
      arrowDirection: ArrowDirection.down,
    ),
    _TourStep(
      icon: Icons.insert_chart_outlined,
      title: 'Monthly Reports',
      description:
          'Your spending chart is just below. Tap "View Full" to see detailed monthly reports and insights.',
      arrowDirection: ArrowDirection.down,
    ),
    _TourStep(
      icon: Icons.smart_toy_outlined,
      title: 'Chat to Track',
      description:
          'Tap the green chat button (bottom right) anytime to log an expense or income just by typing!',
      arrowDirection: ArrowDirection.downRight,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut);
    if (widget.showTour) {
      _checkAndStartTour();
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkAndStartTour() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('tour_done') ?? false;
    if (!done && mounted) {
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) {
        setState(() => _tourActive = true);
        _animCtrl.forward();
      }
    }
  }

  Future<void> _completeTour() async {
    await _animCtrl.reverse();
    setState(() => _tourActive = false);
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
        // Semi-transparent overlay
        FadeTransition(
          opacity: _fadeAnim,
          child: GestureDetector(
            onTap: _nextStep,
            child: Container(color: Colors.black.withValues(alpha: 0.6)),
          ),
        ),
        // Tour card — anchored at bottom
        Positioned(
          left: 16,
          right: 16,
          bottom: 90,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: _buildTourCard(step),
          ),
        ),
      ],
    );
  }

  Widget _buildTourCard(_TourStep step) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Step indicator + skip
            Row(
              children: [
                Row(
                  children: List.generate(_steps.length, (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: i == _step ? 18 : 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: i == _step ? _primary : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  )),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _completeTour,
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  child: const Text('Skip', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Icon + title
            Row(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(step.icon, color: _primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    step.title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              step.description,
              style: const TextStyle(fontSize: 13, color: Colors.black54, height: 1.5),
            ),
            const SizedBox(height: 16),
            // Direction hint
            if (step.arrowDirection != ArrowDirection.none)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(_arrowIcon(step.arrowDirection), size: 16, color: Colors.grey.shade400),
                    const SizedBox(width: 4),
                    Text(
                      _arrowLabel(step.arrowDirection),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                  ],
                ),
              ),
            // Next button
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _nextStep,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  _step == _steps.length - 1 ? 'Got it! 🎉' : 'Next  →',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _arrowIcon(ArrowDirection dir) {
    switch (dir) {
      case ArrowDirection.up:
        return Icons.arrow_upward;
      case ArrowDirection.down:
        return Icons.arrow_downward;
      case ArrowDirection.downRight:
        return Icons.south_east;
      default:
        return Icons.arrow_forward;
    }
  }

  String _arrowLabel(ArrowDirection dir) {
    switch (dir) {
      case ArrowDirection.up:
        return 'Look at the top of the screen';
      case ArrowDirection.down:
        return 'Scroll down to see it';
      case ArrowDirection.downRight:
        return 'Check the bottom-right corner';
      default:
        return '';
    }
  }
}

enum ArrowDirection { none, up, down, downRight }

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
