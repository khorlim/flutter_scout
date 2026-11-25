part of 'flutter_scout_binding.dart';

// part: the "Scout is driving" layer. While an agent connection is attached,
// people watching the app see what the agent does: a cursor (desktop) or
// touch dot (iOS/Android) that glides to each target, a ripple at the exact
// hit point, a filling ring for a long press, a trail for drags and scrolls,
// the field being typed into, and a calm edge glow. The session label in
// the corner (annotation_overlay.dart) says whether Scout is controlling.
//
// It is a picture of input, never part of it:
// - Dispatch never waits for it. The input lands first; the visual timeline
//   (glide, then press) is drawn alongside and cannot move a real event.
// - One OverlayEntry: IgnorePointer > ExcludeSemantics > RepaintBoundary >
//   CustomPaint. It takes no hits, adds no semantics, and its widget name
//   starts with `_FlutterScout`, which every Scout tree walk prunes, so it is
//   absent from visible text, interactables, fields and screen inference.
// - One Ticker, running only while something moves. Its frame callback is
//   subtracted from the stability signals (`_appTransientCallbackCount`), so
//   settle detection sees only the app's own animations.
// - Scout screenshots and crops hide it unless asked to include it.

/// App-side opt-out: `--dart-define=FLUTTER_SCOUT_OVERLAY=0` (or `off`)
/// disables the layer for this build; `reduced` forces reduced motion.
const String _scoutOverlayDefine = String.fromEnvironment(
  'FLUTTER_SCOUT_OVERLAY',
);

bool get _scoutOverlayDisabledByDefine => const {
  '0',
  'off',
  'false',
  'no',
}.contains(_scoutOverlayDefine.toLowerCase());

/// Palette: Scout's signal accent over a dark rim, so every mark reads on a
/// light app and on a dark one.
abstract final class _DrivingColors {
  static const accent = ScoutColors.signal;
  static const rim = Color(0x8C06100E);
  static const glass = Color(0xE60B1211);
  static const ink = ScoutColors.ink;
  static const white = Color(0xFFFFFFFF);
}

double _easeOut(double t) => Curves.easeOutCubic.transform(t.clamp(0, 1));
double _easeInOut(double t) => Curves.easeInOutCubic.transform(t.clamp(0, 1));

/// A value easing from [from] to [to] over [duration] ms from [start].
class _DrivingFade {
  _DrivingFade(this.value);

  double value;
  double _from = 0;
  double _to = 0;
  double _start = 0;
  double _duration = 0;

  bool active(double now) => now < _start + _duration;

  void to(double target, double now, double duration) {
    final current = at(now);
    _from = current;
    _to = target;
    _start = now;
    _duration = duration <= 0 ? 0 : duration;
    if (_duration == 0) value = target;
  }

  double at(double now) {
    if (_duration == 0) return value;
    if (now >= _start + _duration) return value = _to;
    return value =
        _from + (_to - _from) * _easeInOut((now - _start) / _duration);
  }
}

enum _DrivingEffectKind { press, longPress, trail, typing, back, dismiss }

/// One drawn input. Times are overlay-clock milliseconds.
class _DrivingEffect {
  _DrivingEffect({
    required this.kind,
    required this.start,
    required this.end,
    this.point = Offset.zero,
    this.taps = 1,
    this.interval = 0,
    this.secondary = false,
    this.hold = 0,
    this.scroll = false,
    this.rect = Rect.zero,
    this.label,
    this.chip = Rect.zero,
    this.caret = Rect.zero,
  });

  final _DrivingEffectKind kind;
  final double start;
  double end;
  final Offset point;
  final int taps;
  final double interval;
  final bool secondary;
  final double hold;
  final bool scroll;
  final Rect rect;

  /// Typing: where the keystroke chip sits (inside the field, after the
  /// text), and the caret at the end of the typed text.
  final Rect chip;
  final Rect caret;

  /// Trail points (drag/scroll) and the time each was reached.
  final List<Offset> path = <Offset>[];
  final List<double> pathTimes = <double>[];

  /// Typing chip text (already masked for secrets) or a cue label.
  final TextPainter? label;

  /// A held drag stays open until drag-end; [end] is pushed out meanwhile.
  bool open = false;
}

/// A Ticker that can say whether its frame callback is pending, so the
/// stability signals can subtract exactly that one callback.
class _DrivingTicker extends Ticker {
  _DrivingTicker(super.onTick) : super(debugLabel: 'flutter_scout_overlay');

  bool get pending => scheduled;
}

class _ScoutDrivingOverlay extends ChangeNotifier {
  static const double _observingGlow = 0.34;
  static const double _activeGlow = 0.8;
  static const Duration _idleAfter = Duration(milliseconds: 2400);

  /// How long the session label keeps saying "controlling" after the last
  /// input settles. Longer than a model's turn between acts (3 to 12 s), so
  /// the label does not flip on every turn while the glow and cursor still
  /// calm down after [_idleAfter].
  static const Duration _labelIdleAfter = Duration(seconds: 15);
  static const int _maxEffects = 24;

  // ---- presence ---------------------------------------------------------
  bool _attached = false;
  bool _reducedRequested = false;
  int _leaseMs = 0;
  Timer? _leaseTimer;
  Timer? _idleTimer;
  Timer? _labelIdleTimer;
  Timer? _tagTimer;
  int _captureHideDepth = 0;
  bool _active = false;

  // ---- entry ------------------------------------------------------------
  OverlayEntry? _entry;
  OverlayState? _host;
  BuildContext? _entryContext;
  bool _installScheduled = false;

  // ---- hold -------------------------------------------------------------
  // While Scout runs a mutation the overlay schedules no frames: the ticker
  // is muted and new inputs wait here, then play when the act has answered.
  int _holdDepth = 0;
  final List<VoidCallback> _held = <VoidCallback>[];
  bool _rebase = false;

  bool get holding => _holdDepth > 0;

  void hold() {
    _holdDepth += 1;
    _ticker?.muted = true;
  }

  void release() {
    if (_holdDepth == 0 || --_holdDepth > 0) return;
    // Time spent held is dropped from the overlay clock, so a running
    // animation resumes where it paused instead of jumping ahead.
    _rebase = true;
    _ticker?.muted = false;
    final queued = List<VoidCallback>.of(_held);
    _held.clear();
    for (final draw in queued) {
      try {
        draw();
      } catch (_) {
        // Purely visual.
      }
    }
  }

  /// Runs [draw] now, or after the current mutation when held.
  void drawWhenFree(VoidCallback draw) {
    if (!holding) {
      draw();
    } else if (_held.length < 64) {
      _held.add(draw);
    }
  }

