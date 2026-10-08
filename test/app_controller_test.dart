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
import 'package:tarmac/services/v2ray_gateway.dart';
import 'package:tarmac/services/v2ray_service.dart';
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
}) {
  final v2rayGateway = gateway ?? FakeV2rayGateway();
  final v2rayService = V2rayService(v2rayGateway);
  return AppController(
    storage: StorageService(),
    subscriptionService: SubscriptionService(),
    v2rayService: v2rayService,
    smartConnect: SmartConnectService(v2rayService),
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

  test('smartConnectNow with no nodes reports that no usable node was found', () async {
    final controller = _buildController();
    await controller.loadInitial();
    expect(controller.nodes, isEmpty);

    await controller.smartConnectNow();

    // 语义已变：不再要求用户「先测速」，而是直接报告当下没找到可用节点。
    expect(controller.statusMessage, contains('找不到可用节点'));
    expect(controller.connectedNode, isNull);
    expect(controller.busy, isFalse);
  });

  test('smartConnectNow hunts, connects, and updates connectedNode + status', () async {
    // 节点虽已带延迟，但猎取会重测这一批；脚本给出可用延迟、核心实测通过。
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://a': 10},
      connectedDelays: [50],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      _testNode('vless://a', 10),
    ]);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    expect(controller.connectedNode?.id, 'vless://a');
    expect(controller.statusMessage, contains('已连接'));
    expect(controller.busy, isFalse);
    expect(controller.hunting, isFalse);
  });

  test('disconnectNow aborts an in-flight hunt and leaves nothing connected', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://a': 10},
      connectedDelays: [50],
    );
    gateway.pending = Completer<int?>(); // getConnectedDelay() 挂起，模拟连接进行中
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_testNode('vless://a', 10)]);

    final future = controller.smartConnectNow(verifyWindow: Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await controller.disconnectNow();
    // 放行挂起的核心实测，让仍在 await 的 connectAndVerify 观察到取消并返回。
    gateway.pending!.complete(50);
    await future;

    expect(controller.connectedNode, isNull);
    expect(controller.connectionState, V2rayConnectionState.disconnected);
    expect(controller.busy, isFalse);
  });

  test('smartConnectNow connects without any prior retest (all delays null)', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://a': 20, 'vless://b': 10},
      connectedDelays: [50],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_rawNode('vless://a'), _rawNode('vless://b')]);
    expect(controller.nodes.every((n) => n.delayMs == null), isTrue);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    expect(controller.connectedNode, isNotNull);
    expect(controller.connectionState, V2rayConnectionState.connected);
    expect(controller.statusMessage, contains('已连接'));
    expect(controller.busy, isFalse);
  });

  test('smartConnectNow tries nodes previously marked as timed out', () async {
    // 两个节点的旧数据都是「超时」(-1)，只有其中之一这回能测通——
    // 证明超时节点不会被排除，旧数据不可信。
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://t': 30},
      connectedDelays: [50],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      _testNode('vless://x', -1),
      _testNode('vless://t', -1),
    ]);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    expect(controller.connectedNode?.id, 'vless://t');
    expect(controller.statusMessage, contains('已连接'));
  });

  test('smartConnectNow persists the delays it discovers while hunting', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://a': 25},
      connectedDelays: [50],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_rawNode('vless://a')]);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    final cached = await StorageService().loadNodeDelays();
    expect(cached['vless://a'], 25);
    expect(controller.lastRetestAt, isNotNull);
  });

  test('cancelHunt stops the hunt without connecting', () async {
    final gate = Completer<void>();
    final gateway = FakeV2rayGateway(
      gate: gate,
      delayScript: {'vless://a': 10},
      connectedDelays: [50],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      for (var i = 0; i < 20; i++) _rawNode('vless://n$i'),
    ]);

    // 不 await：让猎取卡在第一批的测速闸门前，再中途取消并放行。
    final future = controller.smartConnectNow(
      batchSize: 8,
      concurrency: 8,
      verifyWindow: Duration.zero,
    );
    await Future<void>.delayed(Duration.zero);
    controller.cancelHunt();
    gate.complete();
    await future;

    expect(controller.connectedNode, isNull);
    expect(controller.busy, isFalse);
    expect(controller.hunting, isFalse);
    expect(controller.statusMessage, contains('已停止寻找'));
  });

  test('smartConnectNow reports failure when nothing works', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://a': 10},
      connectedDelays: const [],   // 核心经该节点始终取不到数据
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_rawNode('vless://a')]);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    expect(controller.statusMessage, contains('找不到可用节点'));
    expect(controller.connectedNode, isNull);
    expect(controller.busy, isFalse);
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

  test('cached delays survive refreshSubscriptions (regression: delays were dropped every launch)',
      () async {
    SharedPreferences.setMockInitialValues({
      'tarmac.node_delays': '{"vless://a@x:443#A": 42}',
    });
    final client = MockClient((_) async => http.Response('vless://a@x:443#A', 200));
    final controller = _buildController(httpClient: client);

    await controller.bootstrap();

    final node = controller.nodes.firstWhere((n) => n.rawLink == 'vless://a@x:443#A');
    expect(node.delayMs, 42);
  });

  test('delays survive a full restart via the disk cache', () async {
    final client = MockClient((_) async => http.Response('vless://a@x:443#A', 200));
    final gateway1 = FakeV2rayGateway(delayScript: {'vless://a@x:443#A': 7});
    final controller1 = _buildController(httpClient: client, gateway: gateway1);
    await controller1.bootstrap();
    await controller1.retestAll();
    expect(
      controller1.nodes.firstWhere((n) => n.rawLink == 'vless://a@x:443#A').delayMs,
      7,
    );

    // 新建 controller 模拟重启，共用同一个 SharedPreferences mock。
    final controller2 = _buildController(httpClient: client, gateway: FakeV2rayGateway());
    await controller2.bootstrap();

    final node = controller2.nodes.firstWhere((n) => n.rawLink == 'vless://a@x:443#A');
    expect(node.delayMs, 7);
    expect(controller2.lastRetestAt, isNotNull);
  });

  test('cancelled retest caches only the nodes that were actually tested', () async {
    final gate = Completer<void>();
    final gateway = FakeV2rayGateway(gate: gate);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      for (var i = 0; i < 20; i++) _rawNode('vless://n$i'),
    ]);

    // 不 await：跑到闸门前挂起，取消后放行。
    final future = controller.retestAll();
    await Future<void>.delayed(Duration.zero);
    controller.cancelRetest();
    gate.complete();
    await future;

    final cached = await StorageService().loadNodeDelays();
    // 只测了第一批（默认并发 8）——这些「测过但失败」的节点存成 -1（期望行为）；
    // 因取消而仍为 null 的节点不得进缓存。
    expect(cached, hasLength(8));
    for (var i = 0; i < 8; i++) {
      expect(cached['vless://n$i'], -1);
    }
    expect(cached.containsKey('vless://n19'), isFalse);
  });

  test('merged cached delays are ordered by ascending delay after bootstrap', () async {
    SharedPreferences.setMockInitialValues({
      'tarmac.node_delays': '{"vless://slow@x:443#S": 300, "vless://fast@x:443#F": 50}',
    });
    final body = 'vless://slow@x:443#S\nvless://fast@x:443#F';
    final client = MockClient((_) async => http.Response(body, 200));
    final controller = _buildController(httpClient: client);

    await controller.bootstrap();

    expect(
      controller.nodes.map((n) => n.rawLink).toList(),
      ['vless://fast@x:443#F', 'vless://slow@x:443#S'],
    );
  });

  test('the cache is pruned when a node disappears from the current set', () async {
    var body = 'vless://a@x:443#A\nvless://b@x:443#B';
    final client = MockClient((_) async => http.Response(body, 200));
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://a@x:443#A': 11, 'vless://b@x:443#B': 22},
    );
    final controller = _buildController(httpClient: client, gateway: gateway);
    await controller.bootstrap();
    await controller.retestAll();

    expect(
      (await StorageService().loadNodeDelays()).keys,
      containsAll(['vless://a@x:443#A', 'vless://b@x:443#B']),
    );

    // 订阅改为只返回 a；再刷新 + 重测，缓存应被裁剪掉 b。
    body = 'vless://a@x:443#A';
    await controller.refreshSubscriptions();

    final cached = await StorageService().loadNodeDelays();
    expect(cached.containsKey('vless://a@x:443#A'), isTrue);
    expect(cached.containsKey('vless://b@x:443#B'), isFalse);
  });

  test('connectToNode connects the selected node and persists it on success', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    final node = _testNode('vless://a', 10);

    await controller.connectToNode(node);

    expect(controller.connectedNode?.id, 'vless://a');
    expect(controller.connectionState, V2rayConnectionState.connected);
    expect(controller.statusMessage, contains('已连接'));
    expect(controller.busy, isFalse);
    expect(await StorageService().loadLastConnectedNodeId(), 'vless://a');
  });

  test('connectToNode marks disconnected when the core proxy yields no data', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [-1]);
    // 核心经该节点始终取不到数据 → connectAndVerify 判定「连接不可用」。
    // 传 Duration.zero 的 establishWindow，免得真等满默认的 10s。
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    final node = _testNode('vless://a', 10);

    await controller.connectToNode(node, establishWindow: Duration.zero);

    expect(controller.connectedNode, isNull);
    expect(controller.connectionState, V2rayConnectionState.disconnected);
    expect(controller.statusMessage, contains('经该节点取不到数据'));
    expect(controller.busy, isFalse);
  });

  test('connectToNode reports a permission failure when the VPN permission is denied', () async {
    final gateway = FakeV2rayGateway(permissionGranted: false, connectedDelays: [50]);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    final node = _testNode('vless://a', 10);

    await controller.connectToNode(node, establishWindow: Duration.zero);

    expect(controller.connectedNode, isNull);
    expect(controller.connectionState, V2rayConnectionState.disconnected);
    expect(controller.statusMessage, contains('权限'));
    // 权限被拒 → 根本没起隧道。
    expect(gateway.lastStartedRawLink, isNull);
    expect(controller.busy, isFalse);
  });

  test('connectToNode can connect an untested node without a prior retest', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    final node = _rawNode('vless://untested'); // delayMs == null：从未测速
    expect(node.delayMs, isNull);

    await controller.connectToNode(node);

    expect(controller.connectedNode?.id, 'vless://untested');
    expect(controller.connectionState, V2rayConnectionState.connected);
    expect(controller.statusMessage, contains('已连接'));
  });

  test('connectToNode is ignored while busy', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    final node = _testNode('vless://a', 10);

    controller.busy = true;
    final before = controller.statusMessage;

    await controller.connectToNode(node);

    expect(controller.statusMessage, before);
    expect(controller.connectedNode, isNull);
    // 被忽略的点击不该复位 busy（复位由进行中的那个操作负责）。
    expect(controller.busy, isTrue);
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('意外掉线会触发自动重连并最终重新连上', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://a': 10},
      connectedDelays: [50],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_testNode('vless://a', 10)]);

    await controller.connectToNode(_testNode('vless://a', 10));
    expect(controller.connectionState, V2rayConnectionState.connected);
    expect(controller.connectedNode, isNotNull);

    // 重连成功后文案会被覆盖成「已连接」，所以「自动重连」这条中间态
    // 只能靠监听器把历次 statusMessage 记下来。
    final seen = <String>[];
    controller.addListener(() => seen.add(controller.statusMessage));

    gateway.emitState(V2rayConnectionState.disconnected);
    await pumpEventQueue();

    expect(seen.any((s) => s.contains('自动重连')), isTrue,
        reason: '应当先给出自动重连提示');
    expect(controller.connectedNode, isNotNull, reason: '应当重连成功');
    expect(controller.connectionState, V2rayConnectionState.connected);
    expect(controller.busy, isFalse);
  });

  test('用户主动断开不会触发自动重连', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    await controller.connectToNode(_testNode('vless://a', 10));
    expect(controller.connectionState, V2rayConnectionState.connected);

    await controller.disconnectNow();
    await pumpEventQueue();

    expect(controller.statusMessage, '未连接');
    expect(controller.statusMessage, isNot(contains('自动重连')));
    expect(controller.connectedNode, isNull);
  });

  test('有操作在跑(busy)时不抢连接状态', () async {
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    await controller.connectToNode(_testNode('vless://a', 10));
    expect(controller.connectionState, V2rayConnectionState.connected);

    controller.busy = true;
    gateway.emitState(V2rayConnectionState.disconnected);
    await pumpEventQueue();

    // busy 守卫生效：进行中的操作自己会写终态，状态流期间不得抢改。
    expect(controller.connectionState, V2rayConnectionState.connected);
    expect(controller.connectedNode, isNotNull);

    controller.busy = false;
  });

  test('renameSubscription renames a subscription and persists it', () async {
    final controller = _buildController();
    await controller.loadInitial();
    expect(controller.subscriptions, isNotEmpty);
    final id = controller.subscriptions.first.id;
    final count = controller.subscriptions.length;

    await controller.renameSubscription(id, '我的机场');

    expect(controller.subscriptions.first.name, '我的机场');
    expect(controller.subscriptions, hasLength(count));

    // 新建 controller 模拟重启，能从存储读回新名字。
    final reloaded = _buildController();
    await reloaded.loadInitial();
    expect(reloaded.subscriptions.first.name, '我的机场');
  });

  test('renameSubscription with an unknown id is a no-op and does not throw', () async {
    final controller = _buildController();
    await controller.loadInitial();
    final before = controller.subscriptions.map((s) => s.name).toList();

    await controller.renameSubscription('no-such-id', 'X');

    expect(controller.subscriptions.map((s) => s.name).toList(), before);
  });

  test('自动重连有次数上限，超过后提示手动重试', () async {
    // 猎取必然失败：节点没有脚本延迟 -> 测出 -1 -> 永不被当作候选，
    // 所以整条猎取链路瞬时结束。刻意不用 connectedDelays: const []
    // 那条路径，因为重连内部调用的是生产默认参数（8s 实测窗口），
    // 注入不了极短窗口，会把测试拖慢。
    final gateway = FakeV2rayGateway(connectedDelays: [50]);
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_rawNode('vless://a')]);

    for (var i = 0; i < 5; i++) {
      // 手工摆回「已连接」以模拟又一次意外掉线。不走状态流的 connected
      // 事件，否则会把自动重连计数归零、永远到不了上限。
      controller.connectionState = V2rayConnectionState.connected;
      gateway.emitState(V2rayConnectionState.disconnected);
      await pumpEventQueue();
    }

    expect(controller.statusMessage, contains('请手动重试'));
    expect(controller.busy, isFalse);
  });

  test('smartConnectNow 优先挑全通节点：partial 先被记住，后面全通者胜出', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://p': 10, 'vless://f': 20},
      // 调用顺序 = 每个候选先 google 后 twitter：
      //   p: google 50 ✓ / twitter -1 ✗ → partial，先记住
      //   f: google 50 ✓ / twitter 50 ✓ → verified，胜出
      connectedDelays: [50, -1, 50, 50],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      _testNode('vless://p', 10),
      _testNode('vless://f', 20),
    ]);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    expect(controller.connectedNode?.id, 'vless://f');
    expect(controller.statusMessage, isNot(contains('Twitter 不可用')));
    expect(controller.statusMessage, contains('已连接'));
    expect(controller.busy, isFalse);
  });

  test('smartConnectNow 没有全通节点时回退连上 partial（Twitter 不可用）', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://p': 10},
      // p: google 50 ✓ / twitter -1 ✗ → partial；
      // 回退再连一次同样是 google 50 ✓ / twitter -1 ✗ → partial，保持连接。
      connectedDelays: [50, -1, 50, -1],
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_testNode('vless://p', 10)]);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    expect(controller.connectedNode?.id, 'vless://p');
    expect(controller.connectionState, V2rayConnectionState.connected);
    expect(controller.statusMessage, contains('Twitter 不可用'));
    expect(controller.busy, isFalse);
  });

  test('smartConnectNow 主目标也不通时报告失败，且不回退 partial', () async {
    final gateway = FakeV2rayGateway(
      delayScript: {'vless://p': 10},
      connectedDelays: const [], // 核心经该节点始终取不到数据（主目标就不过）
    );
    final controller = _buildController(gateway: gateway);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_testNode('vless://p', 10)]);

    await controller.smartConnectNow(verifyWindow: Duration.zero);

    expect(controller.statusMessage, contains('找不到可用节点'));
    expect(controller.connectedNode, isNull);
    expect(controller.busy, isFalse);
  });
}
