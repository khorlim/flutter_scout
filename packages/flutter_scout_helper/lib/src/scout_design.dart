part of 'flutter_scout_binding.dart';

// part: Scout design system — "Recon HUD".
//
// Scout floats over an arbitrary running app, so its chrome must read on any
// background and look unmistakably like *tooling*, not part of the app. The
// language is a heads-up display: dark translucent "glass" panels, a hairline
// luminous border, a soft outer glow instead of Material drop shadows, a single
// signal-cyan accent (with amber for review / rose for danger), tracked
// uppercase micro-labels, and monospace numerals.
//
// Tokens are fixed (not theme-derived) on purpose: Scout looks identical over a
// light app, a dark app, or no app. See docs/scout-design-system.md.
//
// Build new Scout overlay UI from these tokens + the ScoutPanel/ScoutButton/
// ScoutPill primitives below. Do NOT reach for raw Material widgets or
// Theme.of(context) for Scout chrome.

/// Color tokens. Alpha is encoded in the hex (0xAARRGGBB).
abstract final class ScoutColors {
  /// Panel fill — near-opaque deep teal-black "glass".
  static const glass = Color(0xF20B1211);

  /// Slightly lighter inset fill (inputs, wells).
  static const glassRaised = Color(0xF2122220);

  /// Hairline border on glass — cyan at low alpha.
  static const border = Color(0x3357EFE2);

  /// Primary text on glass.
  static const ink = Color(0xFFE9F6F4);

  /// Secondary / supporting text.
  static const inkDim = Color(0xFF8DA8A4);

  /// Primary accent — "signal" cyan. Open annotations, primary actions, focus.
  static const signal = Color(0xFF35E6D4);

  /// Signal at low alpha — glows and tinted fills.
  static const signalGlow = Color(0x4035E6D4);

  /// Text/icon sitting on a solid [signal] fill.
  static const onSignal = Color(0xFF03201C);

  /// Review state (pending_review pins, review accents).
  static const amber = Color(0xFFFFC24B);

  /// Danger / destructive / stale.
  static const rose = Color(0xFFFF6079);

  /// Capture scrim — intentionally barely-there.
  static const scrim = Color(0x14060B0A);

  /// Returns the accent for an annotation [status].
  static Color forStatus(String status) => switch (status) {
    'pending_review' => amber,
    'stale_target' => rose,
    _ => signal,
  };
}

/// 4-based spacing scale.
abstract final class ScoutSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
}

/// Corner radii.
abstract final class ScoutRadius {
  static const panel = 14.0;
  static const control = 10.0;
  static const pill = 999.0;
}

/// Type ramp. Tight tracking; uppercase micro-labels; tabular numerals.
abstract final class ScoutType {
  static const label = TextStyle(
    decoration: TextDecoration.none,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
    height: 1.0,
    color: ScoutColors.ink,
  );
  static const title = TextStyle(
    decoration: TextDecoration.none,
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
    height: 1.1,
    color: ScoutColors.ink,
  );
  static const body = TextStyle(
    decoration: TextDecoration.none,
    fontSize: 14,
    height: 1.35,
    letterSpacing: 0.1,
    color: ScoutColors.ink,
  );
  static const meta = TextStyle(
    decoration: TextDecoration.none,
    fontSize: 11.5,
    letterSpacing: 0.4,
    height: 1.2,
    color: ScoutColors.inkDim,
  );
  static const numeral = TextStyle(
    decoration: TextDecoration.none,
    fontSize: 12.5,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.5,
    fontFeatures: [FontFeature.tabularFigures()],
    color: ScoutColors.ink,
  );
}

/// Motion tokens — confident, snappy HUD feel.
abstract final class ScoutMotion {
  static const fast = Duration(milliseconds: 130);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 340);

  /// Entrances: decelerate in.
  static const enter = Curves.easeOutCubic;

  /// Exits: accelerate out.
  static const exit = Curves.easeInCubic;

  /// Signature "pop" for pins/markers — slight overshoot.
  static const pop = Curves.easeOutBack;
}

/// A glow + hairline border decoration for glass surfaces, optionally tinted by
/// an [accent] (defaults to the cyan signal glow).
BoxDecoration scoutGlass({
  double radius = ScoutRadius.panel,
  Color fill = ScoutColors.glass,
  Color? accent,
}) {
  final glow = accent == null
      ? ScoutColors.signalGlow
      : accent.withValues(alpha: 0.28);
  final edge = accent == null
      ? ScoutColors.border
      : accent.withValues(alpha: 0.55);
  return BoxDecoration(
    color: fill,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: edge, width: 1),
    boxShadow: [
      BoxShadow(color: glow, blurRadius: 22, spreadRadius: -6),
      const BoxShadow(color: Color(0x55000000), blurRadius: 14, spreadRadius: -8),
    ],
  );
}

