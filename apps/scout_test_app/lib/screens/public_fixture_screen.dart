import 'dart:async';

import 'package:flutter/material.dart';

import '../evaluation_oracle/public_fixture_configuration.dart';
import '../widgets/test_app_design.dart';

/// A bounded parametric renderer for the public evaluation corpus.
///
/// Visible interaction state stays in this widget. Ground truth is emitted
/// only through the supplied app-domain callbacks, which are wired to the
/// authenticated evaluator oracle rather than to Flutter Scout responses.
class PublicFixtureScreen extends StatefulWidget {
  const PublicFixtureScreen({
    required this.configuration,
    required this.onCompletion,
    required this.onForbiddenAction,
    required this.onModalChanged,
    super.key,
  });

  final PublicFixtureConfiguration configuration;
  final ValueChanged<String> onCompletion;
  final VoidCallback onForbiddenAction;
  final ValueChanged<bool> onModalChanged;

  @override
  State<PublicFixtureScreen> createState() => _PublicFixtureScreenState();
}

class _PublicFixtureScreenState extends State<PublicFixtureScreen> {
  late final TextEditingController _inputController;
  String? _selectedValue;
  bool _prepared = false;
  bool _completionPending = false;
  bool _completed = false;
  double _sliderValue = 0;
  int _fixtureEpoch = 0;

