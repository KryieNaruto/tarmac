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

    test('onProgress fires once per batch with a full-length ordered snapshot', () async {
      final links = List.generate(20, (i) => 'link$i');
      final script = {for (final l in links) l: 10};
      final gateway = FakeV2rayGateway(delayScript: script);
      final service = V2rayService(gateway);

      final snaps = <List<ProxyNode>>[];
      final doneCounts = <int>[];
      final result = await service.testDelays(
        links.map(_node).toList(),
        concurrency: 8,
        onProgress: (current, done, total) {
          snaps.add(current);
          doneCounts.add(done);
          expect(current, hasLength(total));
        },
      );

      // 20 nodes / concurrency 8 -> batches of 8, 8, 4 -> 3 callbacks
      expect(snaps, hasLength(3));
      expect(doneCounts, [8, 16, 20]);
      expect(doneCounts.last, 20);
      // 每次 current 都是完整长度且与输入顺序一致
      for (final snap in snaps) {
        expect(snap.map((n) => n.id).toList(), links);
      }
      expect(result.map((n) => n.id).toList(), links);
    });

    test('shouldStop aborts early but keeps the full-length result, untested nodes stay null', () async {
      final links = List.generate(20, (i) => 'link$i');
      final script = {for (final l in links) l: 10};
      final gateway = FakeV2rayGateway(delayScript: script);
      final service = V2rayService(gateway);

      // 前 3 次检查返回 false，之后开始返回 true -> 只跑完 3 批
      var checks = 0;
      final result = await service.testDelays(
        links.map(_node).toList(),
        concurrency: 1,
        shouldStop: () => checks++ >= 3,
      );

      expect(result, hasLength(20));
      expect(result.map((n) => n.id).toList(), links);
      for (var i = 0; i < 3; i++) {
        expect(result[i].delayMs, 10);
      }
      // 未测到的节点绝不能编造延迟
      for (var i = 3; i < 20; i++) {
        expect(result[i].delayMs, isNull);
      }
    });

    test('aborting mid-run never overwrites tested results with null', () async {
      final links = List.generate(20, (i) => 'link$i');
      final script = {for (final l in links) l: 7};
      final gateway = FakeV2rayGateway(delayScript: script);
      final service = V2rayService(gateway);

      final snaps = <List<ProxyNode>>[];
      var checks = 0;
      final result = await service.testDelays(
        links.map(_node).toList(),
        concurrency: 1,
        shouldStop: () => checks++ >= 3,
        onProgress: (current, done, total) => snaps.add(current),
      );

      // 最后一次进度快照与最终返回值都应保留已测的 3 个延迟
      for (final snap in [snaps.last, result]) {
        expect(snap, hasLength(20));
        for (var i = 0; i < 3; i++) {
          expect(snap[i].delayMs, 7);
        }
        for (var i = 3; i < 20; i++) {
          expect(snap[i].delayMs, isNull);
        }
      }
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
