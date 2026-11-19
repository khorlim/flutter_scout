import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a feature key above a control is an extra handle; its label stays primary',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                KeyedSubtree(
                  key: const ValueKey<String>('feature.home.tile_member'),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: ElevatedButton(
                      onPressed: () {},
                      child: const Text('Member'),
                    ),
                  ),
                ),
                ElevatedButton(onPressed: () {}, child: const Text('Orders')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final nodes = FlutterScoutHelper.debugRuntime
          .debugSnapshot()
          .interactables;
      final member = nodes.singleWhere((node) => node.label == 'Member');
      expect(member.id, 'btn.member');
      expect(member.altIds, contains('btn.feature_home_tile_member'));
      final orders = nodes.singleWhere((node) => node.label == 'Orders');
      expect(orders.altIds.where((id) => id.contains('feature')), isEmpty);
    },
  );
}