  // ---- app-work tracking ------------------------------------------------
  // Scout reuses its last observation snapshot while the app's trees cannot
  // have changed. Without the overlay that means "no frame since and none
  // scheduled"; the overlay's own frames would break that on every tick.
  // While it is installed, debug-only framework hooks tell app work from
  // overlay-only repaints: any app element rebuild, or any painted render
  // object other than the overlay's own CustomPaint (every layout marks
  // paint), advances [appWorkSeq], and so does a frame that ends with app
  // tickers still running. A pending frame counts as overlay-only only when
  // both hooks are still Scout's, no app build is scheduled and no app ticker
  // runs; otherwise the plain frame rules apply.
  final GlobalKey _paintKey = GlobalKey();
  bool _tracking = false;
  bool _buildPending = false;
  int appWorkSeq = 0;
  RebuildDirtyWidgetCallback? _previousRebuildHook;
  ProfilePaintCallback? _previousPaintHook;
  VoidCallback? _previousBuildScheduled;
  // Stored once so the identity checks in [_hooksIntact] hold.
  late final RebuildDirtyWidgetCallback _rebuildHook = _onAppRebuild;
  late final ProfilePaintCallback _paintHook = _onPaint;
  late final VoidCallback _buildScheduledHook = _onBuildScheduled;

  void _onAppRebuild(Element element, bool builtOnce) {
    appWorkSeq += 1;
    _previousRebuildHook?.call(element, builtOnce);
  }

  void _onPaint(RenderObject renderObject) {
    if (!identical(
      renderObject,
      _paintKey.currentContext?.findRenderObject(),
    )) {
      appWorkSeq += 1;
    }
    _previousPaintHook?.call(renderObject);
  }

  /// Told about every app build scheduled while this tracks app work
  /// (headless drive builds it when Flutter has stopped frames).
  VoidCallback? onAppBuildScheduled;

  void _onBuildScheduled() {
    _buildPending = true;
    appWorkSeq += 1;
    _previousBuildScheduled?.call();
    onAppBuildScheduled?.call();
  }

  bool _frameProbeInstalled = false;

  bool get tracksAppWork => _tracking && _hooksIntact;

  bool get _hooksIntact =>
      identical(debugOnRebuildDirtyWidget, _rebuildHook) &&
      identical(debugOnProfilePaint, _paintHook) &&
      identical(
        WidgetsBinding.instance.buildOwner?.onBuildScheduled,
        _buildScheduledHook,
      );

  int get _appTransientCallbacks {
    final count = WidgetsBinding.instance.transientCallbackCount;
    return tickScheduled ? math.max(0, count - 1) : count;
  }

  /// Whether the frame now scheduled (if any) can only be the overlay's.
  bool get onlyOverlayPending =>
      tracksAppWork &&
      !_buildPending &&
      _appTransientCallbacks == 0 &&
      WidgetsBinding.instance.schedulerPhase == SchedulerPhase.idle;

  void _startAppWorkTracking() {
    if (_tracking || !kDebugMode) return;
    final owner = WidgetsBinding.instance.buildOwner;
    if (owner == null) return;
    _previousRebuildHook = debugOnRebuildDirtyWidget;
    _previousPaintHook = debugOnProfilePaint;
    _previousBuildScheduled = owner.onBuildScheduled;
    debugOnRebuildDirtyWidget = _rebuildHook;
    debugOnProfilePaint = _paintHook;
    owner.onBuildScheduled = _buildScheduledHook;
    _tracking = true;
    // Builds run inside drawFrame; this callback runs after it, so a build
    // scheduled from here on belongs to a later frame.
    if (!_frameProbeInstalled) {
      _frameProbeInstalled = true;
      WidgetsBinding.instance.addPersistentFrameCallback((_) {
        if (!_tracking) return;
        _buildPending = false;
        if (_appTransientCallbacks > 0) appWorkSeq += 1;
      });
    }
  }

  void _stopAppWorkTracking() {
    if (!_tracking) return;
    _tracking = false;
    appWorkSeq += 1;
    // Restore only hooks that are still ours; someone else's stays.
    if (identical(debugOnRebuildDirtyWidget, _rebuildHook)) {
      debugOnRebuildDirtyWidget = _previousRebuildHook;
    }
    if (identical(debugOnProfilePaint, _paintHook)) {
      debugOnProfilePaint = _previousPaintHook;
    }
    final owner = WidgetsBinding.instance.buildOwner;
    if (owner != null &&
        identical(owner.onBuildScheduled, _buildScheduledHook)) {
      owner.onBuildScheduled = _previousBuildScheduled;
    }
  }

  // ---- clock ------------------------------------------------------------
  _DrivingTicker? _ticker;
  double _clockBase = 0;
  double now = 0;

  // ---- drawn state ------------------------------------------------------
  final _DrivingFade glow = _DrivingFade(0);

  /// The session label's word: controlling (an input within the last
  /// [_labelIdleAfter]) or observing. It changes at those transitions only, so
  /// the label can follow it without rebuilding per frame. The glow and cursor
  /// follow [controlling] instead, which calms down after [_idleAfter].
  final ValueNotifier<bool> controllingNotifier = ValueNotifier<bool>(false);
  final _DrivingFade cursorAlpha = _DrivingFade(0);
  // Cursor path as keyframes (time, point), eased between neighbours. A new
  // input replaces whatever path is still ahead, so a fast sequence of keys
  // retargets smoothly from wherever the cursor is drawn.
  final List<double> _keyTimes = <double>[0];
  final List<Offset> _keyPoints = <Offset>[Offset.zero];
  double _glowSettleAt = -1;
  // The cursor's name tag shows while the cursor works, then steps aside so
  // a parked cursor never hides what the input opened.
  double _tagUntil = -1;
  static const double _tagHold = 1100;
  static const double _tagFade = 300;

  double tagAlpha(double time) {
    if (time <= _tagUntil) return 1;
    return (1 - (time - _tagUntil) / _tagFade).clamp(0.0, 1.0);
  }

  final List<_DrivingEffect> effects = <_DrivingEffect>[];
  _DrivingEffect? _heldDrag;
  double _typingFreeAt = 0;

  bool get enabled => !_scoutOverlayDisabledByDefine;
  bool get attached => _attached;

  /// Changes only on attach/detach (not per frame), so the session label can
  /// follow the agent's presence without rebuilding on every tick.
  final ValueNotifier<bool> attachedNotifier = ValueNotifier<bool>(false);
  bool get hiddenForCapture => _captureHideDepth > 0;
  bool get controlling => _active;
  bool get installed => _entry != null && (_host?.mounted ?? false);

