part of 'flutter_scout_binding.dart';

// part: in-app annotation overlay widgets (toggle + send-to-agent buttons,
// comment panel, target/pin painter) rendered on top of the running app.

/// Instance label injected by the CLI's `--name` flag as
/// `--dart-define=FLUTTER_SCOUT_INSTANCE=<label>`. Empty when unset. Lets
/// several worktree sessions of the same desktop app be told apart on screen.
const String _scoutInstanceLabel = String.fromEnvironment(
  'FLUTTER_SCOUT_INSTANCE',
);

/// Each `--name`d session gets its own hue on the session label's dot, so
/// overlapping worktree runs are told apart at a glance. The hue is a stable
/// hash of the label (same session → same colour across relaunches, no
/// flicker on hot reload); the dot sits on dark glass, so only the hue varies.
final Color _scoutSessionHue = _deriveScoutSessionHue(_scoutInstanceLabel);

Color _deriveScoutSessionHue(String label) {
  // FNV-1a over code units: deterministic across runs and platforms, unlike
  // String.hashCode, so a given name always maps to the same hue.
  var hash = 0x811c9dc5;
  for (final unit in label.codeUnits) {
    hash = (hash ^ unit) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final hue = (hash % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.90, 0.64).toColor();
}

/// The session label: Scout's small glass chip in the bottom-left corner. It
/// names the running session (a per-session hue on its dot tells overlapping
/// worktree runs apart) and shares the driving overlay's look (dark glass,
/// hairline, signal accent, sentence-case type) so the two read as one
/// system. While an agent is attached the dot turns signal-cyan with a halo,
/// matching the edge glow and the "Scout is …" pill. Before an explicit
/// annotation or recording opt-in it is a passive, hit-test-transparent label;
/// afterwards it opens the Scout menu.
///
/// It stays mounted during in-app captures. [hidden] only turns its opacity
/// to zero while a capture that excludes Scout's overlay covers it, so it
/// never rebuilds its animations or blinks for captures elsewhere.
class _ScoutInstanceBadge extends StatelessWidget {
  const _ScoutInstanceBadge({
    super.key,
    required this.hidden,
    required this.menuOpen,
    required this.interactive,
    required this.agentAttached,
    required this.agentControlling,
    required this.onTap,
  });

  final bool hidden;
  final bool menuOpen;
  final bool interactive;
  final ValueListenable<bool> agentAttached;
  final ValueListenable<bool> agentControlling;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: ScoutSpace.s,
      bottom: ScoutSpace.s,
      child: Opacity(opacity: hidden ? 0 : 1, child: _chip()),
    );
  }

  Widget _chip() {
    return IgnorePointer(
      ignoring: !interactive,
      child: ExcludeSemantics(
        excluding: !interactive,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: interactive ? onTap : null,
          child: ListenableBuilder(
            listenable: Listenable.merge([agentAttached, agentControlling]),
            builder: (context, _) {
              final attached = agentAttached.value;
              final controlling = attached && agentControlling.value;
              final dot = attached ? ScoutColors.signal : _scoutSessionHue;
              return AnimatedContainer(
                duration: ScoutMotion.base,
                curve: ScoutMotion.enter,
                height: 26,
                padding: const EdgeInsets.only(left: 9, right: 11),
                decoration: BoxDecoration(
                  color: const Color(0xE60B1211),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: ScoutColors.signal.withValues(
                      alpha: menuOpen ? 0.7 : (attached ? 0.4 : 0.2),
                    ),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 10,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: ScoutMotion.base,
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                        boxShadow: [
                          if (attached)
                            BoxShadow(
                              color: ScoutColors.signal.withValues(alpha: 0.55),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 7),
                    const Text('Scout', style: _badgeTitle),
                    if (_scoutInstanceLabel.isNotEmpty) ...[
                      Text(
                        '  ·  ',
                        style: _badgeName.copyWith(
                          color: ScoutColors.inkDim.withValues(alpha: 0.6),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: const Text(
                          _scoutInstanceLabel,
                          style: _badgeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    // While an agent is attached the label is also the
                    // session indicator: what Scout is doing right now.
                    if (attached) ...[
                      Text(
                        '  ·  ',
                        style: _badgeName.copyWith(
                          color: ScoutColors.inkDim.withValues(alpha: 0.6),
                        ),
                      ),
                      // Both words share one slot as wide as the wider
                      // one, so the chip never changes size; they
                      // cross-fade when the state changes.
                      Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          _stateWord(
                            'controlling',
                            visible: controlling,
                            style: _badgeName.copyWith(
                              color: ScoutColors.signal,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          _stateWord(
                            'observing',
                            visible: !controlling,
                            style: _badgeName,
                          ),
                        ],
                      ),
                    ],
                    if (interactive) ...[
                      const SizedBox(width: 4),
                      // Chevron flips up→down to signal the menu's state.
                      AnimatedRotation(
                        turns: menuOpen ? 0.5 : 0.0,
                        duration: ScoutMotion.base,
                        curve: ScoutMotion.enter,
                        child: const Icon(
                          Icons.keyboard_arrow_up,
                          size: 14,
                          color: ScoutColors.inkDim,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static Widget _stateWord(
    String word, {
    required bool visible,
    required TextStyle style,
  }) {
    return ExcludeSemantics(
      excluding: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: ScoutMotion.fast,
        curve: ScoutMotion.enter,
        child: Text(word, style: style),
      ),
    );
  }

  static const _badgeTitle = TextStyle(
    decoration: TextDecoration.none,
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: ScoutColors.ink,
  );
  static const _badgeName = TextStyle(
    decoration: TextDecoration.none,
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    color: ScoutColors.inkDim,
  );
}

/// The Scout launcher menu: a HUD panel of overlay actions anchored just above
/// the bottom-left launcher. Hosts the annotation toggle and the (scaffold)
/// flow recorder; more Scout tools can slot in as rows here.
class _ScoutMenu extends StatelessWidget {
  const _ScoutMenu({
    required this.annotationActive,
    required this.annotationCount,
    required this.recording,
    required this.onToggleAnnotate,
    required this.onToggleRecord,
  });

  final bool annotationActive;
  final int annotationCount;
  final bool recording;
  final VoidCallback onToggleAnnotate;
  final VoidCallback onToggleRecord;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: ScoutSpace.s,
      bottom: 40,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: ScoutMotion.base,
        curve: ScoutMotion.enter,
        builder: (context, t, child) {
          final v = t.clamp(0.0, 1.0);
          return Opacity(
            opacity: v,
            child: Transform.translate(
              offset: Offset(0, (1 - v) * 8),
              child: Transform.scale(
                scale: 0.96 + 0.04 * v,
                alignment: Alignment.bottomLeft,
                child: child,
              ),
            ),
          );
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 224, maxWidth: 264),
          child: ScoutPanel(
            padding: const EdgeInsets.all(ScoutSpace.s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ScoutSpace.s,
                    ScoutSpace.xs,
                    ScoutSpace.s,
                    ScoutSpace.s,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.my_location,
                        size: 12,
                        color: ScoutColors.signal,
                      ),
                      const SizedBox(width: ScoutSpace.xs),
                      Expanded(
                        child: Text(
                          _scoutInstanceLabel.isEmpty
                              ? 'Scout'
                              : 'Scout · $_scoutInstanceLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ScoutType.meta,
                        ),
                      ),
                    ],
                  ),
                ),
                _ScoutMenuItem(
                  icon: annotationActive
                      ? Icons.my_location
                      : Icons.add_location_alt_outlined,
                  label: 'Annotate',
                  sublabel: annotationActive
                      ? 'Tap a widget to pin a note'
                      : 'Pin review notes on the app',
                  active: annotationActive,
                  trailing: annotationActive
                      ? (annotationCount > 0 ? 'ON · $annotationCount' : 'ON')
                      : 'OFF',
                  onTap: onToggleAnnotate,
                ),
                const SizedBox(height: ScoutSpace.xs),
                _ScoutMenuItem(
                  icon: Icons.fiber_manual_record,
                  label: 'Record',
                  sublabel: recording
                      ? 'Capturing this flow…'
                      : 'Record a replayable flow',
                  active: recording,
                  accent: ScoutColors.rose,
                  trailing: recording ? 'REC' : 'OFF',
                  showPulse: recording,
                  onTap: onToggleRecord,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One tappable row in the [_ScoutMenu]: icon + label/sublabel + a status chip.
/// Tints to [accent] and raises its status chip when [active].
class _ScoutMenuItem extends StatefulWidget {
  const _ScoutMenuItem({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.active,
    required this.trailing,
    required this.onTap,
    this.accent = ScoutColors.signal,
    this.showPulse = false,
  });

  final IconData icon;
  final String label;
  final String sublabel;
  final bool active;
  final String trailing;
  final VoidCallback onTap;
  final Color accent;
  final bool showPulse;

  @override
  State<_ScoutMenuItem> createState() => _ScoutMenuItemState();
}

class _ScoutMenuItemState extends State<_ScoutMenuItem> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final fill = widget.active
        ? accent.withValues(alpha: 0.16)
        : (_down ? ScoutColors.glassRaised : Colors.transparent);
    final border = widget.active
        ? accent.withValues(alpha: 0.55)
        : ScoutColors.border;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: ScoutMotion.fast,
        padding: const EdgeInsets.all(ScoutSpace.s),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(ScoutRadius.control),
          border: Border.all(color: border, width: 1),
        ),
        child: Row(
          children: [
            Icon(
              widget.icon,
              size: 16,
              color: widget.active ? accent : ScoutColors.ink,
            ),
            const SizedBox(width: ScoutSpace.s),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label.toUpperCase(),
                    style: ScoutType.label.copyWith(fontSize: 11),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.sublabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScoutType.meta.copyWith(fontSize: 10),
                  ),
                ],
              ),
            ),
            const SizedBox(width: ScoutSpace.s),
            _ScoutStatusChip(
              label: widget.trailing,
              accent: accent,
              active: widget.active,
              pulse: widget.showPulse,
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact ON/OFF/REC status chip; shows a pulsing dot when [pulse] is set.
class _ScoutStatusChip extends StatelessWidget {
  const _ScoutStatusChip({
    required this.label,
    required this.accent,
    required this.active,
    required this.pulse,
  });

  final String label;
  final Color accent;
  final bool active;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final fg = active ? accent : ScoutColors.inkDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: active
            ? accent.withValues(alpha: 0.16)
            : ScoutColors.glassRaised,
        borderRadius: BorderRadius.circular(ScoutRadius.pill),
        border: Border.all(
          color: active ? accent.withValues(alpha: 0.5) : ScoutColors.border,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pulse) ...[_ScoutRecDot(color: accent), const SizedBox(width: 5)],
          Text(
            label,
            style: ScoutType.numeral.copyWith(fontSize: 10, color: fg),
          ),
        ],
      ),
    );
  }
}

/// A softly pulsing dot used by the recorder status chip.
class _ScoutRecDot extends StatefulWidget {
  const _ScoutRecDot({required this.color});

  final Color color;

  @override
  State<_ScoutRecDot> createState() => _ScoutRecDotState();
}

class _ScoutRecDotState extends State<_ScoutRecDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ScoutMotion.slow,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.55 + 0.45 * t),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5 * t),
                blurRadius: 6,
                spreadRadius: t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The live recorder HUD: a HUD panel pinned top-center while a recording is
/// active, showing a pulsing REC dot, the step count, the last captured step,
/// and inline Pause/Stop controls. Taps on it are excluded from the recording
/// (it lives inside the Scout overlay subtree, which the recorder skips).
class _ScoutRecHud extends StatelessWidget {
  const _ScoutRecHud({
    required this.paused,
    required this.stepCount,
    required this.lastStep,
    required this.onStop,
    required this.onTogglePause,
  });

  final bool paused;
  final int stepCount;
  final String? lastStep;
  final VoidCallback onStop;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final accent = paused ? ScoutColors.amber : ScoutColors.rose;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + ScoutSpace.s,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: ScoutPanel(
            accent: accent,
            padding: const EdgeInsets.symmetric(
              horizontal: ScoutSpace.m,
              vertical: ScoutSpace.s,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (paused)
                  Icon(Icons.pause, size: 12, color: accent)
                else
                  _ScoutRecDot(color: accent),
                const SizedBox(width: ScoutSpace.s),
                Text(
                  paused ? 'PAUSED' : 'REC',
                  style: ScoutType.label.copyWith(fontSize: 11, color: accent),
                ),
                const SizedBox(width: ScoutSpace.s),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$stepCount ${stepCount == 1 ? 'step' : 'steps'}',
                        style: ScoutType.numeral.copyWith(fontSize: 11),
                      ),
                      if (lastStep != null)
                        Text(
                          lastStep!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ScoutType.meta.copyWith(fontSize: 10),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: ScoutSpace.s),
                _ScoutHudButton(
                  icon: paused ? Icons.play_arrow : Icons.pause,
                  onTap: onTogglePause,
                ),
                const SizedBox(width: ScoutSpace.xs),
                _ScoutHudButton(
                  icon: Icons.stop,
                  accent: ScoutColors.rose,
                  filled: true,
                  onTap: onStop,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small square icon button for the REC HUD (Recon-HUD styled, no Material).
class _ScoutHudButton extends StatelessWidget {
  const _ScoutHudButton({
    required this.icon,
    required this.onTap,
    this.accent = ScoutColors.signal,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color accent;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(ScoutRadius.control),
          border: Border.all(
            color: filled ? Colors.transparent : ScoutColors.border,
            width: 1,
          ),
        ),
        child: Icon(
          icon,
          size: 16,
          color: filled ? ScoutColors.onSignal : ScoutColors.ink,
        ),
      ),
    );
  }
}

class _FlutterScoutAnnotationOverlay extends StatefulWidget {
  const _FlutterScoutAnnotationOverlay({required this.runtime});

  final FlutterScoutRuntime runtime;

  @override
  State<_FlutterScoutAnnotationOverlay> createState() =>
      _FlutterScoutAnnotationOverlayState();
}

class _FlutterScoutAnnotationOverlayState
    extends State<_FlutterScoutAnnotationOverlay> {
  final TextEditingController _commentController = TextEditingController();
  ScoutAnnotationTarget? _selectedTarget;
  List<ScoutAnnotationTarget> _currentCandidates = const [];
  List<ScoutAnnotationTarget> _visibleTargets = const [];
  Offset? _toggleButtonOffset;
  Offset? _lastTapPoint;
  int _candidateIndex = 0;
  int _lastCollectedRevision = -1;
  // Keeps the session label mounted across captures and locates it for the
  // overlap check in [_sessionLabelCovered].
  final GlobalKey _sessionLabelKey = GlobalKey(
    debugLabel: 'flutter_scout_session_label',
  );
  bool _targetRefreshScheduled = false;
  // The pin whose delete popup is open (tapped an existing annotation pin).
  // Carries everything the exit ghost needs so it can always animate out even
  // if the live target list shifts before delete.
  ({String id, String comment, Offset at, String status, int number})?
  _selectedPin;
  // Ghost pins animating out after deletion (kept mounted until the exit ends).
  final List<({int ghost, Offset center, String status, int number})>
  _exitingPins = [];
  int _nextGhost = 0;

  // Whether the bottom-left launcher menu is expanded. Pure UI state.
  bool _menuOpen = false;
  bool _passiveMenuCloseScheduled = false;

  // A pin reticle is centered this far in from its target's top-left corner;
  // taps within [_pinHitRadius] of that center open the pin's delete popup.
  static const double _pinAnchorInset = 10;
  static const double _pinHitRadius = 18;

  Offset _pinCenter(Rect rect) =>
      Offset(rect.left + _pinAnchorInset, rect.top + _pinAnchorInset);

  static const double _toggleButtonMargin = 12;
  static const double _toggleButtonHeight = 48;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  void _toggleAnnotationMode() {
    widget.runtime._setAnnotationMode(!widget.runtime._annotationMode);
    if (!widget.runtime._annotationMode) {
      setState(() {
        _selectedTarget = null;
        _currentCandidates = const [];
        _commentController.clear();
        _selectedPin = null;
        _exitingPins.clear();
      });
    }
  }

  void _toggleMenu() => setState(() => _menuOpen = !_menuOpen);

  void _closeMenu() {
    if (_menuOpen) setState(() => _menuOpen = false);
  }

  void _schedulePassiveMenuClose() {
    if (_passiveMenuCloseScheduled) return;
    _passiveMenuCloseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _passiveMenuCloseScheduled = false;
      if (!mounted || !_menuOpen) return;
      setState(() => _menuOpen = false);
    });
  }

  // Menu → Annotate: flip annotation mode (revealing the draggable FAB) and
  // close the menu so the app is free for pin placement.
  void _onMenuAnnotate() {
    _closeMenu();
    _toggleAnnotationMode();
  }

  // Menu → Record: start capture (auto-named) or stop-and-save the active
  // recording. The REC HUD (below) shows live progress + stop control.
  void _onMenuRecord() {
    _closeMenu();
    // Fire-and-forget: start/stop bump the record revision, which repaints the
    // overlay through the annotation revision listener.
    unawaited(widget.runtime.toggleRecording());
  }

  /// Tap router: if the tap lands on an existing annotation pin, open its
  /// delete popup; otherwise start/cycle a new target selection.
  void _handleTap(Offset point) {
    final pins = widget.runtime._annotationPins(_visibleTargets);
    ({Rect rect, String status, String id, String comment})? picked;
    var pickedNumber = 0;
    var bestDistance = _pinHitRadius;
    for (var i = 0; i < pins.length; i++) {
      final distance = (point - _pinCenter(pins[i].rect)).distance;
      if (distance <= bestDistance) {
        bestDistance = distance;
        picked = pins[i];
        pickedNumber = i + 1;
      }
    }
    if (picked != null) {
      final hit = picked;
      final number = pickedNumber;
      setState(() {
        _selectedPin = (
          id: hit.id,
          comment: hit.comment,
          at: _pinCenter(hit.rect),
          status: hit.status,
          number: number,
        );
        _selectedTarget = null;
        _currentCandidates = const [];
        _commentController.clear();
      });
      return;
    }
    if (_selectedPin != null) {
      setState(() => _selectedPin = null);
    }
    _selectAt(point);
  }

  void _deleteSelectedPin() {
    final pin = _selectedPin;
    if (pin == null) return;
    // Spawn a ghost from the data captured when the popup opened, so the exit
    // animation always plays even though removeAnnotation drops the real pin
    // immediately and the live target list may have shifted.
    setState(() {
      _exitingPins.add((
        ghost: _nextGhost++,
        center: pin.at,
        status: pin.status,
        number: pin.number,
      ));
      _selectedPin = null;
    });
    widget.runtime.removeAnnotation(pin.id);
  }

  /// Whether a capture that excludes Scout's overlay covers the session
  /// label, as the pins check their own reticles. The label's box (plus its
  /// shadow) comes from the last layout; it does not move during a capture.
  /// Without a laid-out box the label hides, so it can never leak into such
  /// a capture.
  bool _sessionLabelCovered() {
    final clearRects = widget.runtime._captureLabelClearRects;
    if (clearRects.isEmpty) return false;
    final box = _sessionLabelKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return true;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    ).inflate(12);
    return clearRects.any(rect.overlaps);
  }

  /// Live annotation pins (animated, keyed by id) plus any ghosts animating out.
  List<Widget> _buildPins() {
    final clearRects = widget.runtime._captureClearRects;
    final pins = widget.runtime._annotationPins(_visibleTargets);
    final widgets = <Widget>[];
    for (var i = 0; i < pins.length; i++) {
      final pin = pins[i];
      final center = _pinCenter(pin.rect);
      widgets.add(
        _ScoutPin(
          key: ValueKey('pin_${pin.id}'),
          center: center,
          status: pin.status,
          number: i + 1,
          // Hidden for the frame(s) its region is captured, so it never lands
          // in a crop; stays mounted so it doesn't re-animate afterward. Use the
          // reticle's bounding box (+ glow), not just the center, so a neighbour
          // pin's halo near a crop edge can't bleed in either.
          dimmed: clearRects.any(
            (r) => r.overlaps(
              Rect.fromCircle(center: center, radius: _ScoutPin.size / 2 + 10),
            ),
          ),
        ),
      );
    }
    for (final g in _exitingPins) {
      widgets.add(
        _ScoutPin(
          key: ValueKey('exit_${g.ghost}'),
          center: g.center,
          status: g.status,
          number: g.number,
          exiting: true,
          onExited: () {
            if (mounted) {
              setState(
                () => _exitingPins.removeWhere((e) => e.ghost == g.ghost),
              );
            }
          },
        ),
      );
    }
    return widgets;
  }

  void _selectAt(Offset point) {
    final candidates = widget.runtime.annotationCandidatesAt(point);
    if (candidates.isEmpty) {
      setState(() {
        _selectedTarget = null;
        _currentCandidates = const [];
        _commentController.clear();
        _lastTapPoint = point;
        _candidateIndex = 0;
      });
      return;
    }

    var index = 0;
    final last = _lastTapPoint;
    if (last != null && (last - point).distance <= 12) {
      index = (_candidateIndex + 1) % candidates.length;
    }
    setState(() {
      _lastTapPoint = point;
      _candidateIndex = index;
      _currentCandidates = candidates;
      _selectedTarget = candidates[index];
      _commentController.clear();
    });
  }

  void _saveComment() {
    final target = _selectedTarget;
    final comment = _commentController.text.trim();
    if (target == null || comment.isEmpty) return;
    widget.runtime.addAnnotation(target: target, comment: comment);
    setState(() {
      _selectedTarget = null;
      _currentCandidates = const [];
      _commentController.clear();
    });
  }

  void _scheduleTargetRefresh(int revision) {
    if (_targetRefreshScheduled || _lastCollectedRevision == revision) return;
    _targetRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final enabled = widget.runtime._annotationMode;
      final targets = enabled
          ? widget.runtime.visibleAnnotationTargets()
          : const <ScoutAnnotationTarget>[];
      setState(() {
        _targetRefreshScheduled = false;
        _lastCollectedRevision = revision;
        _visibleTargets = targets;
      });
    });
  }

  void _moveToggleButton(DragUpdateDetails details, BuildContext context) {
    final current = _resolvedToggleButtonOffset(context);
    setState(() {
      _toggleButtonOffset = _clampedToggleButtonOffset(
        context,
        current + details.delta,
      );
    });
  }

  Offset _resolvedToggleButtonOffset(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final defaultOffset = Offset(
      size.width - _toggleButtonWidth - _toggleButtonMargin,
      media.padding.top + _toggleButtonMargin,
    );
    return _clampedToggleButtonOffset(
      context,
      _toggleButtonOffset ?? defaultOffset,
    );
  }

  Offset _clampedToggleButtonOffset(BuildContext context, Offset offset) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final minLeft = _toggleButtonMargin;
    final minTop = media.padding.top + _toggleButtonMargin;
    final maxLeft = (size.width - _toggleButtonWidth - _toggleButtonMargin)
        .clamp(minLeft, double.infinity);
    final maxTop =
        (size.height -
                _toggleButtonHeight -
                media.padding.bottom -
                _toggleButtonMargin)
            .clamp(minTop, double.infinity);
    return Offset(
      offset.dx.clamp(minLeft, maxLeft),
      offset.dy.clamp(minTop, maxTop),
    );
  }

  double get _toggleButtonWidth {
    final count = widget.runtime._activeAnnotationCount;
    if (count == 0) return 56;
    return 74 + (count.toString().length * 8);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.runtime._annotationRevision,
      builder: (context, revision, child) {
        final enabled = widget.runtime._annotationMode;
        final interactive = widget.runtime._annotationOverlayInteractive;
        if (!interactive && _menuOpen) _schedulePassiveMenuClose();
        final toggleButtonOffset = _resolvedToggleButtonOffset(context);
        if (enabled) {
          _scheduleTargetRefresh(revision);
        } else if (_visibleTargets.isNotEmpty) {
          _scheduleTargetRefresh(revision);
        }
        // Hide all launcher/menu/FAB chrome for the frame(s) a region is being
        // rasterised, so it never lands in a crop/screenshot.
        final notCapturing = widget.runtime._captureClearRects.isEmpty;
        // The gate wraps the WHOLE overlay (absorber, pins, panels, launcher,
        // menu, toggle FAB): every piece of Scout chrome must be transparent to
        // synthetic agent gestures, or an agent tap aimed at an app control
        // underneath silently activates Scout's own UI instead.
        return _ScoutHitTestGate(
          runtime: widget.runtime,
          child: Stack(
            children: [
              if (enabled)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => _handleTap(details.localPosition),
                    child: CustomPaint(
                      painter: _FlutterScoutAnnotationPainter(
                        targets: _visibleTargets,
                        selectedTarget: _selectedTarget,
                        clearRects: widget.runtime._captureClearRects,
                        annotationRevision: revision,
                      ),
                    ),
                  ),
                ),
              if (enabled) ..._buildPins(),
              if (enabled && _selectedTarget != null)
                _AnnotationCommentPanel(
                  target: _selectedTarget!,
                  candidateIndex: _candidateIndex,
                  candidateCount: _currentCandidates.length,
                  controller: _commentController,
                  onCancel: () {
                    setState(() {
                      _selectedTarget = null;
                      _currentCandidates = const [];
                      _commentController.clear();
                    });
                  },
                  onSave: _saveComment,
                ),
              if (enabled && _selectedPin != null)
                _AnnotationPinPopup(
                  anchor: _selectedPin!.at,
                  comment: _selectedPin!.comment,
                  onDelete: _deleteSelectedPin,
                  onClose: () => setState(() => _selectedPin = null),
                ),
              // Launcher + its menu. The launcher sits above a tap-to-dismiss
              // barrier so it stays interactive (and reachable during
              // annotation mode) while the menu is open.
              if (notCapturing && interactive && _menuOpen)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeMenu,
                  ),
                ),
              _ScoutInstanceBadge(
                key: _sessionLabelKey,
                hidden: _sessionLabelCovered(),
                menuOpen: interactive && _menuOpen,
                interactive: interactive,
                agentAttached: widget.runtime._drivingOverlay.attachedNotifier,
                agentControlling:
                    widget.runtime._drivingOverlay.controllingNotifier,
                onTap: _toggleMenu,
              ),
              if (notCapturing) ...[
                if (interactive && _menuOpen)
                  _ScoutMenu(
                    annotationActive: enabled,
                    annotationCount: widget.runtime._activeAnnotationCount,
                    recording: widget.runtime._recording,
                    onToggleAnnotate: _onMenuAnnotate,
                    onToggleRecord: _onMenuRecord,
                  ),
                if (widget.runtime._recording)
                  _ScoutRecHud(
                    paused: widget.runtime._recordPaused,
                    stepCount: widget.runtime._recordSteps.length,
                    lastStep: widget.runtime._recordSteps.isEmpty
                        ? null
                        : widget.runtime._recordStepSummary(
                            widget.runtime._recordSteps.last,
                          ),
                    onStop: () => unawaited(widget.runtime.toggleRecording()),
                    onTogglePause: () {
                      if (widget.runtime._recordPaused) {
                        widget.runtime._resumeRecording();
                      } else {
                        widget.runtime._pauseRecording();
                      }
                    },
                  ),
              ],
              // Annotation FAB — now revealed only while annotation mode is
              // active (entered from the menu), not by default.
              if (enabled && notCapturing)
                Positioned(
                  left: toggleButtonOffset.dx,
                  top: toggleButtonOffset.dy,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onPanUpdate: (details) =>
                        _moveToggleButton(details, context),
                    child: _AnnotationToggleButton(
                      enabled: enabled,
                      count: widget.runtime._activeAnnotationCount,
                      onPressed: _toggleAnnotationMode,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _AnnotationToggleButton extends StatelessWidget {
  const _AnnotationToggleButton({
    required this.enabled,
    required this.count,
    required this.onPressed,
  });

  final bool enabled;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ScoutPill(
      icon: enabled ? Icons.my_location : Icons.add_location_alt_outlined,
      active: enabled,
      count: count,
      onPressed: onPressed,
    );
  }
}

class _AnnotationPinPopup extends StatelessWidget {
  const _AnnotationPinPopup({
    required this.anchor,
    required this.comment,
    required this.onDelete,
    required this.onClose,
  });

  final Offset anchor;
  final String comment;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  static const double _width = 260;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    // Anchor just below-right of the pin, clamped on-screen.
    final maxLeft = size.width - _width - 12;
    final left = maxLeft <= 12 ? 12.0 : (anchor.dx - 12).clamp(12.0, maxLeft);
    final minTop = padding.top + 12;
    final maxTop = size.height - padding.bottom - 160;
    final top = maxTop <= minTop
        ? minTop
        : (anchor.dy + 18).clamp(minTop, maxTop);
    return Positioned(
      left: left,
      top: top,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: ScoutMotion.base,
        curve: ScoutMotion.enter,
        builder: (context, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.9 + 0.1 * t,
            alignment: Alignment.topLeft,
            child: child,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _width),
          child: ScoutPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('NOTE', style: ScoutType.meta),
                const SizedBox(height: ScoutSpace.xs),
                Text(
                  comment,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: ScoutType.body,
                ),
                const SizedBox(height: ScoutSpace.m),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ScoutButton(
                      label: 'Close',
                      kind: ScoutButtonKind.ghost,
                      onPressed: onClose,
                    ),
                    const SizedBox(width: ScoutSpace.s),
                    ScoutButton(
                      label: 'Delete',
                      icon: Icons.delete_outline,
                      kind: ScoutButtonKind.danger,
                      onPressed: onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact comment dialog anchored beside the selected widget. It scales/fades
/// in from the edge nearest the target, animates back out before dismissing, and
/// reflows to stay on-screen and above the software keyboard.
class _AnnotationCommentPanel extends StatefulWidget {
  const _AnnotationCommentPanel({
    required this.target,
    required this.candidateIndex,
    required this.candidateCount,
    required this.controller,
    required this.onCancel,
    required this.onSave,
  });

  final ScoutAnnotationTarget target;
  final int candidateIndex;
  final int candidateCount;
  final TextEditingController controller;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  State<_AnnotationCommentPanel> createState() =>
      _AnnotationCommentPanelState();
}

class _AnnotationCommentPanelState extends State<_AnnotationCommentPanel>
    with SingleTickerProviderStateMixin {
  static const double _maxWidth = 300;
  static const double _gap = ScoutSpace.m;
  static const double _margin = ScoutSpace.m;

  final GlobalKey _panelKey = GlobalKey();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ScoutMotion.base,
    reverseDuration: ScoutMotion.fast,
  );
  late final CurvedAnimation _anim = CurvedAnimation(
    parent: _controller,
    curve: ScoutMotion.enter,
    reverseCurve: ScoutMotion.exit,
  );
  Size? _measured;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    // Dispose the CurvedAnimation before its parent so it deregisters its
    // status listener from the controller.
    _anim.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss(VoidCallback after) async {
    if (_closing) return;
    _closing = true;
    FocusScope.of(context).unfocus();
    try {
      await _controller.reverse();
    } finally {
      if (mounted) after();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final keyboard = media.viewInsets.bottom;
    final available = screen.width - _margin * 2;
    final width = available < _maxWidth ? available : _maxWidth;
    final estimate = _measured ?? Size(width, 220);
    final placement = scoutAnnotationDialogPlacement(
      target: widget.target.visibleRect,
      dialog: Size(width, estimate.height),
      screen: screen,
      safeArea: media.padding,
      keyboardInset: keyboard,
      gap: _gap,
      margin: _margin,
    );

    // Re-measure after layout so positioning uses the dialog's real height
    // (content and keyboard state vary); AnimatedPositioned smooths the move.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _panelKey.currentContext?.size;
      if (size != null && size != _measured) {
        setState(() => _measured = size);
      }
    });

    return AnimatedPositioned(
      duration: ScoutMotion.base,
      curve: ScoutMotion.enter,
      left: placement.offset.dx,
      top: placement.offset.dy,
      width: width,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          final t = _anim.value.clamp(0.0, 1.0);
          return Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.9 + 0.1 * t,
              alignment: placement.origin,
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: _panelKey,
          child: ScoutPanel(
            // TextField requires a Material ancestor; transparency keeps look.
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: ScoutColors.signal,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: ScoutSpace.s),
                      Expanded(
                        child: Text(
                          widget.target.displayName.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ScoutType.label,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: ScoutSpace.xs + 2),
                  Text(
                    '${widget.target.widgetType} · '
                    '${widget.candidateIndex + 1}/${widget.candidateCount}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScoutType.meta,
                  ),
                  const SizedBox(height: ScoutSpace.m),
                  ScoutField(controller: widget.controller),
                  const SizedBox(height: ScoutSpace.m),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ScoutButton(
                        label: 'Cancel',
                        kind: ScoutButtonKind.ghost,
                        onPressed: () => _dismiss(widget.onCancel),
                      ),
                      const SizedBox(width: ScoutSpace.s),
                      ScoutButton(
                        label: 'Save',
                        icon: Icons.check,
                        onPressed: () => _dismiss(widget.onSave),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Places the comment dialog beside [target]: to its right if the dialog fits,
/// else to its left, else below/above when neither side has room. The result is
/// clamped within the safe area and kept above the keyboard ([keyboardInset]).
/// [origin] is the scale-transform anchor so the dialog grows from the edge
/// nearest the target. Pure and side-effect free for testability.
@visibleForTesting
({Offset offset, Alignment origin}) scoutAnnotationDialogPlacement({
  required Rect target,
  required Size dialog,
  required Size screen,
  required EdgeInsets safeArea,
  required double keyboardInset,
  double gap = ScoutSpace.m,
  double margin = ScoutSpace.m,
}) {
  double clampD(double value, double lo, double hi) {
    if (hi < lo) return lo;
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
  }

  final safeLeft = margin;
  final safeRight = screen.width - margin;
  final safeTop = safeArea.top + margin;
  final safeBottom = screen.height - keyboardInset - margin;

  double left;
  var origin = Alignment.centerLeft;
  var beside = true;
  final rightSpace = safeRight - (target.right + gap);
  final leftSpace = (target.left - gap) - safeLeft;
  if (dialog.width <= rightSpace) {
    left = target.right + gap;
    origin = Alignment.centerLeft;
  } else if (dialog.width <= leftSpace) {
    left = target.left - gap - dialog.width;
    origin = Alignment.centerRight;
  } else {
    beside = false;
    left = clampD(
      target.center.dx - dialog.width / 2,
      safeLeft,
      safeRight - dialog.width,
    );
  }

  double top;
  if (beside) {
    top = target.center.dy - dialog.height / 2;
  } else {
    final below = target.bottom + gap;
    final above = target.top - gap - dialog.height;
    if (below + dialog.height <= safeBottom) {
      top = below;
      origin = Alignment.topCenter;
    } else if (above >= safeTop) {
      top = above;
      origin = Alignment.bottomCenter;
    } else {
      top = target.center.dy - dialog.height / 2;
      origin = Alignment.topCenter;
    }
  }
  top = clampD(top, safeTop, safeBottom - dialog.height);
  return (offset: Offset(left, top), origin: origin);
}

/// Paints the HUD field: a faint scrim, hairline reticle outlines on candidate
/// targets, and a bright corner-ticked frame on the selected target. Pins are
/// drawn as animated widgets above this layer (see [_ScoutPin]).
class _FlutterScoutAnnotationPainter extends CustomPainter {
  const _FlutterScoutAnnotationPainter({
    required this.targets,
    required this.selectedTarget,
    required this.clearRects,
    required this.annotationRevision,
  });

  final List<ScoutAnnotationTarget> targets;
  final ScoutAnnotationTarget? selectedTarget;
  final List<Rect> clearRects;
  final int annotationRevision;

  @override
  void paint(Canvas canvas, Size size) {
    // Carve out any region currently being rasterised so Scout's chrome never
    // lands in a crop/screenshot (without blanking the whole overlay).
    for (final rect in clearRects) {
      canvas.clipRect(rect, clipOp: ui.ClipOp.difference);
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = ScoutColors.scrim);

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ScoutColors.signal.withValues(alpha: 0.22);
    for (final target in targets.take(220)) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          target.rect.deflate(0.5),
          const Radius.circular(3),
        ),
        outline,
      );
    }

    final selected = selectedTarget;
    if (selected != null) {
      final r = selected.rect;
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ScoutColors.signal.withValues(alpha: 0.6),
      );
      final tick = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = ScoutColors.signal;
      const len = 11.0;
      _corner(
        canvas,
        r.topLeft,
        const Offset(1, 0),
        const Offset(0, 1),
        len,
        tick,
      );
      _corner(
        canvas,
        r.topRight,
        const Offset(-1, 0),
        const Offset(0, 1),
        len,
        tick,
      );
      _corner(
        canvas,
        r.bottomLeft,
        const Offset(1, 0),
        const Offset(0, -1),
        len,
        tick,
      );
      _corner(
        canvas,
        r.bottomRight,
        const Offset(-1, 0),
        const Offset(0, -1),
        len,
        tick,
      );
    }
  }

  void _corner(Canvas c, Offset o, Offset dx, Offset dy, double len, Paint p) {
    c.drawLine(o, o + dx * len, p);
    c.drawLine(o, o + dy * len, p);
  }

  @override
  bool shouldRepaint(covariant _FlutterScoutAnnotationPainter oldDelegate) {
    // clearRects is a single mutable list reused across builds, so comparing it
    // is a no-op; the revision bumps whenever clearRects changes, which is what
    // actually drives repaints during capture.
    return oldDelegate.targets != targets ||
        oldDelegate.selectedTarget != selectedTarget ||
        oldDelegate.annotationRevision != annotationRevision;
  }
}

/// An animated pin marker (HUD reticle badge) drawn above the painter layer.
/// Pops in on mount; on [exiting] it scales/fades out then calls [onExited].
class _ScoutPin extends StatefulWidget {
  const _ScoutPin({
    super.key,
    required this.center,
    required this.status,
    required this.number,
    this.dimmed = false,
    this.exiting = false,
    this.onExited,
  });

  final Offset center;
  final String status;
  final int number;
  final bool dimmed; // hidden for one frame while its region is being captured
  final bool exiting;
  final VoidCallback? onExited;

  static const double size = 26;

  @override
  State<_ScoutPin> createState() => _ScoutPinState();
}

class _ScoutPinState extends State<_ScoutPin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ScoutMotion.base,
    reverseDuration: ScoutMotion.fast,
  );

  @override
  void initState() {
    super.initState();
    if (widget.exiting) {
      _c.value = 1;
      _runExit();
    } else {
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(_ScoutPin old) {
    super.didUpdateWidget(old);
    if (widget.exiting && !old.exiting) _runExit();
  }

  void _runExit() {
    _c.reverse().then((_) {
      if (mounted) widget.onExited?.call();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ScoutColors.forStatus(widget.status);
    return Positioned(
      left: widget.center.dx - _ScoutPin.size / 2,
      top: widget.center.dy - _ScoutPin.size / 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            final t = ScoutMotion.pop.transform(_c.value.clamp(0.0, 1.0));
            return Opacity(
              opacity: widget.dimmed ? 0 : _c.value.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.4 + 0.6 * t, child: child),
            );
          },
          child: _PinReticle(accent: accent, number: widget.number),
        ),
      ),
    );
  }
}

class _PinReticle extends StatelessWidget {
  const _PinReticle({required this.accent, required this.number});

  final Color accent;
  final int number;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _ScoutPin.size,
      height: _ScoutPin.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ScoutColors.glass,
        shape: BoxShape.circle,
        border: Border.all(color: accent, width: 2),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.5),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Text(
        '$number',
        style: ScoutType.numeral.copyWith(color: accent, fontSize: 12),
      ),
    );
  }
}

/// Wraps the overlay's full-screen absorber so it stays opaque to real user
/// taps (selecting targets) but becomes hit-test-transparent while Scout is
/// collecting annotation targets. That lets the collection-time global hit
/// test pass through to the app and resolve the true topmost responder,
/// keeping occluded Stack siblings out of the target list.
class _ScoutHitTestGate extends SingleChildRenderObjectWidget {
  const _ScoutHitTestGate({required this.runtime, required Widget super.child});

  final FlutterScoutRuntime runtime;

  @override
  _RenderScoutHitTestGate createRenderObject(BuildContext context) =>
      _RenderScoutHitTestGate(runtime);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderScoutHitTestGate renderObject,
  ) {
    renderObject.runtime = runtime;
  }
}

class _RenderScoutHitTestGate extends RenderProxyBox {
  _RenderScoutHitTestGate(this.runtime);

  FlutterScoutRuntime runtime;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (runtime._scoutChromeHitTransparent) return false;
    return super.hitTest(result, position: position);
  }
}
