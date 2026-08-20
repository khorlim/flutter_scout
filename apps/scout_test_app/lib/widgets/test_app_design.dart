import 'package:flutter/widgets.dart';

/// Minimal layout tokens shared by new Scout Test App fixtures.
///
/// The older stress screens predate a token layer. New fixtures use these
/// values so spacing remains named and reviewable rather than accumulating
/// unrelated literals.
abstract final class TestAppLayout {
  static const double compactGap = 8;
  static const double contentGap = 12;
  static const double sectionGap = 32;
  static const EdgeInsets screenPadding = EdgeInsets.all(16);
}
