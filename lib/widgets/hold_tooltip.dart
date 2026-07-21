import 'package:flutter/material.dart';

/// The mobile equivalent of "hover to see what this means" — press and
/// hold to reveal a short explanation bubble right above the finger;
/// lift off and it disappears. No extra taps, nothing left on screen
/// once released.
class HoldTooltip extends StatefulWidget {
  final Widget child;
  final String message;

  const HoldTooltip({super.key, required this.child, required this.message});

  @override
  State<HoldTooltip> createState() => _HoldTooltipState();
}

class _HoldTooltipState extends State<HoldTooltip> {
  OverlayEntry? _entry;
  final LayerLink _link = LayerLink();

  void _show(BuildContext context) {
    _entry?.remove();
    _entry = OverlayEntry(
      builder: (context) => Positioned(
        width: 220,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -8),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2E35),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))],
              ),
              child: Text(
                widget.message,
                style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.35),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: GestureDetector(
        onLongPressStart: (_) => _show(context),
        onLongPressEnd: (_) => _hide(),
        onLongPressCancel: _hide,
        child: widget.child,
      ),
    );
  }
}
