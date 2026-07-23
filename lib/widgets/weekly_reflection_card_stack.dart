import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../theme/health_theme.dart';
import '../screens/goals_screen.dart';

/// Maps a backend `type`/`recommendationCode` to a real symbol + a short
/// label -- the backend deliberately tags every highlight/concern/pattern
/// with a `type` "for the UI's own icon/color choice" (see
/// weekly_reflection_service.py's compose_weekly_reflection docstring).
/// This is that choice: a specific icon per meaning, not one generic
/// emoji reused for every card of a given section.
class _TypeMeta {
  final IconData icon;
  final String label;
  const _TypeMeta(this.icon, this.label);
}

const Map<String, _TypeMeta> _typeMeta = {
  'HEALTH_IMPROVED': _TypeMeta(Icons.trending_up_rounded, 'Health improved'),
  'MEANINGFUL_STREAK': _TypeMeta(Icons.local_fire_department_rounded, 'Streak'),
  'CATEGORY_WITHIN_BUDGET': _TypeMeta(Icons.shield_rounded, 'Under budget'),
  'HEALTH_WORSENED': _TypeMeta(Icons.trending_down_rounded, 'Health dipped'),
  'CATEGORY_HIGH_USAGE': _TypeMeta(Icons.speed_rounded, 'Nearing limit'),
  'LOW_ACTIVITY': _TypeMeta(Icons.nightlight_round, 'Quiet week'),
  'UNUSUAL_SPENDING': _TypeMeta(Icons.search_rounded, 'Unusual pattern'),
  'GOAL_AT_RISK': _TypeMeta(Icons.flag_rounded, 'Goal at risk'),
  'GOAL_ON_TRACK': _TypeMeta(Icons.flag_circle_rounded, 'Goal on track'),
  'STOP_CATEGORY_SPENDING': _TypeMeta(Icons.block_rounded, 'Pause spending'),
  'REDUCE_CATEGORY_SPENDING': _TypeMeta(Icons.trending_down_rounded, 'Ease up'),
  'REVIEW_MULTIPLE_CATEGORIES': _TypeMeta(Icons.view_agenda_rounded, 'Review'),
  'MONITOR_CATEGORY_SPENDING': _TypeMeta(Icons.visibility_rounded, 'Keep watching'),
  'SLOW_SPENDING_PACE': _TypeMeta(Icons.speed_rounded, 'Slow the pace'),
  'INCREASE_GOAL_CONTRIBUTION': _TypeMeta(Icons.savings_rounded, 'Boost goal'),
  'KEEP_CURRENT_HABITS': _TypeMeta(Icons.check_circle_rounded, 'Stay the course'),
};

_TypeMeta _metaFor(String? type, IconData fallbackIcon, String fallbackLabel) =>
    _typeMeta[type] ?? _TypeMeta(fallbackIcon, fallbackLabel);

class _ReflectionCard {
  final IconData icon;
  final String label;
  final String text;
  final HealthTheme theme;
  final bool showGoalButton;

  const _ReflectionCard({
    required this.icon,
    required this.label,
    required this.text,
    required this.theme,
    this.showGoalButton = false,
  });
}

/// "Your Week in Money" as a swipeable stack of cards, in a popup -- not
/// a separate page. Each card leads with a symbol (a specific icon for
/// what it means, not a generic emoji) and a short label; the composed
/// sentence is supporting detail underneath, not the headline. Swiping
/// (or the chevrons) moves forward and back through the stack.
class WeeklyReflectionCardStack extends StatefulWidget {
  final Map<String, dynamic> reflection;

  const WeeklyReflectionCardStack({super.key, required this.reflection});

  @override
  State<WeeklyReflectionCardStack> createState() => _WeeklyReflectionCardStackState();
}

class _WeeklyReflectionCardStackState extends State<WeeklyReflectionCardStack> {
  static const Color _primary = Color(0xFF2DBE7F);

