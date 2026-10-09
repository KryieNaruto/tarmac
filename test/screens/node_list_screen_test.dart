// test/screens/node_list_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tarmac/app_controller.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/screens/node_list_screen.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/storage_service.dart';
import 'package:tarmac/services/subscription_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_tunnel_probe.dart';
import '../fakes/fake_v2ray_gateway.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows 未连接 status and a 一键连接 button by default', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('一键连接'), findsOneWidget);
  });

  testWidgets(
      'characterization: pull-to-refresh works on an empty node list (framework default physics)',
      (tester) async {
    // 说明：这条不是「启动路径拉订阅」那个 bug 的回归测试——它当前就是绿的，
    // 依赖的是 Flutter 框架本来就有的行为：ScrollView 构造函数在
    // primary == null && controller == null && 竖向 时会默认套上
    // AlwaysScrollableScrollPhysics（见 scroll_view.dart），空列表因此仍可下拉。
    // 它的真实身份是 characterization 护栏：防止后人给这里的 ListView 加上
    // primary: false 或显式 controller，从而破坏「空列表可下拉刷新」。
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient(
        (_) async => http.Response('vless://shared@x:443#Shared', 200),
      ),
    );
    await controller.loadInitial();

    // Precondition: nothing has been fetched yet, so the list is empty.
    expect(controller.nodes, isEmpty);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    // The pull gesture must reach the RefreshIndicator and trigger a fetch.
    expect(controller.nodes, isNotEmpty);
  });

  testWidgets('empty node list shows the empty-state hint', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    expect(controller.nodes, isEmpty);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.textContaining('还没有节点'), findsOneWidget);
  });

  testWidgets('empty node list shows a fetching hint while busy', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    controller.busy = true;

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.textContaining('正在拉取订阅'), findsOneWidget);
  });

  testWidgets('hunting shows the progress row and a progress indicator', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    // hunting 是 getter（huntTotal > 0），设 total/done 即可进入猎取态。
    controller.huntTotal = 10;
    controller.huntDone = 3;

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.textContaining('正在寻找可用节点'), findsOneWidget);
    expect(find.text('正在寻找可用节点 3/10'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('tapping a node row connects to that node', (tester) async {
    // 校验目标（与 V2rayService.kVerifyUrls 一致）全部可达
    // → 手动连接被判定为「已连接」。
    final v2rayService = V2rayService(
      FakeV2rayGateway(),
      probe: FakeTunnelProbe(
        reachable: const {'www.google.com', 'twitter.com'},
      ),
    );
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      ProxyNode(
        id: 'a',
        remark: '节点A',
        protocol: 'vless',
        rawLink: 'a',
        sourceSubId: 'manual',
        delayMs: 50,
      ),
      ProxyNode(
        id: 'b',
        remark: '节点B',
        protocol: 'vless',
        rawLink: 'b',
        sourceSubId: 'manual',
        delayMs: 60,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));
    expect(find.text('节点A'), findsOneWidget);

    await tester.tap(find.text('节点A'));
    // 连接过程全是微任务；多 pump 几次把异步链推完（成功路径无定时器）。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(controller.connectedNode?.id, 'a');
    expect(controller.statusMessage, contains('已连接'));
  });

  testWidgets('shows the last retest time when available and not hunting', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    controller.lastRetestAt = DateTime(2026, 10, 8, 9, 5);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.text('上次测速 10/8 09:05'), findsOneWidget);
  });

  testWidgets('超时节点默认收起，只露出可用节点与分区头', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      ProxyNode(
        id: 'a',
        remark: '可用A',
        protocol: 'vless',
        rawLink: 'a',
        sourceSubId: 'manual',
        delayMs: 50,
      ),
      ProxyNode(
        id: 'b',
        remark: '可用B',
        protocol: 'vless',
        rawLink: 'b',
        sourceSubId: 'manual',
        delayMs: 200,
      ),
      ProxyNode(
        id: 't1',
        remark: '超时1',
        protocol: 'vless',
        rawLink: 't1',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
      ProxyNode(
        id: 't2',
        remark: '超时2',
        protocol: 'vless',
        rawLink: 't2',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
      ProxyNode(
        id: 't3',
        remark: '超时3',
        protocol: 'vless',
        rawLink: 't3',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    // 可用节点可见。
    expect(find.text('可用A'), findsOneWidget);
    expect(find.text('可用B'), findsOneWidget);
    // 超时节点默认不可见。
    expect(find.text('超时1'), findsNothing);
    expect(find.text('超时2'), findsNothing);
    expect(find.text('超时3'), findsNothing);
    // 分区头在，且处于收起文案。
    expect(find.textContaining('超时节点'), findsOneWidget);
    expect(find.textContaining('已收起 3 个超时节点'), findsOneWidget);
  });

  testWidgets('点分区头展开超时节点，文案随之变化', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      ProxyNode(
        id: 'a',
        remark: '可用A',
        protocol: 'vless',
        rawLink: 'a',
        sourceSubId: 'manual',
        delayMs: 50,
      ),
      ProxyNode(
        id: 't1',
        remark: '超时1',
        protocol: 'vless',
        rawLink: 't1',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
      ProxyNode(
        id: 't2',
        remark: '超时2',
        protocol: 'vless',
        rawLink: 't2',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));
    expect(find.textContaining('已收起 2 个超时节点'), findsOneWidget);
    expect(find.text('超时1'), findsNothing);

    await tester.tap(find.textContaining('超时节点'));
    await tester.pump();

    expect(find.text('超时1'), findsOneWidget);
    expect(find.text('超时2'), findsOneWidget);
    expect(find.textContaining('收起 2 个超时节点'), findsOneWidget);
    expect(find.textContaining('已收起'), findsNothing);
  });

  testWidgets('未测速(delayMs == null)节点属于可见组，默认可见', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      ProxyNode(
        id: 'u',
        remark: '未测速U',
        protocol: 'vless',
        rawLink: 'u',
        sourceSubId: 'manual',
      ),
      ProxyNode(
        id: 't1',
        remark: '超时1',
        protocol: 'vless',
        rawLink: 't1',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.text('未测速U'), findsOneWidget);
    expect(find.text('超时1'), findsNothing);
  });

  testWidgets('全为超时节点时不显示空态，仍显示分区头', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      ProxyNode(
        id: 't1',
        remark: '超时1',
        protocol: 'vless',
        rawLink: 't1',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
      ProxyNode(
        id: 't2',
        remark: '超时2',
        protocol: 'vless',
        rawLink: 't2',
        sourceSubId: 'manual',
        delayMs: -1,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    // nodes 非空，不能误用空态。
    expect(find.textContaining('还没有节点'), findsNothing);
    expect(find.textContaining('正在拉取订阅'), findsNothing);
    // 分区头照常显示。
    expect(find.textContaining('超时节点'), findsOneWidget);
  });
}
