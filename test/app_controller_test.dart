import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tarmac/app_controller.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/storage_service.dart';
import 'package:tarmac/services/subscription_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import 'fakes/fake_connectivity_probe.dart';
import 'fakes/fake_v2ray_gateway.dart';

ProxyNode _testNode(String link, int delayMs) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
      delayMs: delayMs,
    );

AppController _buildController({
  http.Client? httpClient,
  FakeV2rayGateway? gateway,
  FakeConnectivityProbe? probe,
}) {
  final v2rayGateway = gateway ?? FakeV2rayGateway();
  final v2rayService = V2rayService(v2rayGateway);
  return AppController(
    storage: StorageService(),
    subscriptionService: SubscriptionService(),
    v2rayService: v2rayService,
    smartConnect: SmartConnectService(v2rayService, probe ?? FakeConnectivityProbe()),
    httpClient: httpClient ?? MockClient((_) async => http.Response('', 404)),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loadInitial populates subscriptions from storage defaults', () async {
    final controller = _buildController();
    await controller.loadInitial();
    expect(controller.subscriptions, hasLength(4));
  });

  test('refreshSubscriptions fetches all enabled subs and dedupes nodes across them', () async {
    final body = 'vless://shared@x:443#Shared\nvless://only-a@x:443#OnlyA';
    final client = MockClient((request) async => http.Response(body, 200));
    final controller = _buildController(httpClient: client);
    await controller.loadInitial();

    await controller.refreshSubscriptions();

    // 4 default subs x 2 links each = 8 raw, but 'shared' link repeats
    // across every source and must collapse to a single node.
    final ids = controller.nodes.map((n) => n.id).toSet();
    expect(ids, contains('vless://shared@x:443#Shared'));
    expect(ids, contains('vless://only-a@x:443#OnlyA'));
    expect(controller.nodes.length, ids.length);
  });

  test('a subscription that fails to fetch records lastError without blocking others', () async {
    var call = 0;
    final client = MockClient((request) async {
      call++;
      if (call == 1) return http.Response('', 404);
      return http.Response('vless://ok@x:443#OK', 200);
    });
    final controller = _buildController(httpClient: client);
    await controller.loadInitial();

    await controller.refreshSubscriptions();

    expect(controller.subscriptions.first.lastError, isNotNull);
    expect(controller.nodes, isNotEmpty);
  });

  test('smartConnectNow with no tested nodes yields a friendly noCandidates status', () async {
    final controller = _buildController();
    await controller.loadInitial();

    await controller.smartConnectNow();

    expect(controller.statusMessage, contains('先测速'));
  });

  test('smartConnectNow success updates connectedNode and status message', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [true]);
    final controller = _buildController(gateway: gateway, probe: probe);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      _testNode('vless://a', 10),
    ]);

    await controller.smartConnectNow();

    expect(controller.connectedNode?.id, 'vless://a');
    expect(controller.statusMessage, contains('已连接'));
  });

  test('disconnectNow cancels an in-flight smart connect and resets status', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    probe.pending = Completer<bool>(); // first check() hangs until completed below
    final controller = _buildController(gateway: gateway, probe: probe);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_testNode('vless://a', 10)]);

    final future = controller.smartConnectNow();
    await Future<void>.delayed(Duration.zero);
    await controller.disconnectNow();
    // Let the still-pending probe resolve so smartConnectNow's awaited
    // connectBest() can observe the cancellation and return.
    probe.pending!.complete(true);
    await future;

    expect(controller.connectedNode, isNull);
    expect(controller.statusMessage, '未连接');
  });
}
