// test/services/smart_connect_service_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
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
  test('connects to the lowest-latency candidate once the core proxy reports a delay', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final service = SmartConnectService(V2rayService(gateway));
    final nodes = [_node('slow', 300), _node('fast', 50)];

    final outcome = await service.connectBest(nodes, pollInterval: Duration.zero);

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'fast');
    expect(gateway.lastStartedRawLink, 'fast');
  });

  test('falls through to the next candidate when the first node yields no data', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [-1, 50]);
    final service = SmartConnectService(V2rayService(gateway));
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

  test('never reports success when the core proxy keeps returning no data (fake-connectivity regression)',
      () async {
    final gateway = FakeV2rayGateway(connectedDelays: [-1]);
    final service = SmartConnectService(V2rayService(gateway));
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

  test('keeps polling until the core proxy succeeds late', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [-1, -1, 50]);
    final service = SmartConnectService(V2rayService(gateway));
    final nodes = [_node('only', 50)];

    final outcome = await service.connectBest(
      nodes,
      establishWindow: const Duration(seconds: 5),
      pollInterval: Duration.zero,
    );

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'only');
  });

  test('fails the candidate when the core proxy never yields data inside the window', () async {
    final gateway = FakeV2rayGateway(connectedDelays: []);
    final service = SmartConnectService(V2rayService(gateway));
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
    final service = SmartConnectService(V2rayService(gateway));
    final nodes = [
      ProxyNode(id: 'a', remark: 'a', protocol: 'vless', rawLink: 'a', sourceSubId: 'manual'), // delayMs null
      ProxyNode(id: 'b', remark: 'b', protocol: 'vless', rawLink: 'b', sourceSubId: 'manual', delayMs: -1), // timed out
    ];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.noCandidates);
  });

  test('returns noCandidates for an empty node list without throwing', () async {
    final gateway = FakeV2rayGateway();
    final service = SmartConnectService(V2rayService(gateway));

    final outcome = await service.connectBest([]);

    expect(outcome.result, SmartConnectResult.noCandidates);
  });

  test('only tries the top maxCandidates nodes by ascending delay', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [-1]);
    final service = SmartConnectService(V2rayService(gateway));
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

  test('cancel() while the core verification is pending stops the cascade and disconnects', () async {
    final gateway = FakeV2rayGateway();
    gateway.pending = Completer<int?>();
    final service = SmartConnectService(V2rayService(gateway));
    final nodes = [_node('a', 10), _node('b', 20)];

    final future = service.connectBest(nodes, pollInterval: Duration.zero);
    // Let connectBest reach the pending core call, then cancel before it resolves.
    await Future<void>.delayed(Duration.zero);
    service.cancel();
    gateway.pending!.complete(50); // even if a delay "would have" come back, cancel wins

    final outcome = await future;

    expect(outcome.result, SmartConnectResult.cancelled);
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('onAttempt callback fires once per candidate tried', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [-1, 50]);
    final service = SmartConnectService(V2rayService(gateway));
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

  test('connectAndVerify returns verified and keeps the tunnel when the core proxy succeeds', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final service = SmartConnectService(V2rayService(gateway));

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.verified);
    // 校验通过 → 保持连接，不得 disconnect（stop() 会把它清成 null）。
    expect(gateway.lastStartedRawLink, 'a');
  });

  test('connectAndVerify returns proxyUnavailable and disconnects when the core proxy yields no data',
      () async {
    final gateway = FakeV2rayGateway(connectedDelays: [-1]);
    final service = SmartConnectService(V2rayService(gateway));

    final outcome = await service.connectAndVerify(
      _node('a', 50),
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(outcome, ConnectOutcome.proxyUnavailable);
    // 校验不过 → 自己断开，不留半死的隧道。
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('connectAndVerify returns permissionDenied and does not disconnect when the gateway refuses to start', () async {
    final gateway = FakeV2rayGateway(permissionGranted: false, connectedDelays: [50]);
    final service = SmartConnectService(V2rayService(gateway));

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.permissionDenied);
    // connect 返回 false（权限被拒）→ 根本没起隧道，也就没必要 disconnect。
    expect(gateway.lastStartedRawLink, isNull);
  });
}
