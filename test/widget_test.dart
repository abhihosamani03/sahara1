// Basic smoke test for Sahara app.

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/theme.dart';
import 'package:itantra/ml/languages.dart';

void main() {
  test('Sahara theme loads', () {
    // Verify the dark theme is accessible.
    final theme = SaharaTheme.dark;
    expect(theme.brightness, isNotNull);
  });

  test('language constants are defined', () {
    expect(kLanguages, isNotEmpty);
    expect(kLanguages.length, greaterThanOrEqualTo(2));
  });
}