/// A HUD glass surface: fill + hairline border + soft glow + corner ticks.
class ScoutPanel extends StatelessWidget {
  const ScoutPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(ScoutSpace.m),
    this.radius = ScoutRadius.panel,
    this.accent,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: scoutGlass(radius: radius, accent: accent),
      child: CustomPaint(
        painter: _ScoutCornerTicksPainter(
          color: (accent ?? ScoutColors.signal).withValues(alpha: 0.7),
          radius: radius,
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Small L-shaped reticle ticks just inside each corner — the HUD signature.
class _ScoutCornerTicksPainter extends CustomPainter {
  const _ScoutCornerTicksPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const inset = 7.0;
    const len = 9.0;
    final i = inset + radius * 0.25;
    // top-left
    canvas.drawLine(Offset(i, i), Offset(i + len, i), paint);
    canvas.drawLine(Offset(i, i), Offset(i, i + len), paint);
    // top-right
    canvas.drawLine(Offset(size.width - i, i), Offset(size.width - i - len, i), paint);
    canvas.drawLine(Offset(size.width - i, i), Offset(size.width - i, i + len), paint);
    // bottom-left
    canvas.drawLine(Offset(i, size.height - i), Offset(i + len, size.height - i), paint);
    canvas.drawLine(Offset(i, size.height - i), Offset(i, size.height - i - len), paint);
    // bottom-right
    canvas.drawLine(Offset(size.width - i, size.height - i), Offset(size.width - i - len, size.height - i), paint);
    canvas.drawLine(Offset(size.width - i, size.height - i), Offset(size.width - i, size.height - i - len), paint);
  }

  @override
  bool shouldRepaint(_ScoutCornerTicksPainter old) =>
      old.color != color || old.radius != radius;
}

/// Visual weight for a [ScoutButton].
enum ScoutButtonKind { primary, ghost, danger }

/// A HUD button: tracked uppercase label, hairline/solid fill by [kind], and a
/// press-scale (no Material ripple). Use instead of FilledButton/TextButton.
class ScoutButton extends StatefulWidget {
  const ScoutButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = ScoutButtonKind.primary,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final ScoutButtonKind kind;

  @override
  State<ScoutButton> createState() => _ScoutButtonState();
}

class _ScoutButtonState extends State<ScoutButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final accent = switch (widget.kind) {
      ScoutButtonKind.primary => ScoutColors.signal,
      ScoutButtonKind.danger => ScoutColors.rose,
      ScoutButtonKind.ghost => ScoutColors.signal,
    };
    final solid = widget.kind != ScoutButtonKind.ghost;
    final fg = solid ? ScoutColors.onSignal : ScoutColors.ink;
    final decoration = BoxDecoration(
      color: solid ? accent : Colors.transparent,
      borderRadius: BorderRadius.circular(ScoutRadius.control),
      border: Border.all(
        color: solid ? Colors.transparent : ScoutColors.border,
        width: 1,
      ),
      boxShadow: solid
          ? [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 16, spreadRadius: -6)]
          : null,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onPressed,
      child: AnimatedScale(
        scale: _down ? 0.95 : 1.0,
        duration: ScoutMotion.fast,
        curve: ScoutMotion.enter,
        child: AnimatedContainer(
          duration: ScoutMotion.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: ScoutSpace.l,
            vertical: ScoutSpace.s + 2,
          ),
          decoration: decoration,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: fg),
                const SizedBox(width: ScoutSpace.s),
              ],
              Text(widget.label.toUpperCase(), style: ScoutType.label.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A HUD text input — a raised glass well with no Material underline. Requires
/// a Material ancestor (TextField needs one); wrap call sites accordingly.
class ScoutField extends StatelessWidget {
  const ScoutField({
    super.key,
    required this.controller,
    this.hint = 'Comment',
    this.minLines = 2,
    this.maxLines = 4,
  });

  final TextEditingController controller;
  final String hint;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ScoutColors.glassRaised,
        borderRadius: BorderRadius.circular(ScoutRadius.control),
        border: Border.all(color: ScoutColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: ScoutSpace.m,
        vertical: ScoutSpace.s,
      ),
      child: TextField(
        controller: controller,
        autofocus: true,
        minLines: minLines,
        maxLines: maxLines,
        cursorColor: ScoutColors.signal,
        style: ScoutType.body,
        textInputAction: TextInputAction.newline,
        decoration: InputDecoration.collapsed(
          hintText: hint,
          hintStyle: ScoutType.body.copyWith(color: ScoutColors.inkDim),
        ),
      ),
    );
  }
}

/// A draggable HUD pill (the annotation toggle / send-to-agent control): glass
/// stadium, icon, optional numeral count, optional [active]/[accent] emphasis.
class ScoutPill extends StatelessWidget {
  const ScoutPill({
    super.key,
    required this.icon,
    required this.onPressed,
    this.count,
    this.label,
    this.active = false,
    this.accent,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final int? count;
  final String? label;
  final bool active;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? ScoutColors.signal;
    final fg = active ? ScoutColors.onSignal : ScoutColors.ink;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: AnimatedContainer(
        duration: ScoutMotion.base,
        curve: ScoutMotion.enter,
        padding: const EdgeInsets.symmetric(
          horizontal: ScoutSpace.m,
          vertical: ScoutSpace.s + 2,
        ),
        decoration: BoxDecoration(
          color: active ? tint : ScoutColors.glass,
          borderRadius: BorderRadius.circular(ScoutRadius.pill),
          border: Border.all(
            color: active ? Colors.transparent : ScoutColors.border,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: tint.withValues(alpha: active ? 0.45 : 0.22),
              blurRadius: 18,
              spreadRadius: -6,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: fg),
            if (label != null) ...[
              const SizedBox(width: ScoutSpace.s),
              Text(label!.toUpperCase(), style: ScoutType.label.copyWith(color: fg)),
            ],
            if (count != null && count! > 0) ...[
              const SizedBox(width: ScoutSpace.s),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: active
                      ? ScoutColors.onSignal.withValues(alpha: 0.18)
                      : tint.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(ScoutRadius.pill),
                ),
                child: Text('$count', style: ScoutType.numeral.copyWith(color: fg)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
