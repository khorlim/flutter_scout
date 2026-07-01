part of 'flutter_scout_binding.dart';

// part: in-app annotation overlay widgets (toggle + send-to-agent buttons,
// comment panel, target/pin painter) rendered on top of the running app.

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
  bool _targetRefreshScheduled = false;
  bool _handoffSent = false;
  // The pin whose delete popup is open (tapped an existing annotation pin).
  // Carries everything the exit ghost needs so it can always animate out even
  // if the live target list shifts before delete.
  ({String id, String comment, Offset at, String status, int number})?
  _selectedPin;
  // Ghost pins animating out after deletion (kept mounted until the exit ends).
  final List<({int ghost, Offset center, String status, int number})>
  _exitingPins = [];
  int _nextGhost = 0;

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

  void _sendToAgent() {
    widget.runtime._signalAnnotationHandoff();
    setState(() => _handoffSent = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _handoffSent = false);
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
        final toggleButtonOffset = _resolvedToggleButtonOffset(context);
        if (enabled) {
          _scheduleTargetRefresh(revision);
        } else if (_visibleTargets.isNotEmpty) {
          _scheduleTargetRefresh(revision);
        }
        return Stack(
          children: [
            if (enabled)
              Positioned.fill(
                child: _ScoutHitTestGate(
                  runtime: widget.runtime,
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
            if (enabled &&
                _selectedTarget == null &&
                _selectedPin == null &&
                widget.runtime._activeAnnotationCount > 0)
              Positioned(
                left: 12,
                right: 12,
                bottom: MediaQuery.paddingOf(context).bottom + 12,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: _AnnotationHandoffButton(
                    sent: _handoffSent,
                    count: widget.runtime._activeAnnotationCount,
                    onPressed: _sendToAgent,
                  ),
                ),
              ),
            Positioned(
              left: toggleButtonOffset.dx,
              top: toggleButtonOffset.dy,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (details) => _moveToggleButton(details, context),
                child: _AnnotationToggleButton(
                  enabled: enabled,
                  count: widget.runtime._activeAnnotationCount,
                  onPressed: _toggleAnnotationMode,
                ),
              ),
            ),
          ],
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

class _AnnotationHandoffButton extends StatelessWidget {
  const _AnnotationHandoffButton({
    required this.sent,
    required this.count,
    required this.onPressed,
  });

  final bool sent;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: ScoutMotion.base,
      switchInCurve: ScoutMotion.enter,
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: sent
          ? ScoutButton(
              key: const ValueKey('sent'),
              label: 'Sent',
              icon: Icons.check_circle_outline,
              kind: ScoutButtonKind.ghost,
              onPressed: () {},
            )
          : ScoutButton(
              key: const ValueKey('send'),
              label: 'Send $count to agent',
              icon: Icons.podcasts,
              onPressed: onPressed,
            ),
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
    if (runtime._collectingAnnotationTargets) return false;
    return super.hitTest(result, position: position);
  }
}