  /// Whether input should be drawn: attached and installed.
  bool get _live => _attached && _entry != null;

  bool get reducedMotion {
    if (_reducedRequested || _scoutOverlayDefine == 'reduced') return true;
    final features =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
    return features.disableAnimations || features.reduceMotion;
  }

  /// Touch platforms get a touch dot; desktop gets a cursor.
  bool get touchStyle => switch (defaultTargetPlatform) {
    TargetPlatform.iOS ||
    TargetPlatform.android ||
    TargetPlatform.fuchsia => true,
    _ => false,
  };

  /// Whether the overlay's ticker has a frame callback pending. That
  /// callback is Scout's own, so stability signals subtract it.
  bool get tickScheduled => _ticker?.pending ?? false;

  bool get ticking => _ticker?.isActive ?? false;

  Map<String, Object?> status() => <String, Object?>{
    'enabled': enabled,
    if (!enabled) 'disabledBy': 'dart_define_FLUTTER_SCOUT_OVERLAY',
    'attached': _attached,
    'installed': installed,
    'motion': reducedMotion ? 'reduced' : 'full',
    'style': touchStyle ? 'touch_dot' : 'cursor',
    'controlling': _active,
    'label': controllingNotifier.value ? 'controlling' : 'observing',
    'ticking': ticking,
    'effects': effects.length,
    'hiddenForCapture': hiddenForCapture,
    'view': 'primary',
    'leaseMs': _leaseMs,
    'observable': false,
  };

  // ---- presence lifecycle -----------------------------------------------

  /// Attach (or renew) for [leaseMs]. A lapsed lease detaches, so a crashed
  /// agent never leaves the glow behind.
  void attach({required int leaseMs, required bool reduced}) {
    if (!enabled) return;
    _leaseMs = leaseMs;
    _reducedRequested = reduced;
    _leaseTimer?.cancel();
    _leaseTimer = Timer(Duration(milliseconds: leaseMs), detach);
    if (_attached) {
      if (_entry == null) _scheduleInstall();
      return;
    }
    _attached = true;
    attachedNotifier.value = true;
    _scheduleInstall();
    glow.to(_observingGlow, now, reducedMotion ? 150 : 520);
    _kick();
  }

  void detach() {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _labelIdleTimer?.cancel();
    _labelIdleTimer = null;
    _tagTimer?.cancel();
    _tagTimer = null;
    if (!_attached) return;
    _attached = false;
    attachedNotifier.value = false;
    _active = false;
    _heldDrag = null;
    if (_entry == null) {
      _teardown();
      return;
    }
    glow.to(0, now, 320);
    controllingNotifier.value = false;
    cursorAlpha.to(0, now, 260);
    _tagUntil = math.min(_tagUntil, now);
    _kick();
  }

  /// Hides every mark for a screenshot. Paired with [endCaptureHide].
  void beginCaptureHide() {
    _captureHideDepth += 1;
    notifyListeners();
  }

  void endCaptureHide() {
    if (_captureHideDepth == 0) return;
    _captureHideDepth -= 1;
    notifyListeners();
  }

  // ---- entry lifecycle --------------------------------------------------

  void _scheduleInstall() {
    if (_entry != null) {
      if (_host?.mounted ?? false) return;
      // The hosting Overlay was replaced (root swap); reinstall.
      _entry = null;
      _host = null;
      _entryContext = null;
    }
    if (_installScheduled) return;
    _installScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _installScheduled = false;
      _install();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _install() {
    if (!_attached || _entry != null) return;
    final root = WidgetsBinding.instance.rootElement;
    final overlay = root == null ? null : _shallowestOverlay(root);
    if (overlay == null) {
      // No Overlay yet (first frames): try again on the next frame.
      _scheduleInstall();
      return;
    }
    final entry = OverlayEntry(
      builder: (context) {
        _entryContext = context;
        return _FlutterScoutDrivingOverlay(controller: this);
      },
    );
    _entry = entry;
    _host = overlay;
    overlay.insert(entry);
    _startAppWorkTracking();
    _kick();
  }

  /// The root Navigator's Overlay: the first one found from the root, so a
  /// nested navigator's overlay never hosts the layer.
  OverlayState? _shallowestOverlay(Element root) {
    final queue = Queue<Element>()..add(root);
    while (queue.isNotEmpty) {
      final element = queue.removeFirst();
      if (element is StatefulElement && element.state is OverlayState) {
        return element.state as OverlayState;
      }
      element.visitChildElements(queue.add);
    }
    return null;
  }

  void _teardown() {
    _stopAppWorkTracking();
    _ticker?.dispose();
    _ticker = null;
    for (final effect in effects) {
      effect.label?.dispose();
    }
    effects.clear();
    _heldDrag = null;
    final entry = _entry;
    _entry = null;
    _host = null;
    _entryContext = null;
    if (entry == null) return;
    try {
      entry.remove();
      entry.dispose();
    } catch (_) {
      // The host may already be disposed by a root replacement.
    }
  }

  // ---- clock ------------------------------------------------------------

  void _kick() {
    if (_entry == null) return;
    final ticker = _ticker ??= _DrivingTicker(_tick);
    ticker.muted = holding;
    if (!ticker.isActive) ticker.start();
    notifyListeners();
  }

  void _tick(Duration elapsed) {
    var time = _clockBase + elapsed.inMicroseconds / 1000.0;
    if (_rebase) {
      _rebase = false;
      final resumed = now + 16;
      _clockBase += resumed - time;
      time = resumed;
    }
    now = time;
    for (var i = effects.length - 1; i >= 0; i--) {
      final effect = effects[i];
      if (effect.open || now < effect.end) continue;
      effects.removeAt(i);
      effect.label?.dispose();
    }
    // The flash at an input decays to the steady level.
    if (_glowSettleAt >= 0 && now >= _glowSettleAt) {
      _glowSettleAt = -1;
      glow.to(_active ? _activeGlow : _observingGlow, now, 380);
    }
    final moving =
        effects.isNotEmpty ||
        _glowSettleAt >= 0 ||
        glow.active(now) ||
        cursorAlpha.active(now) ||
        (now > _tagUntil && now < _tagUntil + _tagFade) ||
        now < _keyTimes.last;
    if (!moving) {
      _ticker!.stop();
      _clockBase = now;
      if (!_attached) {
        _teardown();
        return;
      }
      _armTagFade();
      _armIdle();
    }
    notifyListeners();
  }

  /// The parked cursor's tag waits without frames; a timer starts its fade.
  void _armTagFade() {
    if (now >= _tagUntil || _tagTimer != null) return;
    final wait = (_tagUntil - now).ceil();
    _tagTimer = Timer(Duration(milliseconds: wait), () {
      _tagTimer = null;
      if (!_attached || ticking) return;
      // The overlay clock stands still while stopped; move it to the fade.
      _clockBase = now = _tagUntil;
      _kick();
    });
  }

  /// After the last input, the cursor parks for a moment, then fades and the
  /// glow drops back to the calmer observing state. The session label waits
  /// longer before it says observing, so it does not flip between turns.
  void _armIdle() {
    if (controllingNotifier.value && _labelIdleTimer == null) {
      _labelIdleTimer = Timer(_labelIdleAfter, () {
        _labelIdleTimer = null;
        if (!_attached) return;
        controllingNotifier.value = false;
      });
    }
    if (!_active || _idleTimer != null) return;
    _idleTimer = Timer(_idleAfter, () {
      _idleTimer = null;
      if (!_attached) return;
      _active = false;
      glow.to(_observingGlow, now, 600);
      cursorAlpha.to(0, now, 450);
      _kick();
    });
  }

  // ---- input hooks (called right before dispatch; never awaited) --------

  Offset _toLocal(Offset global) {
    final context = _entryContext;
    final box = context == null || !context.mounted
        ? null
        : context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.globalToLocal(global);
    }
    return global;
  }

