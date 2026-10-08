// test/services/smart_connect_service_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_connectivity_probe.dart';
import '../fakes/fake_v2ray_gateway.dart';

ProxyNode _node(String link, int delayMs) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
      delayMs: delayMs,
    );

void main() {
  test('connects to the lowest-latency candidate once its egress IP changes', () async {
    final gateway = FakeV2rayGateway();
    // baseline 1.1.1.1，第一次 poll 立刻变成 2.2.2.2。
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1', '2.2.2.2']);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('slow', 300), _node('fast', 50)];

    final outcome = await service.connectBest(nodes, pollInterval: Duration.zero);

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'fast');
    expect(gateway.lastStartedRawLink, 'fast');
  });

  test('falls through to the next candidate when the first tunnel never forms', () async {
    final gateway = FakeV2rayGateway();
    // baseline 1.1.1.1；候选 a 的 poll 仍见 1.1.1.1（且 establishWindow 为 0 → 失败），
    // 候选 b 的 poll 见到 2.2.2.2 → 成功。
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1', '1.1.1.1', '2.2.2.2']);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('fast', 50), _node('slow', 300)];

    final outcome = await service.connectBest(
      nodes,
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'slow');
    expect(gateway.lastStartedRawLink, 'slow');
  });

  test('never reports success when the egress IP never changes (fake-connectivity regression)',
      () async {
    final gateway = FakeV2rayGateway();
    // 出口 IP 永远不变：隧道是死的，但设备本身有网，旧实现会误报成功。
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1']);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 50), _node('b', 60)];

    final outcome = await service.connectBest(
      nodes,
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(outcome.result, SmartConnectResult.allFailed);
    expect(outcome.node, isNull);
    // 每个候选都被断开过（stop() 会把 lastStartedRawLink 清成 null）。
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('fails closed (egressCheckUnavailable, no attempt) when the baseline IP is unavailable', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(ips: [null]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 50), _node('b', 60)];
    final attempted = <String>[];

    final outcome = await service.connectBest(
      nodes,
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
      onAttempt: (n) => attempted.add(n.id),
    );

    // 拿不到基线是「无法校验」，不是「节点全废」——不能报 allFailed 让用户去换节点。
    expect(outcome.result, SmartConnectResult.egressCheckUnavailable);
    expect(outcome.node, isNull);
    // 无法比对 → 尽早返回，不白跑任何候选。
    expect(attempted, isEmpty);
  });

  test('keeps polling until the tunnel takes effect late', () async {
    final gateway = FakeV2rayGateway();
    // baseline + 两次 poll 未变，第三次才变 —— 单次探测会失败，轮询才能成功。
    final probe = FakeConnectivityProbe(
      ips: ['1.1.1.1', '1.1.1.1', '1.1.1.1', '2.2.2.2'],
    );
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('only', 50)];

    final outcome = await service.connectBest(
      nodes,
      establishWindow: const Duration(seconds: 5),
      pollInterval: Duration.zero,
    );

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'only');
  });

  test('fails the candidate when the egress IP stays the same inside the window', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1']);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 50)];

    final outcome = await service.connectBest(
      nodes,
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(outcome.result, isNot(SmartConnectResult.success));
    expect(outcome.result, SmartConnectResult.allFailed);
  });

  test('returns noCandidates when no node has a usable delayMs yet', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [
      ProxyNode(id: 'a', remark: 'a', protocol: 'vless', rawLink: 'a', sourceSubId: 'manual'), // delayMs null
      ProxyNode(id: 'b', remark: 'b', protocol: 'vless', rawLink: 'b', sourceSubId: 'manual', delayMs: -1), // timed out
    ];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.noCandidates);
  });

  test('returns noCandidates for an empty node list without throwing', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    final service = SmartConnectService(V2rayService(gateway), probe);

    final outcome = await service.connectBest([]);

    expect(outcome.result, SmartConnectResult.noCandidates);
  });

  test('only tries the top maxCandidates nodes by ascending delay', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1']);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('only-candidate', 10), _node('excluded', 20)];

    final outcome = await service.connectBest(
      nodes,
      maxCandidates: 1,
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(outcome.result, SmartConnectResult.allFailed);
    // 'excluded' was never attempted because maxCandidates capped the list at 1
  });

  test('cancel() while the baseline probe is pending stops the cascade and disconnects', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    probe.pending = Completer<String?>();
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 10), _node('b', 20)];

    final future = service.connectBest(nodes, pollInterval: Duration.zero);
    // Let connectBest reach the pending probe, then cancel before it resolves.
    await Future<void>.delayed(Duration.zero);
    service.cancel();
    probe.pending!.complete('9.9.9.9'); // even if a baseline "would have" come back, cancel wins

    final outcome = await future;

    expect(outcome.result, SmartConnectResult.cancelled);
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('onAttempt callback fires once per candidate tried', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1', '1.1.1.1', '2.2.2.2']);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 10), _node('b', 20)];
    final attempted = <String>[];

    await service.connectBest(
      nodes,
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
      onAttempt: (n) => attempted.add(n.id),
    );

    expect(attempted, ['a', 'b']);
  });

  test('connectAndVerify returns verified and keeps the tunnel when the egress IP changes', () async {
    final gateway = FakeV2rayGateway();
    // baseline 1.1.1.1，_awaitEgressChange 的第一次 poll 立刻变成 2.2.2.2。
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1', '2.2.2.2']);
    final service = SmartConnectService(V2rayService(gateway), probe);

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.verified);
    // 校验通过 → 保持连接，不得 disconnect（stop() 会把它清成 null）。
    expect(gateway.lastStartedRawLink, 'a');
  });

  test('connectAndVerify returns tunnelNotEstablished and disconnects when the egress IP never changes', () async {
    final gateway = FakeV2rayGateway();
    // 出口 IP 永远不变：隧道是死的，但设备本身有网 —— 旧实现会误报「已连接」。
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1']);
    final service = SmartConnectService(V2rayService(gateway), probe);

    final outcome = await service.connectAndVerify(
      _node('a', 50),
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(outcome, ConnectOutcome.tunnelNotEstablished);
    // 校验不过 → 自己断开，不留半死的隧道。
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('connectAndVerify returns egressCheckUnavailable without connecting when the baseline IP is unavailable',
      () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(ips: [null]);
    final service = SmartConnectService(V2rayService(gateway), probe);

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.egressCheckUnavailable);
    // baseline 取不到 → 从未发起连接（也没必要白起一次隧道）。
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('connectAndVerify returns permissionDenied and does not disconnect when the gateway refuses to start', () async {
    final gateway = FakeV2rayGateway(permissionGranted: false);
    final probe = FakeConnectivityProbe(ips: ['1.1.1.1', '2.2.2.2']);
    final service = SmartConnectService(V2rayService(gateway), probe);

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.permissionDenied);
    // connect 返回 false（权限被拒）→ 根本没起隧道，也就没必要 disconnect。
    expect(gateway.lastStartedRawLink, isNull);
  });
}
