// test/widgets/node_tile_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/widgets/node_tile.dart';

ProxyNode _node({int? delayMs}) => ProxyNode(
      id: 'a',
      remark: '🇯🇵 Japan',
      protocol: 'vless',
      rawLink: 'a',
      sourceSubId: 'manual',
      delayMs: delayMs,
    );

void main() {
  testWidgets('shows remark, protocol badge, and green delay text under 150ms', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: NodeTile(node: _node(delayMs: 80)))));

    expect(find.text('🇯🇵 Japan'), findsOneWidget);
    expect(find.text('VLESS'), findsOneWidget);
    expect(find.text('80ms'), findsOneWidget);
  });

  testWidgets('shows 超时 for a timed-out node (delayMs == -1)', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: NodeTile(node: _node(delayMs: -1)))));
    expect(find.text('超时'), findsOneWidget);
  });

  testWidgets('shows 未测速 for an untested node (delayMs == null)', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: NodeTile(node: _node()))));
    expect(find.text('未测速'), findsOneWidget);
  });
}