  void _markActive() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _labelIdleTimer?.cancel();
    _labelIdleTimer = null;
    _tagTimer?.cancel();
    _tagTimer = null;
    _tagUntil = now + _tagHold;
    _active = true;
    controllingNotifier.value = true;
    glow.to(1, now, 90);
    _glowSettleAt = now + 90;
  }

  /// Starts one input: marks the session active and glides the cursor to
  /// [target]. Returns when (overlay clock) the cursor arrives.
  double _beginInput(Offset target) {
    _markActive();
    final reduced = reducedMotion;
    final hidden = cursorAlpha.at(now) < 0.05;
    if (hidden || cursorAlpha.value < 1) {
      cursorAlpha.to(1, now, reduced ? 0 : (hidden ? 140 : 100));
    }
    final from = hidden
        ? (reduced ? target : target + const Offset(22, 28))
        : cursorPosition;
    final distance = (target - from).distance;
    final glide = reduced || distance < 1
        ? 0.0
        : (120 + distance * 0.08).clamp(120, 180).toDouble();
    _keyTimes
      ..clear()
      ..add(now)
      ..add(now + glide);
    _keyPoints
      ..clear()
      ..add(from)
      ..add(target);
    return now + glide;
  }

  /// Appends a cursor keyframe: the cursor reaches [point] at [time].
  void _cursorThen(double time, Offset point) {
    // Drop keyframes already passed, keeping one to interpolate from.
    while (_keyTimes.length > 2 && _keyTimes[1] <= now) {
      _keyTimes.removeAt(0);
      _keyPoints.removeAt(0);
    }
    _keyTimes.add(math.max(time, _keyTimes.last));
    _keyPoints.add(point);
  }

  Offset get cursorPosition {
    if (now <= _keyTimes.first) return _keyPoints.first;
    for (var i = 1; i < _keyTimes.length; i++) {
      final t1 = _keyTimes[i];
      if (now >= t1) continue;
      final t0 = _keyTimes[i - 1];
      final t = t1 <= t0 ? 1.0 : (now - t0) / (t1 - t0);
      return Offset.lerp(_keyPoints[i - 1], _keyPoints[i], _easeInOut(t))!;
    }
    return _keyPoints.last;
  }

  void _add(_DrivingEffect effect) {
    effects.add(effect);
    if (effects.length > _maxEffects) effects.removeAt(0);
    _kick();
  }

  void press(
    Offset globalPoint, {
    int taps = 1,
    Duration interval = Duration.zero,
    bool secondary = false,
  }) {
    if (!_live) return;
    final point = _toLocal(globalPoint);
    final start = _beginInput(point);
    // Two pulses must read as two even when the real interval is tiny.
    final gap = math.max(140.0, interval.inMilliseconds.toDouble());
    _add(
      _DrivingEffect(
        kind: _DrivingEffectKind.press,
        start: start,
        end: start + (taps - 1) * gap + (secondary ? 1000 : 520),
        point: point,
        taps: taps,
        interval: gap,
        secondary: secondary,
        label: secondary ? _chip('Right click') : null,
      ),
    );
  }

  void longPress(Offset globalPoint, Duration hold) {
    if (!_live) return;
    final point = _toLocal(globalPoint);
    final start = _beginInput(point);
    final holdMs = hold.inMilliseconds.toDouble();
    _add(
      _DrivingEffect(
        kind: _DrivingEffectKind.longPress,
        start: start,
        end: start + holdMs + 520,
        point: point,
        hold: holdMs,
      ),
    );
  }

  /// A complete drag/swipe/scroll from [globalStart] by [delta].
  void drag(Offset globalStart, Offset delta, {required bool scroll}) {
    if (!_live) return;
    final from = _toLocal(globalStart);
    final to = _toLocal(globalStart + delta);
    final start = _beginInput(from);
    final travel = reducedMotion ? 0.0 : 300.0;
    final moveAt = start + 70;
    final effect = _DrivingEffect(
      kind: _DrivingEffectKind.trail,
      start: start,
      end: moveAt + travel + 160 + 420,
      point: from,
      scroll: scroll,
    );
    effect.path
      ..add(from)
      ..add(to);
    effect.pathTimes
      ..add(moveAt)
      ..add(moveAt + travel);
    _cursorThen(moveAt, from);
    _cursorThen(moveAt + travel, to);
    _add(effect);
  }

  void heldDragStart(Offset globalPoint) {
    if (!_live) return;
    final point = _toLocal(globalPoint);
    final start = _beginInput(point);
    final effect = _DrivingEffect(
      kind: _DrivingEffectKind.trail,
      start: start,
      end: start + 600,
      point: point,
    )..open = true;
    effect.path.add(point);
    effect.pathTimes.add(start);
    _heldDrag = effect;
    _add(effect);
  }

  void heldDragMove(Offset globalPoint) {
    final effect = _heldDrag;
    if (!_live || effect == null) return;
    final point = _toLocal(globalPoint);
    _idleTimer?.cancel();
    _idleTimer = null;
    _labelIdleTimer?.cancel();
    _labelIdleTimer = null;
    final at = math.max(now, effect.pathTimes.last);
    final duration = reducedMotion ? 0.0 : 90.0;
    effect.path.add(point);
    effect.pathTimes.add(at + duration);
    _cursorThen(at, effect.path[effect.path.length - 2]);
    _cursorThen(at + duration, point);
    _kick();
  }

  void heldDragEnd() {
    final effect = _heldDrag;
    _heldDrag = null;
    if (effect == null) return;
    effect.open = false;
    effect.end = math.max(now, effect.pathTimes.last) + 160 + 420;
    _kick();
  }

  /// Typing into the editable area at [globalArea]; [globalCaret] is the
  /// caret after the typed text. [text] is null for a credential field: the
  /// chip then shows dots and never the value or its length. The chip sits
  /// inside the field after the text, so it never covers app text; without
  /// room for it only the caret at the end of the text pulses.
  void typing(Rect globalArea, Rect globalCaret, String? text) {
    if (!_live) return;
    final origin = _toLocal(Offset.zero);
    final area = globalArea.shift(origin);
    final caret = globalCaret.shift(origin);
    final glideEnd = _beginInput(area.center);
    // fill types several fields; draw them one after another.
    final start = math.max(glideEnd + 60, _typingFreeAt);
    final shown = text ?? '••••••';
    final room = area.right - 4 - (caret.right + 10);
    final label = room >= 48
        ? _chipFitting(shown.isEmpty ? 'Cleared' : shown, room - 20)
        : null;
    final chip = label == null
        ? Rect.zero
        : Rect.fromLTWH(
            area.right - 4 - (label.width + 20),
            caret.center.dy - (label.height + 6) / 2,
            label.width + 20,
            label.height + 6,
          );
    final typeMs = reducedMotion
        ? 0.0
        : (shown.characters.length * 22.0).clamp(160, 560).toDouble();
    _typingFreeAt = start + typeMs + 100;
    _add(
      _DrivingEffect(
        kind: _DrivingEffectKind.typing,
        start: start,
        end: start + typeMs + 520,
        rect: area,
        hold: typeMs,
        label: label,
        chip: chip,
        caret: caret,
      ),
    );
  }

  /// A chip label no wider than [maxWidth]: the tail of [text] (the latest
  /// keystrokes), with a leading ellipsis when cut.
  TextPainter? _chipFitting(String text, double maxWidth) {
    final chars = text.characters.toList();
    for (var keep = math.min(chars.length, 32); keep >= 2; keep--) {
      final cut = keep < chars.length;
      final painter = _chip(
        '${cut ? '…' : ''}${chars.sublist(chars.length - keep).join()}',
        mono: true,
      );
      if (painter.width <= maxWidth) return painter;
      painter.dispose();
    }
    return null;
  }

  void back() => _cue(_DrivingEffectKind.back, 'Back');

  void dismiss() =>
      _cue(_DrivingEffectKind.dismiss, touchStyle ? 'Dismiss' : 'esc');

  void _cue(_DrivingEffectKind kind, String label) {
    if (!_live) return;
    _markActive();
    _add(
      _DrivingEffect(
        kind: kind,
        start: now,
        end: now + 620,
        label: _chip(label),
      ),
    );
  }

  TextPainter _chip(String text, {bool mono = false}) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: _DrivingColors.ink,
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: mono ? 0.2 : 0.4,
        fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  @override
  void dispose() {
    _leaseTimer?.cancel();
    _idleTimer?.cancel();
    _labelIdleTimer?.cancel();
    _tagTimer?.cancel();
    _teardown();
    super.dispose();
  }
}

