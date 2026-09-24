// test/services/subscription_service_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/models/subscription.dart';
import 'package:tarmac/services/subscription_service.dart';

void main() {
  group('normalizeContent', () {
    test('decodes a base64 blob containing share links', () {
      final raw = 'trojan://a@b:443#x\nvless://c@d:443#y';
      final encoded = base64Encode(utf8.encode(raw));
      expect(normalizeContent(encoded), raw);
    });

    test('passes through plain-text share links unchanged', () {
      const raw = 'vless://c@d:443#y\nvmess://abc';
      expect(normalizeContent(raw), raw);
    });

    test('falls back to raw content for garbage that is not valid base64', () {
      const raw = 'not base64 at all !!! ###';
      expect(normalizeContent(raw), raw);
    });

    test('falls back to raw content when base64-decodable but not link-shaped', () {
      final encoded = base64Encode(utf8.encode('just some unrelated english text'));
      expect(normalizeContent(encoded), encoded);
    });
  });

  group('SubscriptionService.fetchAndParse', () {
    test('parses a base64 subscription body into nodes', () async {
      final raw = 'trojan://a@b:443#Node1\nvless://c@d:443#Node2';
      final body = base64Encode(utf8.encode(raw));
      final client = MockClient((request) async => http.Response(body, 200));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u1', name: 'S1', url: 'https://x/sub');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.error, isNull);
      expect(result.nodes, hasLength(2));
      expect(result.nodes.first.sourceSubId, 'u1');
      expect(result.nodes.first.remark, 'Node1');
    });

    test('parses a plain-text subscription body into nodes', () async {
      const body = 'vless://c@d:443#Node2\nvmess://not-valid!!!';
      final client = MockClient((request) async => http.Response(body, 200));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u2', name: 'S2', url: 'https://x/sub2');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.error, isNull);
      // one valid vless link + one vmess link with a degraded fallback remark
      expect(result.nodes, hasLength(2));
    });

    test('records lastError and yields zero nodes on HTTP failure, without throwing', () async {
      final client = MockClient((request) async => http.Response('', 404));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u3', name: 'S3', url: 'https://x/dead');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.nodes, isEmpty);
      expect(result.error, isNotNull);
    });

    test('records lastError and yields zero nodes on network exception', () async {
      final client = MockClient((request) async => throw Exception('network down'));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u4', name: 'S4', url: 'https://x/unreachable');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.nodes, isEmpty);
      expect(result.error, isNotNull);
    });

    test('empty/garbage body with no recognizable links yields zero nodes, no error thrown', () async {
      final client = MockClient((request) async => http.Response('<html>rate limited</html>', 200));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u5', name: 'S5', url: 'https://x/garbage');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.nodes, isEmpty);
    });
  });

  group('dedupeNodes', () {
    test('collapses the same rawLink appearing across two different subscriptions', () {
      final a = ProxyNode(id: 'vless://x', remark: 'A', protocol: 'vless', rawLink: 'vless://x', sourceSubId: 'sub-a');
      final b = ProxyNode(id: 'vless://x', remark: 'A-dup', protocol: 'vless', rawLink: 'vless://x', sourceSubId: 'sub-b');
      final c = ProxyNode(id: 'vless://y', remark: 'C', protocol: 'vless', rawLink: 'vless://y', sourceSubId: 'sub-b');

      final result = dedupeNodes([a, b, c]);

      expect(result, hasLength(2));
      expect(result.map((n) => n.id).toSet(), {'vless://x', 'vless://y'});
    });
  });
}
