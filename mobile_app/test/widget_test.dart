import 'package:flutter_test/flutter_test.dart';
import 'package:massengar/core/theme/app_theme.dart';

void main() {
  test('AppTheme loads darkTheme without errors', () {
    final theme = AppTheme.darkTheme;
    expect(theme.scaffoldBackgroundColor, AppTheme.background);
    expect(theme.primaryColor, AppTheme.primary);
  });
}