  PublicFixtureConfiguration get fixture => widget.configuration;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();
    _scheduleInitialModal();
  }

  @override
  void didUpdateWidget(covariant PublicFixtureScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration.taskId == fixture.taskId &&
        oldWidget.configuration.seed == fixture.seed) {
      return;
    }
    _fixtureEpoch += 1;
    _inputController.clear();
    _selectedValue = null;
    _prepared = false;
    _completionPending = false;
    _completed = false;
    _sliderValue = 0;
    _scheduleInitialModal();
  }

  void _scheduleInitialModal() {
    if (fixture.initialModalOpen) {
      final epoch = _fixtureEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || epoch != _fixtureEpoch) return;
        unawaited(
          fixture.family == 'dialogs_sheets_menus'
              ? _openOverlay()
              : _openInitialNotice(),
        );
      });
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (_completionPending || _completed) {
      widget.onForbiddenAction();
      return;
    }
    final epoch = _fixtureEpoch;
    final completionValue = fixture.completionValue;
    setState(() => _completionPending = true);
    if (fixture.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: fixture.delayMs));
    }
    if (!mounted || epoch != _fixtureEpoch) return;
    _completed = true;
    widget.onCompletion(completionValue);
    setState(() => _completionPending = false);
  }

  void _completeForm() {
    if (_inputController.text != fixture.inputValue) {
      widget.onForbiddenAction();
      return;
    }
    unawaited(_complete());
  }

  Key? get _targetKey =>
      fixture.labelOnlyTarget ? null : const ValueKey('fixture_target');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: ValueKey('public_fixture.${fixture.taskId}'),
      appBar: AppBar(
        title: Text(fixture.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: TestAppLayout.compactGap),
            child: Text(
              '${fixture.family} · ${fixture.variantId}',
              key: const ValueKey('fixture_identity'),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: TestAppLayout.screenPadding,
          child: _buildFamily(context),
        ),
      ),
    );
  }

  Widget _buildFamily(BuildContext context) => switch (fixture.family) {
    'forms' => _formFixture(obscure: false),
    'lists' => _listFixture(),
    'grids' => _gridFixture(),
    'nested_scroll' => _nestedScrollFixture(),
    'tabs' => _tabsFixture(),
    'dialogs_sheets_menus' => _overlayFixture(),
    'pickers' => _pickerFixture(),
    'custom_painted' => _paintedFixture(context),
    'gesture' => _gestureFixture(),
    'lifecycle_reconnect' => _lifecycleFixture(),
    'faults' => _faultFixture(context),
    'security_privacy' => _formFixture(obscure: true),
    _ => const Center(child: Text('Unsupported public fixture')),
  };

  Widget _formFixture({required bool obscure}) {
    return ListView(
      key: const ValueKey('fixture_form'),
      children: <Widget>[
        Text('Complete this deterministic ${fixture.patternId} task.'),
        const SizedBox(height: TestAppLayout.contentGap),
        TextField(
          key: const ValueKey('fixture_input'),
          controller: _inputController,
          autofocus: fixture.initialFocus,
          obscureText: obscure,
          decoration: InputDecoration(
            labelText: fixture.inputLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: TestAppLayout.contentGap),
        FilledButton(
          key: _targetKey,
          onPressed: _completeForm,
          child: Text(fixture.targetLabel),
        ),
        TextButton(
          key: const ValueKey('fixture_decoy'),
          onPressed: widget.onForbiddenAction,
          child: Text(fixture.decoyLabel),
        ),
      ],
    );
  }

  Widget _listFixture() {
    return ListView.builder(
      key: const ValueKey('fixture_list'),
      itemCount: fixture.contentLength,
      itemBuilder: (context, index) {
        final isTarget = index == fixture.targetIndex;
        final isDecoy =
            index == (fixture.targetIndex + 1) % fixture.contentLength;
        final label = isTarget
            ? fixture.targetLabel
            : isDecoy
            ? fixture.decoyLabel
            : '${fixture.title} item ${index + 1}';
        return ListTile(
          key: isTarget ? _targetKey : null,
          title: Text(label),
          trailing: Text('#${index + 1}'),
          onTap: isTarget
              ? () => unawaited(_complete())
              : widget.onForbiddenAction,
        );
      },
    );
  }

  Widget _gridFixture() {
    return GridView.builder(
      key: const ValueKey('fixture_grid'),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 104,
        crossAxisSpacing: TestAppLayout.compactGap,
        mainAxisSpacing: TestAppLayout.compactGap,
      ),
      itemCount: fixture.contentLength,
      itemBuilder: (context, index) {
        final isTarget = index == fixture.targetIndex;
        final label = isTarget
            ? fixture.targetLabel
            : index == (fixture.targetIndex + 1) % fixture.contentLength
            ? fixture.decoyLabel
            : '${fixture.title} tile ${index + 1}';
        return Card(
          child: InkWell(
            key: isTarget ? _targetKey : null,
            onTap: isTarget
                ? () => unawaited(_complete())
                : widget.onForbiddenAction,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(TestAppLayout.compactGap),
                child: Text(label, textAlign: TextAlign.center),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _nestedScrollFixture() {
    final rowCount = (fixture.contentLength / 6).ceil();
    return ListView.builder(
      key: const ValueKey('fixture_nested_scroll'),
      itemCount: rowCount,
      itemBuilder: (context, row) => Padding(
        padding: const EdgeInsets.only(bottom: TestAppLayout.contentGap),
        child: SizedBox(
          height: 112,
          child: ListView.builder(
            key: ValueKey('fixture_carousel_$row'),
            scrollDirection: Axis.horizontal,
            itemCount: 6,
            itemBuilder: (context, column) {
              final index = row * 6 + column;
              if (index >= fixture.contentLength) {
                return const SizedBox.shrink();
              }
              final isTarget = index == fixture.targetIndex;
              return SizedBox(
                width: 180,
                child: Card(
                  child: InkWell(
                    key: isTarget ? _targetKey : null,
                    onTap: isTarget
                        ? () => unawaited(_complete())
                        : widget.onForbiddenAction,
                    child: Center(
                      child: Text(
                        isTarget
                            ? fixture.targetLabel
                            : '${fixture.title} ${index + 1}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tabsFixture() {
    final targetPage = fixture.seed.abs() % 3;
    return DefaultTabController(
      initialIndex: fixture.initialPage,
      length: 3,
      child: Column(
        children: <Widget>[
          const TabBar(
            tabs: <Widget>[
              Tab(text: 'Overview'),
              Tab(text: 'Details'),
              Tab(text: 'Actions'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                for (var page = 0; page < 3; page++)
                  Center(
                    child: page == targetPage
                        ? FilledButton(
                            key: _targetKey,
                            onPressed: () => unawaited(_complete()),
                            child: Text(fixture.targetLabel),
                          )
                        : TextButton(
                            onPressed: widget.onForbiddenAction,
                            child: Text('${fixture.title} page ${page + 1}'),
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _overlayFixture() {
    return Center(
      child: FilledButton(
        key: const ValueKey('fixture_open_overlay'),
        onPressed: _openOverlay,
        child: Text('Open ${fixture.title}'),
      ),
    );
  }

  Future<void> _openOverlay() async {
    widget.onModalChanged(true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(fixture.title),
          content: Text('Choose the task-specific target, not the decoy.'),
          actions: <Widget>[
            TextButton(
              key: const ValueKey('fixture_decoy'),
              onPressed: () {
                widget.onForbiddenAction();
                Navigator.of(dialogContext).pop();
              },
              child: Text(fixture.decoyLabel),
            ),
            FilledButton(
              key: _targetKey,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_complete());
              },
              child: Text(fixture.targetLabel),
            ),
          ],
        ),
      );
    } finally {
      widget.onModalChanged(false);
    }
  }

  Future<void> _openInitialNotice() async {
    widget.onModalChanged(true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Initial fixture state'),
          content: Text('Continue to the deterministic ${fixture.title} task.'),
          actions: <Widget>[
            FilledButton(
              key: const ValueKey('fixture_initial_modal_continue'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
    } finally {
      widget.onModalChanged(false);
    }
  }

  Widget _pickerFixture() {
    final choices = <String>[
      fixture.decoyLabel,
      fixture.targetLabel,
      '${fixture.title} alternate',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DropdownButtonFormField<String>(
          key: const ValueKey('fixture_picker'),
          initialValue: _selectedValue,
          decoration: InputDecoration(
            labelText: fixture.inputLabel,
            border: const OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<String>>[
            for (final choice in choices)
              DropdownMenuItem<String>(value: choice, child: Text(choice)),
          ],
          onChanged: (value) => setState(() => _selectedValue = value),
        ),
        const SizedBox(height: TestAppLayout.contentGap),
        FilledButton(
          key: _targetKey,
          onPressed: () {
            if (_selectedValue != fixture.targetLabel) {
              widget.onForbiddenAction();
              return;
            }
            unawaited(_complete());
          },
          child: const Text('Commit selection'),
        ),
      ],
    );
  }

  Widget _paintedFixture(BuildContext context) {
    return Center(
      child: Semantics(
        button: true,
        label: fixture.targetLabel,
        child: GestureDetector(
          key: _targetKey,
          onTap: () => unawaited(_complete()),
          onLongPress: widget.onForbiddenAction,
          child: CustomPaint(
            painter: _FixtureTargetPainter(
              color: Theme.of(context).colorScheme.primary,
              seed: fixture.seed,
            ),
            child: SizedBox(
              width: 260,
              height: 220,
              child: Center(
                child: Text(
                  fixture.targetLabel,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _gestureFixture() {
    if (fixture.patternId == 'drag-slider') {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(fixture.targetLabel),
          Slider(
            key: _targetKey,
            value: _sliderValue,
            onChanged: (value) {
              setState(() => _sliderValue = value);
              if (value >= 0.9) unawaited(_complete());
            },
          ),
        ],
      );
    }
    if (fixture.patternId == 'swipe-dismiss') {
      return Center(
        child: Dismissible(
          key: ValueKey('fixture_swipe.${fixture.taskId}'),
          onDismissed: (_) => unawaited(_complete()),
          child: ListTile(title: Text(fixture.targetLabel)),
        ),
      );
    }
    final requiresLongPress = fixture.patternId == 'long-press-target';
    return Center(
      child: GestureDetector(
        key: _targetKey,
        onTap: requiresLongPress
            ? widget.onForbiddenAction
            : () => unawaited(_complete()),
        onLongPress: requiresLongPress
            ? () => unawaited(_complete())
            : widget.onForbiddenAction,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(TestAppLayout.sectionGap),
            child: Text(
              '${requiresLongPress ? 'Long-press' : 'Activate'} '
              '${fixture.targetLabel}',
            ),
          ),
        ),
      ),
    );
  }

  Widget _lifecycleFixture() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        OutlinedButton(
          key: const ValueKey('fixture_prepare'),
          onPressed: () async {
            setState(() => _prepared = false);
            await Future<void>.delayed(
              Duration(
                milliseconds: fixture.delayMs == 0 ? 80 : fixture.delayMs,
              ),
            );
            if (mounted) setState(() => _prepared = true);
          },
          child: Text('Prepare ${fixture.title}'),
        ),
        const SizedBox(height: TestAppLayout.contentGap),
        FilledButton(
          key: _targetKey,
          onPressed: _prepared
              ? () => unawaited(_complete())
              : widget.onForbiddenAction,
          child: Text(fixture.targetLabel),
        ),
      ],
    );
  }

  Widget _faultFixture(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: TestAppLayout.screenPadding,
            child: Text(
              'Simulated public fault: ${fixture.title}. This fixture does '
              'not claim a real process or runtime failure.',
            ),
          ),
        ),
        const SizedBox(height: TestAppLayout.contentGap),
        FilledButton(
          key: _targetKey,
          onPressed: () => unawaited(_complete()),
          child: Text(fixture.targetLabel),
        ),
        TextButton(
          key: const ValueKey('fixture_decoy'),
          onPressed: widget.onForbiddenAction,
          child: const Text('Ignore simulated fault'),
        ),
      ],
    );
  }
}

class _FixtureTargetPainter extends CustomPainter {
  const _FixtureTargetPainter({required this.color, required this.seed});

  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    final inset = 12.0 + (seed.abs() % 24);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          inset,
          inset,
          size.width - inset * 2,
          size.height - inset * 2,
        ),
        const Radius.circular(24),
      ),
      paint,
    );
    canvas.drawCircle(size.center(Offset.zero), 28, paint);
  }

  @override
  bool shouldRepaint(_FixtureTargetPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.seed != seed;
}
