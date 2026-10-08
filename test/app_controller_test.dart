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

/// 未测速节点（delayMs 为 null），用于测速/取消场景。
ProxyNode _rawNode(String link) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
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

  test('bootstrap() fetches subscriptions on the startup path (regression: node count was always 0)',
      () async {
    final client = MockClient((_) async => http.Response('vless://a@x:443#A', 200));
    final controller = _buildController(httpClient: client);

    await controller.bootstrap();

    expect(controller.nodes, isNotEmpty);
  });

  test('bootstrap() does not auto-test: no delay data is written', () async {
    final client = MockClient((_) async => http.Response('vless://a@x:443#A', 200));
    final controller = _buildController(httpClient: client);

    await controller.bootstrap();

    expect(controller.nodes, isNotEmpty);
    expect(controller.nodes.every((n) => n.delayMs == null), isTrue);
  });

  test('refreshSubscriptions(retest: false) leaves delays unset; retestAll backfills them', () async {
    final gateway = FakeV2rayGateway(delayScript: {'vless://a@x:443#A': 42});
    final client = MockClient((_) async => http.Response('vless://a@x:443#A', 200));
    final controller = _buildController(httpClient: client, gateway: gateway);
    await controller.loadInitial();

    await controller.refreshSubscriptions(retest: false);
    expect(controller.nodes, isNotEmpty);
    expect(controller.nodes.every((n) => n.delayMs == null), isTrue);

    await controller.retestAll();
    final node = controller.nodes.firstWhere((n) => n.rawLink == 'vless://a@x:443#A');
    expect(node.delayMs, 42);
  });

  test('retestAll sorts nodes by ascending delay', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://slow': 200, 'vless://fast': 50},
    );
    final controller = _buildController(gateway: gateway);
    controller.debugSetNodesForTest([
      _rawNode('vless://slow'),
      _rawNode('vless://fast'),
    ]);

    await controller.retestAll();

    expect(
      controller.nodes.map((n) => n.rawLink).toList(),
      ['vless://fast', 'vless://slow'],
    );
  });

  test('retestAll on an empty node list completes and reports a friendly status', () async {
    final controller = _buildController();
    await controller.loadInitial();
    expect(controller.nodes, isEmpty);

    await controller.retestAll();

    expect(controller.statusMessage, contains('还没有节点'));
    expect(controller.busy, isFalse);
    expect(controller.retesting, isFalse);
  });

  test('cancelRetest keeps untested nodes and never fabricates their delays', () async {
    final gate = Completer<void>();
    final gateway = FakeV2rayGateway(gate: gate);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      for (var i = 0; i < 20; i++) _rawNode('vless://n$i'),
    ]);

    // 不 await：让 retestAll 跑到闸门前挂起，再中途取消并放行。
    final future = controller.retestAll();
    await Future<void>.delayed(Duration.zero);
    controller.cancelRetest();
    gate.complete();
    await future;

    // 未测节点被保留、没丢。
    expect(controller.nodes, hasLength(20));
    expect(controller.statusMessage, contains('测速已停止'));
    // 未测的节点延迟仍是 null，没有被编造。
    expect(controller.nodes.any((n) => n.delayMs == null), isTrue);
  });
}