/// The overlay entry's widget. Its name starts with `_FlutterScout`, which
/// every Scout tree walk prunes; IgnorePointer and ExcludeSemantics keep it
/// out of hit testing and the semantics tree.
class _FlutterScoutDrivingOverlay extends StatelessWidget {
  const _FlutterScoutDrivingOverlay({required this.controller});

  final _ScoutDrivingOverlay controller;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          key: controller._paintKey,
          painter: _ScoutDrivingPainter(controller),
          size: Size.infinite,
        ),
      ),
    ),
  );
}

class _ScoutDrivingPainter extends CustomPainter {
  _ScoutDrivingPainter(this.c) : super(repaint: c);

  final _ScoutDrivingOverlay c;

  // Reused every frame: no per-frame Paint allocation.
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _blurStroke = Paint()
    ..style = PaintingStyle.stroke
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
  final Paint _shadow = Paint()
    ..style = PaintingStyle.fill
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
  // Fades text (which carries its own colour) through one save layer.
  final Paint _layer = Paint();

  void _paintText(Canvas canvas, TextPainter text, Offset at, double alpha) {
    if (alpha >= 0.99) {
      text.paint(canvas, at);
      return;
    }
    _layer.color = Color.fromRGBO(0, 0, 0, alpha);
    canvas.saveLayer(at & text.size, _layer);
    text.paint(canvas, at);
    canvas.restore();
  }

  static final Path _arrow = Path()
    ..moveTo(0, 0)
    ..lineTo(0, 17.5)
    ..lineTo(4.6, 13.4)
    ..lineTo(7.7, 20.2)
    ..lineTo(10.6, 18.9)
    ..lineTo(7.6, 12.3)
    ..lineTo(13.6, 12.3)
    ..close();

  static TextPainter? _tag;

  static TextPainter _label(String text, {double size = 11.5, Color? color}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color ?? _DrivingColors.ink,
            fontSize: size,
            height: 1.2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (c.hiddenForCapture) return;
    final now = c.now;
    final glow = c.glow.at(now);
    if (glow > 0.003) _paintGlow(canvas, size, glow);
    for (final effect in c.effects) {
      if (now < effect.start && effect.kind != _DrivingEffectKind.typing) {
        continue;
      }
      switch (effect.kind) {
        case _DrivingEffectKind.press:
          _paintPress(canvas, size, effect, now);
        case _DrivingEffectKind.longPress:
          _paintLongPress(canvas, effect, now);
        case _DrivingEffectKind.trail:
          _paintTrail(canvas, effect, now);
        case _DrivingEffectKind.typing:
          _paintTyping(canvas, size, effect, now);
        case _DrivingEffectKind.back:
          _paintBack(canvas, size, effect, now);
        case _DrivingEffectKind.dismiss:
          _paintDismiss(canvas, size, effect, now);
      }
    }
    final cursorAlpha = c.cursorAlpha.at(now);
    if (cursorAlpha > 0.01) _paintCursor(canvas, size, now, cursorAlpha);
  }

  // ---- session ----------------------------------------------------------

  void _paintGlow(Canvas canvas, Size size, double level) {
    final radius = c.touchStyle ? 38.0 : 10.0;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(1.5);
    _blurStroke
      ..strokeWidth = 10
      ..color = _DrivingColors.accent.withValues(alpha: 0.42 * level);
    canvas.drawRRect(rrect, _blurStroke);
    _stroke
      ..strokeWidth = 1.6
      ..color = _DrivingColors.accent.withValues(alpha: 0.9 * level);
    canvas.drawRRect(rrect, _stroke);
  }

