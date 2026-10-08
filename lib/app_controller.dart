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
    this._httpClient,
  });

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

  int retestDone = 0;
  int retestTotal = 0;
  bool _retestCancelled = false;

  /// 正在批量测速中（用于 UI 显示进度条）。
  bool get retesting => retestTotal > 0;

  /// 请求中止正在进行的测速。已测到的结果保留，未测的保持「未测速」。
  void cancelRetest() {
    if (retestTotal == 0) return;
    _retestCancelled = true;
  }

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

  /// 启动路径：先读本地存储，再拉一次订阅。**不自动测速**——
  /// 默认源去重后有 554 个节点，全量测速要 1–6 分钟，何时开始由用户点「测速」决定。
  Future<void> bootstrap() async {
    await loadInitial();
    await refreshSubscriptions(retest: false);
  }

  Future<void> refreshSubscriptions({bool retest = true}) async {
    busy = true;
    notifyListeners();

    final manualOnly = nodes.where((n) => n.sourceSubId == 'manual').toList();

    final enabled = subscriptions.where((s) => s.enabled).toList();
    final results = await Future.wait(
      enabled.map((s) => subscriptionService.fetchAndParse(s, client: _httpClient)),
    );
    final byId = {
      for (var i = 0; i < enabled.length; i++) enabled[i].id: results[i],
    };

    final fetched = <ProxyNode>[];
    final updatedSubs = <ProxySubscription>[];
    for (final sub in subscriptions) {
      final result = byId[sub.id];
      if (result == null) {          // 未启用的源：原样保留
        updatedSubs.add(sub);
        continue;
      }
      fetched.addAll(result.nodes);
      updatedSubs.add(sub.copyWith(
        lastFetchedAt: DateTime.now(),
        nodeCount: result.nodes.length,
        lastError: result.error,
        clearError: result.error == null,
      ));
    }

    subscriptions = updatedSubs;
    nodes = dedupeNodes([...fetched, ...manualOnly]);
    await storage.saveSubscriptions(subscriptions);

    if (retest) {
      await _runRetest();            // spec §8：下拉刷新 = 重新拉订阅 + 全量重测
    } else {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> retestAll() async {
    busy = true;
    notifyListeners();
    await _runRetest();
  }

  Future<void> _runRetest() async {
    _retestCancelled = false;

    if (nodes.isEmpty) {
      retestTotal = 0;
      retestDone = 0;
      statusMessage = '还没有节点，请先刷新订阅';
      busy = false;
      notifyListeners();
      return;
    }

    final input = nodes;   // 快照。注意：全程只「重赋值」nodes，绝不原地增删改，
                           // 否则会破坏 testDelays 正在遍历的那个 list。
    retestTotal = input.length;
    retestDone = 0;
    notifyListeners();

    nodes = await v2rayService.testDelays(
      input,
      onProgress: (current, done, total) {
        retestDone = done;
        nodes = sortByDelay(current);   // spec §7.2/§8：实时回填 + 按延迟升序
        notifyListeners();
      },
      shouldStop: () => _retestCancelled,
    );
    nodes = sortByDelay(nodes);

    final usable = nodes.where((n) => n.delayMs != null && n.delayMs! >= 0).length;
    statusMessage = _retestCancelled
        ? '测速已停止（已完成 $retestDone/$retestTotal）'
        : '测速完成 · $usable/${nodes.length} 个可用';

    retestTotal = 0;
    retestDone = 0;
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