  late final PageController _pageController;
  late final List<_ReflectionCard> _cards;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _cards = _buildCards();
    _pageController = PageController(viewportFraction: 0.82);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  List<_ReflectionCard> _buildCards() {
    final r = widget.reflection;
    final highlights = (r['highlights'] as List?) ?? [];
    final concerns = (r['concerns'] as List?) ?? [];
    final pattern = r['pattern'] as Map<String, dynamic>?;
    final goalContext = r['goalContext'] as Map<String, dynamic>?;
    final nextStep = r['nextStep'] as Map<String, dynamic>?;

    final green = HealthTheme.forStatus('green');
    final amber = HealthTheme.forStatus('amber');

    final cards = <_ReflectionCard>[];

    for (final h in highlights) {
      final map = h as Map<String, dynamic>;
      final text = map['text'] as String?;
      if (text != null && text.isNotEmpty) {
        final meta = _metaFor(map['type'] as String?, Icons.auto_awesome_rounded, 'Went well');
        cards.add(_ReflectionCard(icon: meta.icon, label: meta.label, text: text, theme: green));
      }
    }
    for (final c in concerns) {
      final map = c as Map<String, dynamic>;
      final text = map['text'] as String?;
      if (text != null && text.isNotEmpty) {
        final meta = _metaFor(map['type'] as String?, Icons.visibility_rounded, 'Worth watching');
        cards.add(_ReflectionCard(icon: meta.icon, label: meta.label, text: text, theme: amber));
      }
    }
    if (pattern != null) {
      final text = pattern['text'] as String?;
      if (text != null && text.isNotEmpty) {
        final meta = _metaFor(pattern['type'] as String?, Icons.search_rounded, 'We noticed');
        cards.add(_ReflectionCard(icon: meta.icon, label: meta.label, text: text, theme: amber));
      }
    }
    if (goalContext != null) {
      final text = goalContext['text'] as String?;
      if (text != null && text.isNotEmpty) {
        final type = goalContext['type'] as String?;
        final meta = _metaFor(type, Icons.flag_rounded, 'Your goal');
        cards.add(_ReflectionCard(
          icon: meta.icon,
          label: meta.label,
          text: text,
          theme: type == 'GOAL_AT_RISK' ? amber : green,
          showGoalButton: true,
        ));
      }
    }
    if (nextStep != null) {
      final text = nextStep['text'] as String?;
      if (text != null && text.isNotEmpty) {
        final meta = _metaFor(nextStep['recommendationCode'] as String?, Icons.lightbulb_rounded, 'Next step');
        cards.add(_ReflectionCard(icon: meta.icon, label: meta.label, text: text, theme: green));
      }
    }

    if (cards.isEmpty) {
      final opening = (r['opening'] as String?) ?? "Here's what stood out about your money this week.";
      cards.add(_ReflectionCard(icon: Icons.menu_book_rounded, label: 'This week', text: opening, theme: green));
    }

    return cards;
  }

  void _goTo(int page) {
    HapticFeedback.selectionClick();
    _pageController.animateToPage(page, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final opening = widget.reflection['opening'] as String?;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(width: 20),
                const Text('📖', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Your Week in Money', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: Colors.grey.shade500,
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
              ],
            ),
            if (opening != null && opening.isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  opening,
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600, height: 1.4),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              height: 320,
              child: PageView.builder(
                controller: _pageController,
                itemCount: _cards.length,
                onPageChanged: (i) {
                  HapticFeedback.selectionClick();
                  setState(() => _currentPage = i);
                },
                itemBuilder: (context, i) {
                  return AnimatedBuilder(
                    animation: _pageController,
                    builder: (context, child) {
                      double delta = (_currentPage - i).toDouble();
                      if (_pageController.position.haveDimensions) {
                        delta = (_pageController.page ?? _currentPage.toDouble()) - i;
                      }
                      final scale = (1 - delta.abs() * 0.14).clamp(0.86, 1.0);
                      final fade = (1 - delta.abs() * 0.45).clamp(0.45, 1.0);
                      return Center(
                        child: Opacity(
                          opacity: fade,
                          child: Transform.scale(scale: scale, child: child),
                        ),
                      );
                    },
                    child: _buildCard(_cards[i]),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _currentPage > 0 ? () => _goTo(_currentPage - 1) : null,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
                  color: _currentPage > 0 ? _primary : Colors.grey.shade300,
                ),
                ...List.generate(_cards.length, (i) {
                  final active = i == _currentPage;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: active ? 20 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: active ? _primary : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
                IconButton(
                  onPressed: _currentPage < _cards.length - 1 ? () => _goTo(_currentPage + 1) : null,
                  icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                  color: _currentPage < _cards.length - 1 ? _primary : Colors.grey.shade300,
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(_ReflectionCard card) {
    final deepAccent = Color.lerp(card.theme.accent, Colors.black, 0.28)!;

    return Container(
      width: 250,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      padding: const EdgeInsets.fromLTRB(22, 30, 22, 26),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [card.theme.accent, deepAccent],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: card.theme.accent.withValues(alpha: 0.45), blurRadius: 28, offset: const Offset(0, 14)),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // A large, faint version of the same icon watermarked in the
          // corner -- decorative depth, not competing with the real one.
          Positioned(
            right: -18,
            bottom: -14,
            child: Icon(card.icon, size: 110, color: Colors.white.withValues(alpha: 0.08)),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Icon(card.icon, color: Colors.white, size: 30),
              ),
              const SizedBox(height: 16),
              Text(
                card.label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.2),
              ),
              const SizedBox(height: 10),
              Text(
                card.text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.88), height: 1.4, fontWeight: FontWeight.w500),
              ),
              if (card.showGoalButton) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GoalsScreen())),
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('View Goal', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