  // ---- cursor / touch dot -----------------------------------------------

  double _pressDepth(double now) {
    var depth = 0.0;
    for (final effect in c.effects) {
      if (now < effect.start) continue;
      final t = now - effect.start;
      switch (effect.kind) {
        case _DrivingEffectKind.press:
          for (var i = 0; i < effect.taps; i++) {
            final local = t - i * effect.interval;
            if (local >= 0 && local < 160) {
              depth = math.max(depth, 1 - (local / 160));
            }
          }
        case _DrivingEffectKind.longPress:
          if (t < effect.hold) depth = 1;
          if (t >= effect.hold && t < effect.hold + 160) {
            depth = math.max(depth, 1 - (t - effect.hold) / 160);
          }
        case _DrivingEffectKind.trail:
          // Pressed from arrival at the start until the finger lifts.
          if (effect.open || now < effect.pathTimes.last + 60) depth = 1;
        default:
          break;
      }
    }
    return depth;
  }

  void _paintCursor(Canvas canvas, Size size, double now, double alpha) {
    final p = c.cursorPosition;
    final depth = c.reducedMotion ? 0.0 : _pressDepth(now);
    // Just "Scout": it tells the AI pointer from a person's mouse. The
    // session's name lives on the session label.
    final tag = _tag ??= _label(
      'Scout',
      size: 11,
      color: const Color(0xFF03201C),
    );
    if (c.touchStyle) {
      final r = 13.0 * (1 - 0.14 * depth);
      _shadow.color = Color.fromRGBO(0, 0, 0, 0.28 * alpha);
      canvas.drawCircle(p + const Offset(0, 1.5), r + 1, _shadow);
      _fill.color = Color.lerp(
        const Color(0x66FFFFFF),
        _DrivingColors.accent.withValues(alpha: 0.55),
        depth,
      )!.withValues(alpha: (0.45 + 0.25 * depth) * alpha);
      canvas.drawCircle(p, r, _fill);
      _stroke
        ..strokeWidth = 2.2
        ..color = _DrivingColors.accent.withValues(alpha: alpha);
      canvas.drawCircle(p, r, _stroke);
      _stroke
        ..strokeWidth = 1
        ..color = _DrivingColors.rim.withValues(alpha: 0.5 * alpha);
      canvas.drawCircle(p, r + 1.6, _stroke);
      final tagAlpha = alpha * c.tagAlpha(now);
      if (tagAlpha > 0.01) {
        _paintTag(canvas, size, tag, p, Offset(r + 4, r - 2), tagAlpha);
      }
      return;
    }
    final scale = 1 - 0.12 * depth;
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.scale(scale);
    _shadow.color = Color.fromRGBO(0, 0, 0, 0.35 * alpha);
    canvas.save();
    canvas.translate(0.8, 1.8);
    canvas.drawPath(_arrow, _shadow);
    canvas.restore();
    _fill.color = _DrivingColors.glass.withValues(alpha: alpha);
    canvas.drawPath(_arrow, _fill);
    _stroke
      ..strokeWidth = 1.5
      ..color = _DrivingColors.white.withValues(alpha: alpha);
    canvas.drawPath(_arrow, _stroke);
    canvas.restore();
    // A pressed cursor lights its tip.
    if (depth > 0.01) {
      _fill.color = _DrivingColors.accent.withValues(
        alpha: 0.9 * depth * alpha,
      );
      canvas.drawCircle(p, 3.2, _fill);
    }
    final tagAlpha = alpha * c.tagAlpha(now);
    if (tagAlpha > 0.01) {
      _paintTag(canvas, size, tag, p, const Offset(13, 19), tagAlpha);
    }
  }

  /// The name tag beside the cursor; it flips to the cursor's left (and
  /// above it) when it would leave the window.
  /// [rect] moved (not resized) to lie [margin] inside the window.
  static Rect _inside(Size size, Rect rect, {double margin = 4}) {
    final maxLeft = math.max(margin, size.width - rect.width - margin);
    final maxTop = math.max(margin, size.height - rect.height - margin);
    return Rect.fromLTWH(
      rect.left.clamp(margin, maxLeft).toDouble(),
      rect.top.clamp(margin, maxTop).toDouble(),
      rect.width,
      rect.height,
    );
  }

