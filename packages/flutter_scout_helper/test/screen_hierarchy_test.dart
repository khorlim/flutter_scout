import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('nested screen ancestry survives brief and orientation output', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: _EditorScreen(child: _InfoPage())),
    );
    final runtime = FlutterScoutRuntime();
    final snapshot = runtime.debugSnapshot();
    expect(snapshot.screen, '_InfoPage');
    expect(snapshot.screenEvidence['screenCandidates'], <String>[
      '_InfoPage',
      '_EditorScreen',
    ]);
    expect(
      snapshot.screenEvidence['candidateScope'],
      'primary_widget_ancestry',
    );
    expect(
      snapshot.screenEvidence['candidateBoundary'],
      'nearest_overlay_or_navigator',
    );
    expect(snapshot.screenEvidence['candidatesTruncated'], isFalse);
    expect(
      runtime.debugInspectPayload(brief: true)['screenEvidence'],
      snapshot.screenEvidence,
    );
    final where = await runtime.debugWhere();
    expect(where['screenEvidence'], snapshot.screenEvidence);
    expect(runtime.debugWaitForConditionsMet({'screen': '_InfoPage'}), isTrue);
    expect(
      runtime.debugWaitForConditionsMet({'screen': '_EditorScreen'}),
      isFalse,
      reason: 'ancestry is orientation evidence, not an expectation alias',
    );
  });

  testWidgets('hidden siblings and outer navigator shells are not candidates', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _EditorScreen(
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Stack(
                children: [
                  _InfoPage(),
                  Offstage(child: _HiddenPage()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final snapshot = FlutterScoutRuntime().debugSnapshot();
    expect(snapshot.screen, '_InfoPage');
    expect(snapshot.screenEvidence['screenCandidates'], ['_InfoPage']);
  });

  testWidgets('pushed routes do not inherit the covered screen identity', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const _EditorScreen(child: _InfoPage()),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const _OtherPage()),
    );
    await tester.pumpAndSettle();
    final snapshot = FlutterScoutRuntime().debugSnapshot();
    expect(snapshot.screen, '_OtherPage');
    expect(snapshot.screenEvidence['screenCandidates'], ['_OtherPage']);
  });

  testWidgets('modal identity does not expose underlying screen ancestry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: _EditorScreen(child: _InfoPage())),
    );
    showDialog<void>(
      context: tester.element(find.byType(_InfoPage)),
      builder: (_) => const AlertDialog(
        title: Text('Confirm edit'),
        content: Text('Modal evidence'),
      ),
    );
    await tester.pumpAndSettle();
    final runtime = FlutterScoutRuntime();
    final snapshot = runtime.debugSnapshot();
    expect(snapshot.screenEvidence['source'], 'active_surface');
    expect(snapshot.screenEvidence.containsKey('screenCandidates'), isFalse);
    expect(runtime.debugWaitForConditionsMet({'screen': '_InfoPage'}), isFalse);
    expect(
      runtime.debugWaitForConditionsMet({'screen': '_EditorScreen'}),
      isFalse,
    );
  });

  testWidgets('ancestry is bounded and reports truncation', (tester) async {
    Widget child = const _InfoPage();
    for (var index = 0; index < 12; index++) {
      child = _EditorScreen(child: child);
    }
    await tester.pumpWidget(MaterialApp(home: child));
    final evidence = FlutterScoutRuntime().debugSnapshot().screenEvidence;
    expect(evidence['screenCandidates'], hasLength(8));
    expect(evidence['candidateLimit'], 8);
    expect(evidence['candidatesTruncated'], isTrue);
  });
}

class _EditorScreen extends StatelessWidget {
  const _EditorScreen({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _InfoPage extends StatelessWidget {
  const _InfoPage();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Edit info'));
}

class _HiddenPage extends StatelessWidget {
  const _HiddenPage();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Hidden'));
}

class _OtherPage extends StatelessWidget {
  const _OtherPage();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Other'));
}
