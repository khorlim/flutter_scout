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
      });
    }
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
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _selectAt(details.localPosition),
                  child: CustomPaint(
                    painter: _FlutterScoutAnnotationPainter(
                      targets: _visibleTargets,
                      annotationPins: widget.runtime._annotationPins(
                        _visibleTargets,
                      ),
                      selectedTarget: _selectedTarget,
                      colorScheme: Theme.of(context).colorScheme,
                      annotationRevision: revision,
                    ),
                  ),
                ),
              ),
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
            if (enabled &&
                _selectedTarget == null &&
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
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: enabled ? scheme.primary : scheme.surface,
      elevation: 6,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.edit_note,
                color: enabled ? scheme.onPrimary : scheme.onSurface,
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: enabled ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: sent ? scheme.tertiary : scheme.primary,
        foregroundColor: sent ? scheme.onTertiary : scheme.onPrimary,
      ),
      icon: Icon(sent ? Icons.check_circle : Icons.send),
      label: Text(sent ? 'Sent to agent' : 'Send $count to agent'),
    );
  }
}

class _AnnotationCommentPanel extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Positioned(
      left: 12,
      right: 12,
      bottom: MediaQuery.paddingOf(context).bottom + 12,
      child: Material(
        color: scheme.surface,
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                target.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${target.widgetType} - ${candidateIndex + 1} of $candidateCount',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Comment',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.newline,
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: onCancel, child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: onSave,
                    icon: const Icon(Icons.check),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlutterScoutAnnotationPainter extends CustomPainter {
  const _FlutterScoutAnnotationPainter({
    required this.targets,
    required this.annotationPins,
    required this.selectedTarget,
    required this.colorScheme,
    required this.annotationRevision,
  });

  final List<ScoutAnnotationTarget> targets;
  final List<({Rect rect, String status})> annotationPins;
  final ScoutAnnotationTarget? selectedTarget;
  final ColorScheme colorScheme;
  final int annotationRevision;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = colorScheme.scrim.withValues(alpha: 0.08);
    canvas.drawRect(Offset.zero & size, scrim);

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colorScheme.primary.withValues(alpha: 0.28);
    for (final target in targets.take(220)) {
      canvas.drawRect(target.rect, outline);
    }

    final selected = selectedTarget;
    if (selected != null) {
      final selectedPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = colorScheme.primary;
      canvas.drawRect(selected.rect, selectedPaint);
    }

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    for (var i = 0; i < annotationPins.length; i++) {
      final pin = annotationPins[i];
      final rect = pin.rect;
      final center = Offset(rect.left + 10, rect.top + 10);
      final pinColor = _pinColor(pin.status);
      canvas.drawCircle(center, 10, Paint()..color = pinColor);
      textPainter.text = TextSpan(
        text: '${i + 1}',
        style: TextStyle(
          color: _onPinColor(pin.status),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      );
      textPainter.layout(minWidth: 20, maxWidth: 20);
      textPainter.paint(canvas, center - const Offset(10, 7));
    }
  }

  Color _pinColor(String status) {
    switch (status) {
      case 'pending_review':
        return const Color(0xFFFFB300); // amber: agent says fixed, review me
      case 'stale_target':
        return colorScheme.error;
      default:
        return colorScheme.tertiary;
    }
  }

  Color _onPinColor(String status) {
    switch (status) {
      case 'pending_review':
        return const Color(0xFF3E2723);
      case 'stale_target':
        return colorScheme.onError;
      default:
        return colorScheme.onTertiary;
    }
  }

  @override
  bool shouldRepaint(covariant _FlutterScoutAnnotationPainter oldDelegate) {
    return oldDelegate.targets != targets ||
        oldDelegate.annotationPins != annotationPins ||
        oldDelegate.selectedTarget != selectedTarget ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.annotationRevision != annotationRevision;
  }
}

