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
  test('connects to the lowest-latency candidate when its probe succeeds', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [true]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('slow', 300), _node('fast', 50)];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'fast');
    expect(gateway.lastStartedRawLink, 'fast');
  });

  test('falls through to the next candidate when the first probe fails', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [false, true]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('fast', 50), _node('slow', 300)];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'slow');
    expect(gateway.lastStartedRawLink, 'slow');
  });

  test('returns allFailed when every candidate probe fails', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [false, false]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 50), _node('b', 60)];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.allFailed);
    expect(gateway.lastStartedRawLink, isNull); // last attempt was stopped
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
    final probe = FakeConnectivityProbe(results: [false]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('only-candidate', 10), _node('excluded', 20)];

    final outcome = await service.connectBest(nodes, maxCandidates: 1);

    expect(outcome.result, SmartConnectResult.allFailed);
    // 'excluded' was never attempted because maxCandidates capped the list at 1
  });

  test('cancel() while a probe is pending stops the cascade and disconnects', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    probe.pending = Completer<bool>();
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 10), _node('b', 20)];

    final future = service.connectBest(nodes);
    // Let connectBest reach the pending probe, then cancel before it resolves.
    await Future<void>.delayed(Duration.zero);
    service.cancel();
    probe.pending!.complete(true); // even if it "would have" succeeded, cancel wins

    final outcome = await future;

    expect(outcome.result, SmartConnectResult.cancelled);
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('onAttempt callback fires once per candidate tried', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [false, true]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 10), _node('b', 20)];
    final attempted = <String>[];

    await service.connectBest(nodes, onAttempt: (n) => attempted.add(n.id));

    expect(attempted, ['a', 'b']);
  });
}
