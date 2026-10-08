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

    // 以下为「重试 / 超时」行为测试。为避免真等退避时间，
    // 重试类测试一律传 retryBackoff: Duration.zero。

    test('retries once after a connection failure and succeeds on the second attempt', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) throw http.ClientException('connection reset');
        return http.Response('vless://a@x:443#A', 200);
      });
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'r1', name: 'R1', url: 'https://x/retry');

      final result =
          await service.fetchAndParse(sub, client: client, retryBackoff: Duration.zero);

      expect(result.nodes, isNotEmpty);
      expect(result.error, isNull);
      expect(calls, 2);
    });

    test('gives up after all attempts fail, with exactly maxAttempts calls', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        throw http.ClientException('connection reset');
      });
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'r2', name: 'R2', url: 'https://x/down');

      final result =
          await service.fetchAndParse(sub, client: client, retryBackoff: Duration.zero);

      expect(result.nodes, isEmpty);
      expect(result.error, isNotNull);
      expect(calls, 2);
    });

    test('does not retry on 404 (client error)', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('', 404);
      });
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'r3', name: 'R3', url: 'https://x/missing');

      final result =
          await service.fetchAndParse(sub, client: client, retryBackoff: Duration.zero);

      expect(result.error, contains('404'));
      expect(calls, 1);
    });

    test('retries on HTTP 500 and succeeds on the second attempt', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response('', 500);
        return http.Response('vless://a@x:443#A', 200);
      });
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'r4', name: 'R4', url: 'https://x/flaky');

      final result =
          await service.fetchAndParse(sub, client: client, retryBackoff: Duration.zero);

      expect(result.nodes, isNotEmpty);
      expect(result.error, isNull);
      expect(calls, 2);
    });

    test('maxAttempts: 1 disables retries', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('', 500);
      });
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'r5', name: 'R5', url: 'https://x/once');

      final result = await service.fetchAndParse(
        sub,
        client: client,
        maxAttempts: 1,
        retryBackoff: Duration.zero,
      );

      expect(calls, 1);
      expect(result.error, isNotNull);
    });

    test('enforces the per-attempt timeout', () async {
      final client = MockClient((request) async {
        await Future.delayed(const Duration(milliseconds: 200));
        return http.Response('', 200);
      });
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'r6', name: 'R6', url: 'https://x/slow');

      final result = await service.fetchAndParse(
        sub,
        client: client,
        timeout: const Duration(milliseconds: 20),
        maxAttempts: 1,
      );

      expect(result.error, isNotNull);
      // 宽匹配：具体的超时异常文案随 SDK 变化，不去钉死。
      expect(result.error, contains('imeout'));
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

  group('sortByDelay', () {
    ProxyNode withDelay(String remark, int? delay) => ProxyNode(
          id: remark,
          remark: remark,
          protocol: 'vless',
          rawLink: 'vless://$remark',
          sourceSubId: 'manual',
          delayMs: delay,
        );

    test('usable nodes sorted ascending by delay, null/timeout sink to the tail', () {
      final nodes = [
        withDelay('a', 300),
        withDelay('b', null),
        withDelay('c', 50),
        withDelay('d', -1),
        withDelay('e', 100),
      ];

      final result = sortByDelay(nodes);

      expect(result.map((n) => n.remark).toList(), ['c', 'e', 'a', 'b', 'd']);
    });

    test('untested/timed-out nodes keep their original relative order at the tail', () {
      final nodes = [
        withDelay('fast', 20),
        withDelay('x', null),
        withDelay('y', -1),
        withDelay('z', null),
        withDelay('slow', 900),
      ];

      final result = sortByDelay(nodes);

      expect(result.take(2).map((n) => n.remark), ['fast', 'slow']);
      expect(result.skip(2).map((n) => n.remark).toList(), ['x', 'y', 'z']);
    });

    test('all-null and empty lists do not throw', () {
      expect(sortByDelay(const []), isEmpty);
      final allNull = [withDelay('a', null), withDelay('b', null)];
      expect(sortByDelay(allNull).map((n) => n.remark).toList(), ['a', 'b']);
    });

    test('does not mutate the input list', () {
      final nodes = [
        withDelay('a', 300),
        withDelay('b', null),
        withDelay('c', 50),
      ];
      final before = nodes.map((n) => n.remark).toList();

      sortByDelay(nodes);

      expect(nodes.map((n) => n.remark).toList(), before);
    });
  });
}