  void _paintTag(
    Canvas canvas,
    Size size,
    TextPainter tag,
    Offset cursor,
    Offset offset,
    double alpha,
  ) {
    final width = tag.width + 12;
    final height = tag.height + 5;
    var at = cursor + offset;
    if (at.dx + width > size.width - 4) {
      at = Offset(cursor.dx - 6 - width, at.dy);
    }
    if (at.dy + height > size.height - 4) {
      at = Offset(at.dx, cursor.dy - 6 - height);
    }
    final rect = _inside(size, Rect.fromLTWH(at.dx, at.dy, width, height));
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));
    _shadow.color = Color.fromRGBO(0, 0, 0, 0.22 * alpha);
    canvas.drawRRect(rrect.shift(const Offset(0, 1.5)), _shadow);
    _fill.color = _DrivingColors.accent.withValues(alpha: alpha);
    canvas.drawRRect(rrect, _fill);
    _paintText(canvas, tag, Offset(rect.left + 6, rect.top + 2.5), alpha);
  }

  // ---- presses ----------------------------------------------------------

  /// A ripple: accent ring over a dark rim so it reads on any background.
  void _ring(Canvas canvas, Offset p, double t, {bool square = false}) {
    if (t < 0 || t > 1) return;
    final reduced = c.reducedMotion;
    final radius = reduced ? 20.0 : 7 + 21 * _easeOut(t);
    final alpha = (1 - t) * (1 - t);
    void draw(double width, Color color) {
      _stroke
        ..strokeWidth = width
        ..color = color;
      if (square) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCircle(center: p, radius: radius * 0.86),
            Radius.circular(radius * 0.3),
          ),
          _stroke,
        );
      } else {
        canvas.drawCircle(p, radius, _stroke);
      }
    }

    draw(4.6, _DrivingColors.rim.withValues(alpha: 0.45 * alpha));
    draw(2.4, _DrivingColors.accent.withValues(alpha: alpha));
    // The exact hit point.
    if (t < 0.55) {
      _fill.color = _DrivingColors.accent.withValues(
        alpha: 0.55 * (1 - t / 0.55),
      );
      canvas.drawCircle(p, 3.4, _fill);
    }
  }

  void _paintPress(Canvas canvas, Size size, _DrivingEffect e, double now) {
    for (var i = 0; i < e.taps; i++) {
      _ring(
        canvas,
        e.point,
        (now - e.start - i * e.interval) / 460,
        square: e.secondary,
      );
    }
    final label = e.label;
    if (label != null) {
      final t = (now - e.start) / (e.end - e.start);
      _paintChip(
        canvas,
        size,
        label,
        e.point + const Offset(16, -34),
        _chipAlpha(t),
      );
    }
  }

  void _paintLongPress(Canvas canvas, _DrivingEffect e, double now) {
    final t = now - e.start;
    const radius = 22.0;
    if (t < e.hold) {
      final progress = e.hold <= 0 ? 1.0 : t / e.hold;
      final appear = (t / 120).clamp(0.0, 1.0);
      _stroke
        ..strokeWidth = 5
        ..color = _DrivingColors.rim.withValues(alpha: 0.35 * appear);
      canvas.drawCircle(e.point, radius, _stroke);
      _stroke
        ..strokeWidth = 2.6
        ..color = _DrivingColors.accent.withValues(alpha: 0.25 * appear);
      canvas.drawCircle(e.point, radius, _stroke);
      _stroke
        ..strokeWidth = 3
        ..color = _DrivingColors.accent.withValues(alpha: appear);
      canvas.drawArc(
        Rect.fromCircle(center: e.point, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        _stroke,
      );
      _fill.color = _DrivingColors.accent.withValues(alpha: 0.16 * appear);
      canvas.drawCircle(e.point, radius * progress, _fill);
      return;
    }
    _ring(canvas, e.point, (t - e.hold) / 460);
  }

  // ---- drags and scrolls ------------------------------------------------

  void _paintTrail(Canvas canvas, _DrivingEffect e, double now) {
    final points = e.path;
    final times = e.pathTimes;
    if (points.isEmpty) return;
    final fade = e.open
        ? 1.0
        : (1 - ((now - (times.last + 160)) / 420)).clamp(0.0, 1.0);
    if (fade <= 0) return;
    // Head: where the finger is now along the recorded path.
    var head = points.first;
    var reached = 0;
    for (var i = 1; i < points.length; i++) {
      final t0 = times[i - 1];
      final t1 = times[i];
      if (now >= t1) {
        head = points[i];
        reached = i;
        continue;
      }
      if (now > t0) {
        head = Offset.lerp(
          points[i - 1],
          points[i],
          _easeInOut((now - t0) / (t1 - t0)),
        )!;
        reached = i - 1;
      }
      break;
    }
    // Start mark.
    _stroke
      ..strokeWidth = 2
      ..color = _DrivingColors.accent.withValues(alpha: 0.7 * fade);
    canvas.drawCircle(points.first, 5, _stroke);
    // Trail: dark rim then accent, brightening toward the head. Segments
    // run points[0] .. points[reached], then on to the head.
    final segments = reached + 1;
    for (var pass = 0; pass < 2; pass++) {
      var previous = points.first;
      for (var i = 1; i <= segments; i++) {
        final next = i <= reached ? points[i] : head;
        final weight = 0.45 + 0.55 * i / segments;
        _stroke
          ..strokeWidth = pass == 0 ? 7 : 3.6
          ..color = pass == 0
              ? _DrivingColors.rim.withValues(alpha: 0.3 * weight * fade)
              : _DrivingColors.accent.withValues(alpha: 0.85 * weight * fade);
        canvas.drawLine(previous, next, _stroke);
        previous = next;
      }
    }
    if (e.scroll && points.length >= 2) {
      _paintScrollCue(canvas, points.first, points.last, fade);
    }
  }

  /// A chevron badge in the direction the content was asked to move, which
  /// is opposite to the finger.
  void _paintScrollCue(Canvas canvas, Offset from, Offset to, double alpha) {
    final finger = to - from;
    if (finger.distance < 1) return;
    final dir = -finger / finger.distance;
    final center = Offset.lerp(from, to, 0.5)! + Offset(dir.dy, -dir.dx) * 34;
    _shadow.color = Color.fromRGBO(0, 0, 0, 0.25 * alpha);
    canvas.drawCircle(center + const Offset(0, 1.5), 15, _shadow);
    _fill.color = _DrivingColors.glass.withValues(alpha: 0.92 * alpha);
    canvas.drawCircle(center, 15, _fill);
    _stroke
      ..strokeWidth = 1
      ..color = _DrivingColors.accent.withValues(alpha: 0.5 * alpha);
    canvas.drawCircle(center, 15, _stroke);
    final side = Offset(-dir.dy, dir.dx);
    _stroke
      ..strokeWidth = 2.2
      ..color = _DrivingColors.accent.withValues(alpha: alpha);
    for (final shift in const [-3.5, 3.5]) {
      final tip = center + dir * (shift + 3);
      canvas.drawLine(tip, tip - dir * 5 + side * 5.5, _stroke);
      canvas.drawLine(tip, tip - dir * 5 - side * 5.5, _stroke);
    }
  }

  // ---- typing -----------------------------------------------------------

  void _paintTyping(Canvas canvas, Size size, _DrivingEffect e, double now) {
    final appear = ((now - (e.start - 120)) / 140).clamp(0.0, 1.0);
    final out = ((now - (e.end - 400)) / 400).clamp(0.0, 1.0);
    final alpha = appear * (1 - out);
    if (alpha <= 0) return;
    final rrect = RRect.fromRectAndRadius(
      e.rect.inflate(3),
      const Radius.circular(8),
    );
    _blurStroke
      ..strokeWidth = 6
      ..color = _DrivingColors.accent.withValues(alpha: 0.35 * alpha);
    canvas.drawRRect(rrect, _blurStroke);
    _stroke
      ..strokeWidth = 4
      ..color = _DrivingColors.rim.withValues(alpha: 0.25 * alpha);
    canvas.drawRRect(rrect, _stroke);
    _stroke
      ..strokeWidth = 2
      ..color = _DrivingColors.accent.withValues(alpha: alpha);
    canvas.drawRRect(rrect, _stroke);
    final progress = e.hold <= 0
        ? 1.0
        : ((now - e.start) / e.hold).clamp(0.0, 1.0);
    // Caret at the end of the typed text: solid while typing, then a pulse.
    final caretT = now - e.start - e.hold;
    final caretAlpha = caretT < 0
        ? 1.0
        : (0.5 + 0.5 * math.cos(caretT / 520 * 2 * math.pi)).clamp(0.0, 1.0);
    final label = e.label;
    if (label == null) {
      _fill.color = _DrivingColors.accent.withValues(alpha: caretAlpha * alpha);
      canvas.drawRect(
        Rect.fromLTWH(e.caret.right + 2, e.caret.top, 2, e.caret.height),
        _fill,
      );
      return;
    }
    // Keystroke chip inside the field, after the text, with the text
    // arriving and a caret at its end.
    final chip = e.chip;
    final crrect = RRect.fromRectAndRadius(chip, const Radius.circular(7));
    _fill.color = _DrivingColors.glass.withValues(alpha: 0.94 * alpha);
    canvas.drawRRect(crrect, _fill);
    _stroke
      ..strokeWidth = 1
      ..color = _DrivingColors.accent.withValues(alpha: 0.45 * alpha);
    canvas.drawRRect(crrect, _stroke);
    final textLeft = chip.left + 8;
    final textTop = chip.top + 3;
    final visibleWidth = label.width * progress;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(textLeft, chip.top, visibleWidth + 0.5, chip.height),
    );
    _paintText(canvas, label, Offset(textLeft, textTop), alpha);
    canvas.restore();
    _fill.color = _DrivingColors.accent.withValues(alpha: caretAlpha * alpha);
    canvas.drawRect(
      Rect.fromLTWH(textLeft + visibleWidth + 1.5, textTop, 1.6, label.height),
      _fill,
    );
  }

  // ---- back / dismiss ---------------------------------------------------

  double _chipAlpha(double t) {
    if (t < 0.15) return t / 0.15;
    if (t > 0.7) return ((1 - t) / 0.3).clamp(0.0, 1.0);
    return 1;
  }

  void _paintChip(
    Canvas canvas,
    Size size,
    TextPainter label,
    Offset at,
    double alpha,
  ) {
    if (alpha <= 0) return;
    final rect = _inside(
      size,
      Rect.fromLTWH(at.dx, at.dy, label.width + 18, label.height + 8),
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    _shadow.color = Color.fromRGBO(0, 0, 0, 0.25 * alpha);
    canvas.drawRRect(rrect.shift(const Offset(0, 2)), _shadow);
    _fill.color = _DrivingColors.glass.withValues(alpha: 0.94 * alpha);
    canvas.drawRRect(rrect, _fill);
    _stroke
      ..strokeWidth = 1
      ..color = _DrivingColors.accent.withValues(alpha: 0.5 * alpha);
    canvas.drawRRect(rrect, _stroke);
    _paintText(canvas, label, Offset(rect.left + 9, rect.top + 4), alpha);
  }

  void _paintBack(Canvas canvas, Size size, _DrivingEffect e, double now) {
    final t = ((now - e.start) / (e.end - e.start)).clamp(0.0, 1.0);
    final slide = c.reducedMotion ? 1.0 : _easeOut(t / 0.35);
    final alpha = _chipAlpha(t);
    final center = Offset(-16 + 40 * slide, size.height / 2);
    _shadow.color = Color.fromRGBO(0, 0, 0, 0.25 * alpha);
    canvas.drawCircle(center + const Offset(0, 2), 22, _shadow);
    _fill.color = _DrivingColors.glass.withValues(alpha: 0.92 * alpha);
    canvas.drawCircle(center, 22, _fill);
    _stroke
      ..strokeWidth = 2.6
      ..color = _DrivingColors.accent.withValues(alpha: alpha);
    canvas.drawLine(
      center + const Offset(4, -8),
      center + const Offset(-4, 0),
      _stroke,
    );
    canvas.drawLine(
      center + const Offset(-4, 0),
      center + const Offset(4, 8),
      _stroke,
    );
    final label = e.label;
    if (label != null) {
      _paintChip(
        canvas,
        size,
        label,
        center + Offset(30, -label.height / 2 - 4),
        alpha,
      );
    }
  }

  void _paintDismiss(Canvas canvas, Size size, _DrivingEffect e, double now) {
    final label = e.label;
    if (label == null) return;
    final t = ((now - e.start) / (e.end - e.start)).clamp(0.0, 1.0);
    final alpha = _chipAlpha(t);
    final rise = c.reducedMotion ? 0.0 : 6 * (1 - _easeOut(t / 0.3));
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final top = view == null ? 0.0 : view.padding.top / view.devicePixelRatio;
    final width = label.width + 18;
    _paintChip(
      canvas,
      size,
      label,
      Offset((size.width - width) / 2, top + 12 + rise),
      alpha,
    );
  }

  @override
  bool shouldRepaint(_ScoutDrivingPainter oldDelegate) =>
      !identical(oldDelegate.c, c);
}

