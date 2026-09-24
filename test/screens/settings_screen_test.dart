import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/screens/settings_screen.dart';

void main() {
  testWidgets('shows the free-node risk disclaimer verbatim', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));

    expect(
      find.text('免费公益节点可能被运营方记录流量，不建议登录网银/重要账号'),
      findsOneWidget,
    );
  });
}
