// test/models/proxy_node_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';

void main() {
  test('ProxyNode round-trips through JSON', () {
    final node = ProxyNode(
      id: 'vmess://abc',
      remark: '🇯🇵 Japan',
      protocol: 'vmess',
      rawLink: 'vmess://abc',
      sourceSubId: 'sub-1',
      delayMs: 120,
      lastTestedAt: DateTime.utc(2026, 9, 24, 12, 0, 0),
    );

    final restored = ProxyNode.fromJson(node.toJson());

    expect(restored.id, node.id);
    expect(restored.remark, node.remark);
    expect(restored.protocol, node.protocol);
    expect(restored.rawLink, node.rawLink);
    expect(restored.sourceSubId, node.sourceSubId);
    expect(restored.delayMs, 120);
    expect(restored.lastTestedAt, DateTime.utc(2026, 9, 24, 12, 0, 0));
  });

  test('ProxyNode handles null delayMs and lastTestedAt', () {
    final node = ProxyNode(
      id: 'vless://xyz',
      remark: 'test',
      protocol: 'vless',
      rawLink: 'vless://xyz',
      sourceSubId: 'manual',
    );

    final restored = ProxyNode.fromJson(node.toJson());

    expect(restored.delayMs, isNull);
    expect(restored.lastTestedAt, isNull);
  });

  test('copyWith overrides only given fields', () {
    final node = ProxyNode(
      id: 'a',
      remark: 'r',
      protocol: 'ss',
      rawLink: 'a',
      sourceSubId: 'manual',
    );
    final updated = node.copyWith(delayMs: 55);
    expect(updated.delayMs, 55);
    expect(updated.remark, 'r');
  });
}
