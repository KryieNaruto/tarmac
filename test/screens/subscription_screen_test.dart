import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tarmac/app_controller.dart';
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
}