extension _RuntimeDrivingOverlay on FlutterScoutRuntime {
  /// Draws one input on the overlay when an agent is attached. Drawing is
  /// best effort: an overlay failure never reaches the input path.
  void _drawInput(void Function(_ScoutDrivingOverlay overlay) draw) {
    final overlay = _drivingOverlay;
    if (!overlay._live) return;
    overlay.drawWhenFree(() {
      try {
        draw(overlay);
      } catch (_) {
        // Purely visual; the input itself is unaffected.
      }
    });
  }

  /// The app's own pending frame callbacks: the binding's count minus the
  /// driving overlay's ticker, so stability and settle signals never wait on
  /// Scout's own drawing.
  int get _appTransientCallbackCount {
    final count = WidgetsBinding.instance.transientCallbackCount;
    return _drivingOverlay.tickScheduled ? math.max(0, count - 1) : count;
  }

  /// `ext.flutter_scout.agentOverlay`: the agent connection's presence.
  /// `attach` starts or renews a lease (the agent renews while connected),
  /// `detach` fades the layer out, `hide`/`show` bracket a native screenshot,
  /// `status` only reports. Debug-only like every other helper extension.
  Future<developer.ServiceExtensionResponse> _handleAgentOverlay(
    String method,
    Map<String, String> params,
  ) async {
    final overlay = _drivingOverlay;
    switch (params['action'] ?? 'status') {
      case 'attach':
        final leaseMs = int.tryParse(params['leaseMs'] ?? '') ?? 6000;
        overlay.attach(
          leaseMs: leaseMs.clamp(1000, 120000).toInt(),
          reduced: params['motion'] == 'reduced',
        );
      case 'detach':
        overlay.detach();
      case 'hide':
        overlay.beginCaptureHide();
        await _settleOverlayFrames();
      case 'show':
        overlay.endCaptureHide();
    }
    return _ok({'overlay': overlay.status()});
  }

  /// Waits until a frame drawn without the overlay has been composited.
  Future<void> _settleOverlayFrames() async {
    await _settleMutationFrames();
    await _settleMutationFrames();
  }
}
