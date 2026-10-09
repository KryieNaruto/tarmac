import 'dart:async';

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
  }) {
    // 订阅插件状态流：隧道中途意外掉线（节点挂了 / 网络变了）时，
    // 靠它把界面拉回真实状态，而不是一直骗用户「已连接」。
    _stateSubscription =
        v2rayService.stateStream.listen(_onConnectionStateChanged);
  }

  final StorageService storage;
  final SubscriptionService subscriptionService;
  final V2rayService v2rayService;
  final SmartConnectService smartConnect;
  final http.Client? _httpClient;

  /// 供订阅页「加源前试拉」复用同一个 HTTP 客户端（测试里注入 mock）。
  http.Client? get httpClient => _httpClient;

  /// 插件状态流订阅句柄，[dispose] 时取消。
  late final StreamSubscription<V2rayConnectionState> _stateSubscription;

  /// 我方主动断开隧道时置真：状态流紧接着发出的 disconnected 属于预期，
  /// 不能当成「意外掉线」去触发自动重连。
  bool _intentionalDisconnect = false;

  /// 意外掉线后已自动重连的次数；连上成功即归零，防止死循环。
  int _autoReconnectAttempts = 0;
  static const _kMaxAutoReconnectAttempts = 3;

  @override
  void dispose() {
    _stateSubscription.cancel();
    super.dispose();
  }

  List<ProxySubscription> subscriptions = [];
  List<ProxyNode> nodes = [];
  V2rayConnectionState connectionState = V2rayConnectionState.disconnected;
  ProxyNode? connectedNode;
  String statusMessage = '未连接';
  bool busy = false;

  /// 已测出的延迟，按 rawLink 索引；落盘后跨启动复用。
  Map<String, int> _delayCache = {};

  /// 上次测速时间（UI 用它显示「上次测速 M/d HH:mm」）。
  DateTime? lastRetestAt;

  int huntDone = 0;
  int huntTotal = 0;
  bool _huntCancelled = false;

  /// 正在自动猎取可用节点（UI 用它显示「正在寻找可用节点 x/y」）。
  bool get hunting => huntTotal > 0;

  /// 请求停止自动猎取。
  void cancelHunt() {
    if (huntTotal == 0) return;
    _huntCancelled = true;
  }

  @visibleForTesting
  void debugSetNodesForTest(List<ProxyNode> testNodes) {
    nodes = testNodes;
    notifyListeners();
  }

  Future<void> loadInitial() async {
    subscriptions = await storage.loadSubscriptions();
    final manual = await storage.loadManualNodes();
    _delayCache = await storage.loadNodeDelays();
    lastRetestAt = await storage.loadLastRetestAt();
    // 手工节点也享受同样的延迟合并，保持与订阅节点一致。
    nodes = applyCachedDelays(manual, _delayCache, testedAt: lastRetestAt);
    notifyListeners();
  }

  /// 启动路径：先读本地存储，再拉一次订阅。**不自动测速**——
  /// 默认源去重后有 554 个节点，全量测速要 1–6 分钟；测速已收敛进
  /// 「一键连接」的猎取过程，启动时只拉订阅、不测速。
  Future<void> bootstrap() async {
    await loadInitial();
    await refreshSubscriptions();
  }

  Future<void> refreshSubscriptions() async {
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
    // 合并而不是替换：新拉到的节点按 rawLink 把已测延迟带回来，
    // 否则每次启动/刷新都会把上一轮测出的延迟丢光。
    nodes = sortByDelay(applyCachedDelays(
      dedupeNodes([...fetched, ...manualOnly]),
      _delayCache,
      testedAt: lastRetestAt,
    ));
    await storage.saveSubscriptions(subscriptions);

    // 拉完即结束：测速不再由刷新触发，已收敛进「一键连接」的猎取过程。
    busy = false;
    notifyListeners();
  }

  /// 从当前 [nodes] 构建延迟缓存并落盘。只收 `delayMs` 非 null 的节点
  /// （未测的宁可下次重测，也不许当成测过）；map 只含当前仍在 nodes 里的
  /// 节点，天然完成裁剪。由自动猎取在每批测速后调用。
  Future<void> _persistDelays() async {
    _delayCache = {
      for (final n in nodes)
        if (n.delayMs != null) n.rawLink: n.delayMs!,
    };
    lastRetestAt = DateTime.now();
    await storage.saveNodeDelays(_delayCache, lastRetestAt!);
  }

  /// 自动猎取的候选顺序：**不排除任何人，只是排序**。
  ///   1) 可用（`delayMs >= 0`）按延迟升序；
  ///   2) 未测速（`delayMs == null`）保持原相对顺序；
  ///   3) 超时（`delayMs < 0`）保持原相对顺序。
  /// 用稳定分区实现：`List.sort` 不是稳定排序，直接整条排会把后两段打乱。
  List<ProxyNode> _huntOrder(List<ProxyNode> input) {
    final usable = <ProxyNode>[];
    final untested = <ProxyNode>[];
    final timedOut = <ProxyNode>[];
    for (final node in input) {
      final delay = node.delayMs;
      if (delay == null) {
        untested.add(node);
      } else if (delay >= 0) {
        usable.add(node);
      } else {
        timedOut.add(node);
      }
    }
    usable.sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    return [...usable, ...untested, ...timedOut];
  }

  /// 傻瓜式一键连接：按下即**自动猎取**当下可达的节点并连上，
  /// 不需要用户先手动测速、也不需要挑节点。
  ///
  /// 网络会按 IP、时变地丢弃节点服务器，所以旧延迟（尤其「超时」）都不可信：
  /// 这里**不排除任何节点**，而是按 [_huntOrder] 排序后分批并发重测，
  /// 每批里实测可用的节点再逐个「连接 + 经核心实测」，第一个通过即成功。
  ///
  /// 具名参数只为测试注入极小的预算，生产调用不传、用默认值。
  Future<void> smartConnectNow({
    int batchSize = 24,
    int concurrency = kTestConcurrency,
    Duration huntBudget = const Duration(seconds: 240),
    Duration verifyWindow = const Duration(seconds: 8),
  }) async {
    // 忙碌时忽略点击，避免与进行中的拉取/测速/手动连接打架。
    if (busy) return;

    // 把可能还在跑的级联取消，并把旧隧道收干净，避免叠隧道。
    smartConnect.cancel();
    // 主动收掉旧隧道（打标，避免被状态流当成意外掉线）。
    await _disconnectIntentionally();

    busy = true;
    _huntCancelled = false;
    huntTotal = nodes.length;
    huntDone = 0;
    statusMessage = '正在寻找可用节点…';
    notifyListeners();

    final deadline = DateTime.now().add(huntBudget);

    // 记住第一个「主目标通、部分目标（Twitter）不通」的节点：
    // 先继续找有没有能全通的，全都找不着再回退连它。
    ProxyNode? bestPartial;

    try {
      final queue = _huntOrder(nodes);   // 快照：局部不变，nodes 另行重赋值
      for (var start = 0; start < queue.length; start += batchSize) {
        if (_huntCancelled) break;
        if (!DateTime.now().isBefore(deadline)) break;

        final batch = queue.sublist(
          start,
          (start + batchSize).clamp(0, queue.length),
        );

        final probed = await v2rayService.testDelays(
          batch,
          concurrency: concurrency,
          onProgress: (current, done, total) {
            // current 是「这一批」的完整列表（与输入同序，已测/未测按原索引回填，
            // 不是连续前缀），不是全局列表：只用它推进进度显示，绝不在这里并回
            // nodes（会打乱全局顺序）。
            huntDone = start + done;
            statusMessage = '正在寻找可用节点 · 已测 $huntDone/$huntTotal';
            notifyListeners();
          },
          shouldStop: () => _huntCancelled,
        );

        // 用赋值而非 +=：onProgress 已把 huntDone 推到 start + done，
        // 这里再累加会重复计数。
        huntDone = start + batch.length;
        statusMessage = '正在寻找可用节点 · 已测 $huntDone/$huntTotal';
        notifyListeners();

        // 批测完统一合并：把这一批的最新延迟按 rawLink 并回 nodes 并重排，
        // 然后落盘——猎取过程顺便把测速结果攒下来，用户下次不用重测。
        final probedDelays = {
          for (final p in probed)
            if (p.delayMs != null) p.rawLink: p.delayMs!,
        };
        nodes = sortByDelay(
          applyCachedDelays(nodes, probedDelays, testedAt: DateTime.now()),
        );
        await _persistDelays();

        // 这一批里实测可用的节点，按延迟升序逐个「连接 + 经核心实测」。
        final candidates = probed
            .where((n) => n.delayMs != null && n.delayMs! >= 0)
            .toList()
          ..sort((a, b) => a.delayMs!.compareTo(b.delayMs!));

        for (final node in candidates) {
          if (_huntCancelled) break;
          if (!DateTime.now().isBefore(deadline)) break;

          statusMessage = '正在尝试 · ${node.remark}';
          notifyListeners();

          final outcome = await smartConnect.connectAndVerify(
            node,
            establishWindow: verifyWindow,
          );
          if (outcome == ConnectOutcome.verified) {
            connectedNode = node;
            connectionState = V2rayConnectionState.connected;
            statusMessage = '已连接 · ${node.remark}';
            await storage.saveLastConnectedNodeId(node.id);
            _autoReconnectAttempts = 0; // 连上了就重置，避免跨会话累计到上限后永久放弃
            return;   // 猎取成功，finally 仍会复位状态
          }
          if (outcome == ConnectOutcome.verifiedPartial) {
            // 只差 Twitter：先记住它，继续找后面有没有能全通的节点；
            // 不在这里 return —— 队列后面可能还有全通的。
            bestPartial ??= node;
          }
          // 失败（权限被拒 / 主目标取不到数据）→ 继续这一批的下一个。
        }
      }

      // 队列耗尽 / 超预算 / 未取消：若找到过「只差 Twitter」的节点，回退连它，
      // 比什么都连不上对用户有用得多。被取消时（用户明确按了停止）不回退。
      final partial = bestPartial;
      if (!_huntCancelled && partial != null) {
        final fallback = await smartConnect.connectAndVerify(
          partial,
          establishWindow: verifyWindow,
        );
        if (fallback == ConnectOutcome.verified ||
            fallback == ConnectOutcome.verifiedPartial) {
          connectedNode = partial;
          connectionState = V2rayConnectionState.connected;
          statusMessage = '已连接 · ${partial.remark}（Twitter 不可用）';
          await storage.saveLastConnectedNodeId(partial.id);
          _autoReconnectAttempts = 0; // 连上了就重置，避免跨会话累计到上限后永久放弃
          return;   // 回退成功，finally 仍会复位状态
        }
      }

      // 全部走完 / 超预算 / 被取消：确保断开、状态一致。
      await _disconnectIntentionally();
      connectedNode = null;
      connectionState = V2rayConnectionState.disconnected;
      statusMessage = _huntCancelled
          ? '已停止寻找'
          : '暂时找不到可用节点（网络可能正在拦截），请稍后重试或换网络';
    } finally {
      huntTotal = 0;
      huntDone = 0;
      busy = false;
      notifyListeners();
    }
  }

  /// 连接用户手动选中的节点。允许连**未测速**的节点（用户明确要这个）。
  ///
  /// [establishWindow] 透传给 [SmartConnectService.connectAndVerify]，仅为测试能
  /// 用极短窗口跑「取不到数据」这类失败路径；生产调用不传，保持默认 10s。
  Future<void> connectToNode(
    ProxyNode node, {
    Duration establishWindow = const Duration(seconds: 10),
  }) async {
    // 忙碌时忽略点击，避免与进行中的拉取/测速/级联打架。
    if (busy) return;

    try {
      // 先把可能还在跑的级联取消，并把旧隧道收干净，避免叠隧道。
      smartConnect.cancel();
      // 主动收掉旧隧道（打标，避免被状态流当成意外掉线）。
      await _disconnectIntentionally();

      busy = true;
      statusMessage = '正在连接 · ${node.remark}';
      notifyListeners();

      final outcome = await smartConnect.connectAndVerify(
        node,
        establishWindow: establishWindow,
      );

      // 如实区分失败原因：只有 proxyUnavailable 才是「经该节点取不到数据」，
      // 把「权限被拒」说成节点问题会把用户引向错误的排查方向。
      switch (outcome) {
        case ConnectOutcome.verified:
          connectedNode = node;
          connectionState = V2rayConnectionState.connected;
          statusMessage = '已连接 · ${node.remark}';
          await storage.saveLastConnectedNodeId(node.id);
          _autoReconnectAttempts = 0; // 连上了就重置，避免跨会话累计到上限后永久放弃
          break;
        case ConnectOutcome.verifiedPartial:
          // 主目标（Google）通、部分目标（Twitter）不通：仍保留连接，
          // 比把用户丢回「什么都没连上」有用得多。
          connectedNode = node;
          connectionState = V2rayConnectionState.connected;
          statusMessage = '已连接 · ${node.remark}（Twitter 不可用）';
          await storage.saveLastConnectedNodeId(node.id);
          _autoReconnectAttempts = 0; // 连上了就重置，避免跨会话累计到上限后永久放弃
          break;
        case ConnectOutcome.permissionDenied:
          connectedNode = null;
          connectionState = V2rayConnectionState.disconnected;
          statusMessage = '连接失败：未授予 VPN 权限';
          break;
        case ConnectOutcome.proxyUnavailable:
          // connectAndVerify 在此路径内部已自行断开，这里不再重复 disconnect。
          connectedNode = null;
          connectionState = V2rayConnectionState.disconnected;
          statusMessage = '连接不可用：经该节点取不到数据';
          break;
      }
    } finally {
      // 无论成功、失败还是抛异常，都必须复位 busy，否则界面永久卡在忙碌态。
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnectNow() async {
    smartConnect.cancel();
    await _disconnectIntentionally();
    connectedNode = null;
    connectionState = V2rayConnectionState.disconnected;
    statusMessage = '未连接';
    // 用户主动断开：重置自动重连计数，让下次是全新的开始。
    _autoReconnectAttempts = 0;
    await storage.saveLastConnectedNodeId(null);
    notifyListeners();
  }

  /// 我方主动断开隧道：打标以免紧随其后的状态流事件被误判为「意外掉线」。
  Future<void> _disconnectIntentionally() async {
    _intentionalDisconnect = true;
    try {
      await v2rayService.disconnect();
    } finally {
      _intentionalDisconnect = false;
    }
  }

  /// 插件状态流的回调：把真实隧道状态同步到界面，并在**意外掉线**时自动重连。
  void _onConnectionStateChanged(V2rayConnectionState state) {
    // 有操作在跑时不去抢状态：猎取 / 测速 / 连接流程自己会写终态。
    // （也顺带挡住 connectAndVerify 内部失败时自己 disconnect 发出的那些事件。）
    if (busy) return;

    // 我方主动断开：不当作意外掉线。
    if (_intentionalDisconnect) {
      if (connectionState != V2rayConnectionState.disconnected) {
        connectionState = V2rayConnectionState.disconnected;
        notifyListeners();
      }
      return;
    }

    if (state == V2rayConnectionState.connected) {
      if (connectionState != V2rayConnectionState.connected) {
        connectionState = V2rayConnectionState.connected;
        notifyListeners();
      }
      _autoReconnectAttempts = 0; // 连上了就重置计数
      return;
    }

    // state == disconnected
    final wasConnected = connectionState == V2rayConnectionState.connected;
    connectionState = V2rayConnectionState.disconnected;
    connectedNode = null;
    notifyListeners();

    // 只有「本来连着、却意外断了」才自动重连，且有次数上限防止死循环。
    if (wasConnected) {
      unawaited(_handleUnexpectedDrop());
    }
  }

  /// 意外掉线 → 复用「自动猎取」重新找一个当下可达的节点。
  Future<void> _handleUnexpectedDrop() async {
    if (_autoReconnectAttempts >= _kMaxAutoReconnectAttempts) {
      statusMessage = '连接已断开，自动重连多次失败，请手动重试';
      notifyListeners();
      return;
    }
    _autoReconnectAttempts++;
    statusMessage = '连接已断开，正在自动重连（第 $_autoReconnectAttempts 次）…';
    notifyListeners();
    // 直接复用自动猎取：它会自己找当下可达的节点并在成功时重置状态。
    // 刻意不 await 这个 Future —— 重连在后台跑，成功/失败都会经由
    // notifyListeners 反映到界面；上层回调是同步 void，不能 await。
    await smartConnectNow();
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

  /// 重命名订阅源（spec §8「可编辑名字」）。
  /// [ProxySubscription.name] 是可变字段，直接改即可。
  Future<void> renameSubscription(String id, String name) async {
    subscriptions = subscriptions
        .map((s) => s.id == id ? (s..name = name) : s)
        .toList();
    await storage.saveSubscriptions(subscriptions);
    notifyListeners();
  }
}
