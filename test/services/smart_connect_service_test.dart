// test/services/smart_connect_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_tunnel_probe.dart';
import '../fakes/fake_v2ray_gateway.dart';

ProxyNode _node(String link, int delayMs) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
      delayMs: delayMs,
    );

/// 校验目标的 host（与 [V2rayService.kVerifyUrls] 一致）。
const String _googleHost = 'www.google.com';
const String _twitterHost = 'twitter.com';

FakeTunnelProbe _allReachable() =>
    FakeTunnelProbe(reachable: const {_googleHost, _twitterHost});
FakeTunnelProbe _onlyGoogle() =>
    FakeTunnelProbe(reachable: const {_googleHost});
FakeTunnelProbe _nothingReachable() => FakeTunnelProbe();

void main() {
  test('connectAndVerify returns verified and keeps the tunnel when the core proxy succeeds', () async {
    final gateway = FakeV2rayGateway();
    final service =
        SmartConnectService(V2rayService(gateway, probe: _allReachable()));

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.verified);
    // 校验通过 → 保持连接，不得 disconnect（stop() 会把它清成 null）。
    expect(gateway.lastStartedRawLink, 'a');
  });

  test('connectAndVerify returns proxyUnavailable and disconnects when the core proxy yields no data',
      () async {
    final gateway = FakeV2rayGateway();
    final service =
        SmartConnectService(V2rayService(gateway, probe: _nothingReachable()));

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
    final gateway = FakeV2rayGateway(permissionGranted: false);
    final service =
        SmartConnectService(V2rayService(gateway, probe: _allReachable()));

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.permissionDenied);
    // connect 返回 false（权限被拒）→ 根本没起隧道，也就没必要 disconnect。
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('两个校验目标都通 → verified，且保持连接', () async {
    final gateway = FakeV2rayGateway();
    final service =
        SmartConnectService(V2rayService(gateway, probe: _allReachable()));

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.verified);
    // 全通 → 保持连接，不得 disconnect（stop() 会把它清成 null）。
    expect(gateway.lastStartedRawLink, 'a');
  });

  test('只有主目标（Google）通、Twitter 不通 → verifiedPartial，且仍保持连接', () async {
    final gateway = FakeV2rayGateway();
    final service =
        SmartConnectService(V2rayService(gateway, probe: _onlyGoogle()));

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.verifiedPartial);
    // 本改动的核心：partial 也必须保持连接，绝不能断。
    expect(gateway.lastStartedRawLink, 'a');
  });

  test('主目标就不通 → proxyUnavailable，且已断开', () async {
    final gateway = FakeV2rayGateway();
    final service =
        SmartConnectService(V2rayService(gateway, probe: _nothingReachable()));

    final outcome = await service.connectAndVerify(
      _node('a', 50),
      establishWindow: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(outcome, ConnectOutcome.proxyUnavailable);
    // 主目标不通 → 自己断开，不留半死的隧道。
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('多目标签名下未授权 → permissionDenied，且不起隧道', () async {
    final gateway = FakeV2rayGateway(permissionGranted: false);
    final service =
        SmartConnectService(V2rayService(gateway, probe: _allReachable()));

    final outcome = await service.connectAndVerify(_node('a', 50), pollInterval: Duration.zero);

    expect(outcome, ConnectOutcome.permissionDenied);
    expect(gateway.lastStartedRawLink, isNull);
  });
}
