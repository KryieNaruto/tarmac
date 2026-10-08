import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tarmac/app_controller.dart';
import 'package:tarmac/models/subscription.dart';
import 'package:tarmac/screens/subscription_screen.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/storage_service.dart';
import 'package:tarmac/services/subscription_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_v2ray_gateway.dart';

/// 构造一个注入 mock HTTP 客户端的 controller，供加源试拉用。
AppController _buildController(http.Client client) {
  final v2rayService = V2rayService(FakeV2rayGateway());
  return AppController(
    storage: StorageService(),
    subscriptionService: SubscriptionService(),
    v2rayService: v2rayService,
    smartConnect: SmartConnectService(v2rayService),
    httpClient: client,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('lists the three default subscriptions by name', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    expect(find.text('Pawdroid'), findsOneWidget);
    expect(find.text('ermaozi'), findsOneWidget);
    expect(find.text('mohammadaz2'), findsOneWidget);
  });

  testWidgets('shows formatted fetch time when lastFetchedAt is set', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    controller.subscriptions = [
      ProxySubscription(
        id: 'u1',
        name: '源A',
        url: 'https://example.com/a',
        nodeCount: 12,
        lastFetchedAt: DateTime(2026, 10, 7, 9, 5),
      ),
    ];

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    expect(find.text('节点数：12 · 更新于 10/7 09:05'), findsOneWidget);
  });

  testWidgets('shows 未更新 when lastFetchedAt is null', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    controller.subscriptions = [
      ProxySubscription(
        id: 'u2',
        name: '源B',
        url: 'https://example.com/b',
        lastFetchedAt: null,
      ),
    ];

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    expect(find.text('节点数：0 · 未更新'), findsOneWidget);
  });

  testWidgets('lastError takes precedence over lastFetchedAt', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    controller.subscriptions = [
      ProxySubscription(
        id: 'u3',
        name: '源C',
        url: 'https://example.com/c',
        nodeCount: 12,
        lastFetchedAt: DateTime(2026, 10, 7, 9, 5),
        lastError: '超时',
      ),
    ];

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    expect(find.text('失败：超时'), findsOneWidget);
    expect(find.text('节点数：12 · 更新于 10/7 09:05'), findsNothing);
  });

  testWidgets('shows guidance about adding your own airport subscription', (tester) async {
    final controller = _buildController(MockClient((_) async => http.Response('', 404)));
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    expect(find.textContaining('机场'), findsOneWidget);
    expect(find.textContaining('建议'), findsOneWidget);
  });

  testWidgets('adding a subscription reports how many nodes were fetched', (tester) async {
    final client = MockClient(
      (_) async => http.Response('vless://a@x:443#A\nvless://b@x:443#B', 200),
    );
    final controller = _buildController(client);
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '我的源');
    await tester.enterText(find.byType(TextField).at(1), 'https://a.com/sub');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(controller.subscriptions.any((s) => s.name == '我的源'), isTrue);
    expect(find.text('我的源'), findsOneWidget);
    expect(find.textContaining('2 个节点'), findsOneWidget);
  });

  testWidgets('a failed check keeps the dialog open and shows the reason', (tester) async {
    final client = MockClient((_) async => http.Response('', 404));
    final controller = _buildController(client);
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '坏源');
    await tester.enterText(find.byType(TextField).at(1), 'https://a.com/bad');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 对话框不关闭，且显眼地给出失败原因 + 「仍然添加」的出路。
    expect(find.text('添加订阅'), findsOneWidget);
    expect(find.textContaining(RegExp('失败|没拉到')), findsOneWidget);
    expect(find.text('仍然添加'), findsOneWidget);
    // 失败的源没有被写进列表。
    expect(controller.subscriptions.any((s) => s.name == '坏源'), isFalse);
  });

  testWidgets('tapping the title lets the user rename a subscription', (tester) async {
    final controller = _buildController(MockClient((_) async => http.Response('', 404)));
    controller.subscriptions = [
      ProxySubscription(id: 'u9', name: '旧名字', url: 'https://example.com/a'),
    ];

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    await tester.tap(find.text('旧名字'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '新名字');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.subscriptions.first.name, '新名字');
    expect(find.text('新名字'), findsOneWidget);
  });
}
