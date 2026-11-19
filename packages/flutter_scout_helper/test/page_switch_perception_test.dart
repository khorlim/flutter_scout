import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'after animateToPage the shown page is observed and tappable by handle, '
    'even when an ancestor rebuilt mid-animation',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final controller = PageController();
      addTearDown(controller.dispose);
      final taps = <String>[];
      await tester.pumpWidget(
        _PageSwitchApp(controller: controller, onTap: taps.add),
      );
      await tester.pumpAndSettle();
      final runtime = FlutterScoutHelper.debugRuntime;

      Set<String> labels() => {
        for (final node in runtime.debugSnapshot().interactables)
          if (node.label != null) node.label!,
      };

      Future<void> switchTo(int page) async {
        controller.animateToPage(
          page,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
        await tester.pumpAndSettle();
      }

      expect(labels(), containsAll(_home));

      await switchTo(1);
      expect(labels(), containsAll(_admin));
      expect(labels().intersection(_home.toSet()), isEmpty);

      await switchTo(0);
      // The page listener rebuilt the Scrollable while the drive activity was
      // ignoring pointers, so its IgnorePointer widget still says ignoring
      // after the activity ended, while its render object takes taps.
      final scrollableGate = tester.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byType(PageView),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(scrollableGate.ignoring, isTrue);
      final gateRender = tester.renderObject<RenderIgnorePointer>(
        find
            .descendant(
              of: find.byType(PageView),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(gateRender.ignoring, isFalse);

      expect(labels(), containsAll(_home));
      expect(labels().intersection(_admin.toSet()), isEmpty);
      final result = (await tester.runAsync(
        () => runtime.debugTapTarget('btn.attendance'),
      ))!;
      expect(result['ok'], isTrue, reason: '$result');
      expect(taps, ['Attendance']);
    },
  );
}

const _home = ['Member', 'Orders', 'Attendance'];
const _admin = ['Settings', 'Staff', 'Report'];

class _PageSwitchApp extends StatefulWidget {
  const _PageSwitchApp({required this.controller, required this.onTap});

  final PageController controller;
  final ValueChanged<String> onTap;

  @override
  State<_PageSwitchApp> createState() => _PageSwitchAppState();
}

class _PageSwitchAppState extends State<_PageSwitchApp> {
  // Like a Home/Admin segment that shows which page is current.
  int currentPage = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(() {
      final page = widget.controller.page?.toInt() ?? 0;
      if (page != currentPage) setState(() => currentPage = page);
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: Text(currentPage == 0 ? 'Home' : 'Admin')),
      body: PageView(
        controller: widget.controller,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _Page(labels: _home, onTap: widget.onTap),
          _Page(labels: _admin, onTap: widget.onTap),
        ],
      ),
    ),
  );
}

class _Page extends StatefulWidget {
  const _Page({required this.labels, required this.onTap});

  final List<String> labels;
  final ValueChanged<String> onTap;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        children: [
          for (final label in widget.labels)
            ElevatedButton(
              onPressed: () => widget.onTap(label),
              child: Text(label),
            ),
        ],
      ),
    );
  }
}
