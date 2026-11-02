import 'package:flutter/widgets.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Plain test(): no test binding exists before the initializer runs, as in an
  // app's main().
  test('outside debug the initializer still provides the widget binding', () {
    FlutterScoutBinding.debugEnsureInitializedOutsideDebug();
    expect(WidgetsBinding.instance, isA<WidgetsFlutterBinding>());
  });
}
