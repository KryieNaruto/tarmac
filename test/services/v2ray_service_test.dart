import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_v2ray_gateway.dart';

ProxyNode _node(String link) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
    );

void main() {
  group('testDelays', () {
    test('fills in delayMs for each node, -1 for failed/timed-out ones', () async {
      final gateway = FakeV2rayGateway(delayScript: {'a': 50, 'b': null, 'c': 300});
      final service = V2rayService(gateway);

      final result = await service.testDelays([_node('a'), _node('b'), _node('c')]);

      final byId = {for (final n in result) n.id: n.delayMs};
      expect(byId['a'], 50);
      expect(byId['b'], -1);
      expect(byId['c'], 300);
    });

    test('sets lastTestedAt on every tested node', () async {
      final gateway = FakeV2rayGateway(delayScript: {'a': 50});
      final service = V2rayService(gateway);

      final result = await service.testDelays([_node('a')]);

      expect(result.single.lastTestedAt, isNotNull);
    });

    test('respects the concurrency cap without dropping any node', () async {
      final links = List.generate(20, (i) => 'link$i');
      final script = {for (final l in links) l: 10};
      final gateway = FakeV2rayGateway(delayScript: script);
      final service = V2rayService(gateway);

      final result = await service.testDelays(
        links.map(_node).toList(),
        concurrency: 8,
      );

      expect(result, hasLength(20));
      expect(result.every((n) => n.delayMs == 10), isTrue);
    });
  });

  group('connect/disconnect', () {
    test('connect() requests permission then starts, returns true on success', () async {
      final gateway = FakeV2rayGateway();
      final service = V2rayService(gateway);

      final ok = await service.connect(_node('a'));

      expect(ok, isTrue);
      expect(gateway.lastStartedRawLink, 'a');
    });

    test('connect() returns false without starting when permission denied', () async {
      final gateway = FakeV2rayGateway(permissionGranted: false);
      final service = V2rayService(gateway);

      final ok = await service.connect(_node('a'));

      expect(ok, isFalse);
      expect(gateway.lastStartedRawLink, isNull);
    });

    test('disconnect() stops the gateway', () async {
      final gateway = FakeV2rayGateway();
      final service = V2rayService(gateway);
      await service.connect(_node('a'));

      await service.disconnect();

      expect(gateway.lastStartedRawLink, isNull);
    });
  });
}
