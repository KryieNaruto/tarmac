import 'package:flutter/material.dart';
import 'app_controller.dart';
import 'screens/node_list_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/subscription_screen.dart';
import 'services/smart_connect_service.dart';
import 'services/storage_service.dart';
import 'services/subscription_service.dart';
import 'services/v2ray_gateway.dart';
import 'services/v2ray_service.dart';
import 'services/connectivity_probe.dart';

void main() {
  runApp(const TarmacApp());
}

class TarmacApp extends StatefulWidget {
  const TarmacApp({super.key});

  @override
  State<TarmacApp> createState() => _TarmacAppState();
}

class _TarmacAppState extends State<TarmacApp> {
  late final AppController _controller;
  late final V2rayService _v2rayService;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    final gateway = FlutterV2rayGateway();
    _v2rayService = V2rayService(gateway);
    _controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: _v2rayService,
      smartConnect: SmartConnectService(_v2rayService, HttpConnectivityProbe()),
    );
    _v2rayService.initialize();
    _controller.bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      NodeListScreen(controller: _controller),
      SubscriptionScreen(controller: _controller),
      const SettingsScreen(),
    ];
    return MaterialApp(
      title: 'Tarmac',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        body: screens[_tabIndex],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: (i) => setState(() => _tabIndex = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.list), label: '节点'),
            NavigationDestination(icon: Icon(Icons.rss_feed), label: '订阅'),
            NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
          ],
        ),
      ),
    );
  }
}
