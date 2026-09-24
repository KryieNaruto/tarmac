import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'models/proxy_node.dart';
import 'models/subscription.dart';
import 'services/smart_connect_service.dart';
import 'services/storage_service.dart';
import 'services/subscription_service.dart';
import 'services/v2ray_gateway.dart';
import 'services/v2ray_service.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.storage,
    required this.subscriptionService,
    required this.v2rayService,
    required this.smartConnect,
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  final StorageService storage;
  final SubscriptionService subscriptionService;
  final V2rayService v2rayService;
  final SmartConnectService smartConnect;
  final http.Client? _httpClient;

  List<ProxySubscription> subscriptions = [];
  List<ProxyNode> nodes = [];
  V2rayConnectionState connectionState = V2rayConnectionState.disconnected;
  ProxyNode? connectedNode;
  String statusMessage = '未连接';
  bool busy = false;

  @visibleForTesting
  void debugSetNodesForTest(List<ProxyNode> testNodes) {
    nodes = testNodes;
    notifyListeners();
  }

  Future<void> loadInitial() async {
    subscriptions = await storage.loadSubscriptions();
    final manual = await storage.loadManualNodes();
    nodes = manual;
    notifyListeners();
  }

  Future<void> refreshSubscriptions() async {
    busy = true;
    notifyListeners();

    final fetched = <ProxyNode>[];
    final updatedSubs = <ProxySubscription>[];
    for (final sub in subscriptions) {
      if (!sub.enabled) {
        updatedSubs.add(sub);
        continue;
      }
      final result = await subscriptionService.fetchAndParse(sub, client: _httpClient);
      fetched.addAll(result.nodes);
      updatedSubs.add(sub.copyWith(
        lastFetchedAt: DateTime.now(),
        nodeCount: result.nodes.length,
        lastError: result.error,
        clearError: result.error == null,
      ));
    }

    subscriptions = updatedSubs;

    final manualOnly = nodes.where((n) => n.sourceSubId == 'manual').toList();
    nodes = dedupeNodes([...fetched, ...manualOnly]);

    await storage.saveSubscriptions(subscriptions);
    busy = false;
    notifyListeners();
  }

  Future<void> retestAll() async {
    busy = true;
    notifyListeners();
    nodes = await v2rayService.testDelays(nodes);
    busy = false;
    notifyListeners();
  }

  Future<void> smartConnectNow() async {
    final hasCandidates = nodes.any((n) => n.delayMs != null && n.delayMs! >= 0);
    if (!hasCandidates) {
      statusMessage = '还没有可用延迟数据，请先测速';
      notifyListeners();
      return;
    }

    statusMessage = '智能连接中…';
    notifyListeners();

    final outcome = await smartConnect.connectBest(
      nodes,
      onAttempt: (node) {
        statusMessage = '正在尝试 · ${node.remark}';
        notifyListeners();
      },
    );

    switch (outcome.result) {
      case SmartConnectResult.success:
        connectedNode = outcome.node;
        connectionState = V2rayConnectionState.connected;
        statusMessage = '已连接 · ${outcome.node!.remark}';
        await storage.saveLastConnectedNodeId(outcome.node!.id);
        break;
      case SmartConnectResult.allFailed:
        connectedNode = null;
        connectionState = V2rayConnectionState.disconnected;
        statusMessage = '全部节点不可用，请刷新订阅重试';
        break;
      case SmartConnectResult.noCandidates:
        connectedNode = null;
        connectionState = V2rayConnectionState.disconnected;
        statusMessage = '还没有可用延迟数据，请先测速';
        break;
      case SmartConnectResult.cancelled:
        connectedNode = null;
        connectionState = V2rayConnectionState.disconnected;
        statusMessage = '未连接';
        break;
    }
    notifyListeners();
  }

  Future<void> disconnectNow() async {
    smartConnect.cancel();
    await v2rayService.disconnect();
    connectedNode = null;
    connectionState = V2rayConnectionState.disconnected;
    statusMessage = '未连接';
    await storage.saveLastConnectedNodeId(null);
    notifyListeners();
  }

  Future<void> addSubscription(String name, String url) async {
    subscriptions = [
      ...subscriptions,
      ProxySubscription(id: url, name: name, url: url),
    ];
    await storage.saveSubscriptions(subscriptions);
    notifyListeners();
  }

  Future<void> toggleSubscription(String id) async {
    subscriptions = subscriptions
        .map((s) => s.id == id ? s.copyWith(enabled: !s.enabled) : s)
        .toList();
    await storage.saveSubscriptions(subscriptions);
    notifyListeners();
  }

  Future<void> removeSubscription(String id) async {
    subscriptions = subscriptions.where((s) => s.id != id).toList();
    await storage.saveSubscriptions(subscriptions);
    notifyListeners();
  }
}
