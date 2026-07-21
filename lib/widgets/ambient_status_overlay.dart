import 'package:flutter/material.dart';
import '../services/health_theme_service.dart';
import '../theme/health_theme.dart';

/// A subtle, smoky vignette painted above every screen (via MaterialApp's
/// `builder`), signaling overall financial health without touching any
/// individual screen's Scaffold. Ignores touches — purely atmospheric.
///
/// Phase 13.5 — now driven by the real Health Engine status
/// (HealthThemeService), not the old budget-percentage proxy. Green has
/// no overlay at all (calm reads better as the absence of a mood layer
/// than as a green wash); amber/red keep the same smoky, desaturated
/// haze this widget already had — never a flat saturated color block.
class AmbientStatusOverlay extends StatelessWidget {
  const AmbientStatusOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: HealthThemeService.status,
      builder: (context, status, _) {
        final theme = HealthTheme.forStatus(status);
        if (theme.backgroundTintTop == null) return const SizedBox.shrink();

        final bool isDanger = status == 'red';

        return IgnorePointer(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 700),
            opacity: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    theme.backgroundTintTop!.withValues(alpha: isDanger ? 0.22 : 0.16),
                    theme.backgroundTintBottom!.withValues(alpha: isDanger ? 0.30 : 0.22),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
