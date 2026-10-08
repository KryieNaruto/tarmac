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

  testWidgets('retesting shows the progress row and a progress indicator', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();
    // retesting 是 getter（retestTotal > 0），设 total 即可进入测速态。
    controller.retestTotal = 554;
    controller.retestDone = 37;

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.text('测速中 37/554'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('FAB is disabled while busy', (tester) async {
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

    final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
    expect(fab.onPressed, isNull);
  });

  testWidgets('tapping a node row connects to that node', (tester) async {
    // 核心经该节点实测返回 50ms → 手动连接被判定为「已连接」。
    final v2rayService = V2rayService(FakeV2rayGateway(connectedDelays: [50]));
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

  testWidgets('shows the last retest time when available and not retesting', (tester) async {
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
}
