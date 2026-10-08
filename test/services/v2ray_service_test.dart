import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/v2ray_gateway.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_v2ray_gateway.dart';

ProxyNode _node(String link) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
    );

/// 比 [FakeV2rayGateway] 更细的可控 fake：闸门按 link 单独设置，可以只挂起某个
/// 节点的 `getServerDelay` 直到放行，其余节点立刻返回。用于验证 worker 池
/// 「慢节点只占住自己那个 worker、不阻塞别的 worker」这一核心语义。
/// `gates` 里没有的 link 立即返回 `script[link]`（缺省 null）。
class _ScriptedGateway implements V2rayGateway {
  _ScriptedGateway({
    this.script = const {},
    this.gates = const {},
  });

  final Map<String, int?> script;
  final Map<String, Completer<void>> gates;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<int?> getServerDelay(String rawLink) async {
    final gate = gates[rawLink];
    if (gate != null) await gate.future;
    return script[rawLink];
  }

  @override
  Future<void> start({required String remark, required String rawLink}) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<V2rayConnectionState> get stateStream => const Stream.empty();
}

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

    test('onProgress fires once per tested node with a full-length ordered snapshot', () async {
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

      // 滑动窗口 worker 池：每个节点测完各回调一次，共 20 次（不再是「每批一次」）。
      expect(snaps, hasLength(20));
      expect(doneCounts.toSet(), {for (var d = 1; d <= 20; d++) d});
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

    test('worker pool overlaps: a hung leading node does not block the others', () async {
      // 本次改动的核心区分点。挂起节点排在最前、并发设为 2：
      //   - 批次屏障实现：第一批 [hang, a] 被 hang 卡死，a 及其后节点永远拿不到结果；
      //   - worker 池实现：worker A 卡在 hang 上，worker B 继续把 a/b/c/d 全部测完。
      final hang = Completer<void>();
      final gateway = _ScriptedGateway(
        script: {'hang': null, 'a': 10, 'b': 10, 'c': 10, 'd': 10},
        gates: {'hang': hang},
      );
      final service = V2rayService(gateway);

      final links = ['hang', 'a', 'b', 'c', 'd'];
      final tested = <String>{};
      var finished = false;
      final future = service.testDelays(
        links.map(_node).toList(),
        concurrency: 2,
        onProgress: (current, done, total) {
          for (final n in current) {
            if (n.delayMs != null) tested.add(n.id);
          }
        },
      ).then((r) {
        finished = true;
        return r;
      });

      // 推进事件循环若干轮，但始终不放行 'hang'。
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      // 池化实现：其余节点此时已被 worker B 全部测完；批次屏障实现：这里 tested 为空。
      expect(tested, containsAll(<String>['a', 'b', 'c', 'd']));
      expect(tested, isNot(contains('hang')));
      expect(finished, isFalse, reason: 'hang 未放行，整体不应结束');

      hang.complete();
      final result = await future;
      expect(result, hasLength(5));
      expect(result.map((n) => n.id).toList(), links);
      expect(result.every((n) => n.delayMs != null), isTrue);
    });

    test('result length and order always equal the input, regardless of completion order',
        () async {
      // 三个节点各自挂起，按与输入相反的顺序放行：返回值仍须与输入同序等长。
      final c0 = Completer<void>();
      final c1 = Completer<void>();
      final c2 = Completer<void>();
      final gateway = _ScriptedGateway(
        script: {'x0': 100, 'x1': 200, 'x2': 300},
        gates: {'x0': c0, 'x1': c1, 'x2': c2},
      );
      final service = V2rayService(gateway);

      final future = service.testDelays(
        [_node('x0'), _node('x1'), _node('x2')],
        concurrency: 3,
      );
      await Future<void>.delayed(Duration.zero);
      c2.complete();                              // 先回 index 2
      await Future<void>.delayed(Duration.zero);
      c1.complete();                              // 再回 index 1
      await Future<void>.delayed(Duration.zero);
      c0.complete();                              // 最后回 index 0

      final result = await future;
      expect(result.map((n) => n.id).toList(), ['x0', 'x1', 'x2']);
      expect(result.map((n) => n.delayMs).toList(), [100, 200, 300]);
    });

    test('interrupted pool leaves untested nodes null, never -1', () async {
      final links = List.generate(10, (i) => 'link$i');
      final gateway = FakeV2rayGateway(
        delayScript: {for (final l in links) l: 5},
      );
      final service = V2rayService(gateway);

      // concurrency 1 -> 单 worker 顺序领任务：前 4 次检查放行（测 index 0..3），
      // 第 5 次返回 true 中止。
      var checks = 0;
      final result = await service.testDelays(
        links.map(_node).toList(),
        concurrency: 1,
        shouldStop: () => checks++ >= 4,
      );

      expect(result, hasLength(10));
      expect(result.map((n) => n.id).toList(), links);
      for (var i = 0; i < 4; i++) {
        expect(result[i].delayMs, 5);
      }
      for (var i = 4; i < 10; i++) {
        expect(result[i].delayMs, isNull, reason: '未测到的节点绝不能是 -1');
      }
    });

    test('empty input returns an empty list', () async {
      final service = V2rayService(FakeV2rayGateway());
      expect(await service.testDelays(<ProxyNode>[]), isEmpty);
    });

    test('concurrency <= 0 is clamped to 1 and does not hang or throw', () async {
      final gateway = FakeV2rayGateway(delayScript: {'a': 1, 'b': 2});
      final service = V2rayService(gateway);

      final zero = await service.testDelays([_node('a'), _node('b')], concurrency: 0);
      expect(zero.map((n) => n.delayMs).toList(), [1, 2]);

      final negative = await service.testDelays([_node('a'), _node('b')], concurrency: -3);
      expect(negative.map((n) => n.delayMs).toList(), [1, 2]);
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
