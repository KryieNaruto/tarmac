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
import '../fakes/fake_connectivity_probe.dart';
import '../fakes/fake_v2ray_gateway.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('lists the four default subscriptions by name', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService, FakeConnectivityProbe()),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    expect(find.text('freefq'), findsOneWidget);
    expect(find.text('Pawdroid'), findsOneWidget);
    expect(find.text('ermaozi'), findsOneWidget);
    expect(find.text('V2RayAggregator'), findsOneWidget);
  });

  testWidgets('shows formatted fetch time when lastFetchedAt is set', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService, FakeConnectivityProbe()),
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
      smartConnect: SmartConnectService(v2rayService, FakeConnectivityProbe()),
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
      smartConnect: SmartConnectService(v2rayService, FakeConnectivityProbe()),
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
}
