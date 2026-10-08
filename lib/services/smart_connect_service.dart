// lib/services/smart_connect_service.dart
import '../models/proxy_node.dart';
import 'v2ray_service.dart';

enum SmartConnectResult {
  success,
  allFailed,
  noCandidates,
  cancelled,
}

/// 手动连接单个节点的结果。刻意区分失败原因——尤其要把「权限被拒」与
/// 「经该节点取不到数据」分开，否则会把用户引向错误的排查方向。
enum ConnectOutcome {
  /// 已连接，且经该节点实测通过。
  verified,

  /// 未授予 VPN 权限，连接未启动。
  permissionDenied,

  /// 连接起了，但窗口内经该节点取不到数据
  /// ——节点本身不可用（隧道可能已建起，只是经它发不出请求）。
  proxyUnavailable,
}

class SmartConnectOutcome {
  SmartConnectOutcome({required this.result, this.node});
  final SmartConnectResult result;
  final ProxyNode? node;
}

class SmartConnectService {
  SmartConnectService(this._v2ray);
  final V2rayService _v2ray;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<SmartConnectOutcome> connectBest(
    List<ProxyNode> nodes, {
    int maxCandidates = 15,
    Duration establishWindow = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 800),
    Duration totalBudget = const Duration(seconds: 60),
    String verifyUrl = V2rayService.kVerifyUrl,
    void Function(ProxyNode)? onAttempt,
  }) async {
    _cancelled = false;

    final candidates = nodes.where((n) => n.delayMs != null && n.delayMs! >= 0).toList()
      ..sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    if (candidates.isEmpty) {
      return SmartConnectOutcome(result: SmartConnectResult.noCandidates);
    }

    // 按延迟升序逐个候选：连接 → 让核心经该节点实测 → 通过即成功，
    // 否则断开换下一个，直到超出 totalBudget 或候选用尽。
    final deadline = DateTime.now().add(totalBudget);
    for (final node in candidates.take(maxCandidates)) {
      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }
      if (DateTime.now().isAfter(deadline)) break;

      onAttempt?.call(node);
      final result = await _startAndAwaitProxy(
        node,
        establishWindow: establishWindow,
        pollInterval: pollInterval,
        verifyUrl: verifyUrl,
      );
      if (result == null) continue;   // connect 未启动：没起隧道，直接试下一个

      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }

      if (result) {
        return SmartConnectOutcome(result: SmartConnectResult.success, node: node);
      }
      // 窗口内经该节点始终取不到数据 → 该候选并未真正打通，断开后试下一个。
      await _v2ray.disconnect();
    }

    return SmartConnectOutcome(result: SmartConnectResult.allFailed);
  }

  /// 连接指定节点，并让核心经该节点实测一次请求。
  /// 返回 [ConnectOutcome] 如实区分失败原因；只有「起了但取不到数据」这条
  /// 才**自己断开**，其余（权限被拒）根本没起隧道，不该 disconnect。
  Future<ConnectOutcome> connectAndVerify(
    ProxyNode node, {
    Duration establishWindow = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 800),
    String verifyUrl = V2rayService.kVerifyUrl,
  }) async {
    // 每次操作重新开始，与 connectBest 一致（此前可能被 cancel() 置过 true）。
    _cancelled = false;

    final result = await _startAndAwaitProxy(
      node,
      establishWindow: establishWindow,
      pollInterval: pollInterval,
      verifyUrl: verifyUrl,
    );

    if (result == null) return ConnectOutcome.permissionDenied; // connect 未启动，没起隧道
    if (result) return ConnectOutcome.verified;                 // 校验通过：保持连接
    await _v2ray.disconnect();                                  // 起了但取不到数据：自己收干净
    return ConnectOutcome.proxyUnavailable;
  }

  /// 发起连接并等待核心经该节点实测通过。
  /// 服务「启动」不代表代理「已就绪」(tun 路由可能还没生效)，所以必须轮询，
  /// 不能只测一次。返回 null 表示 connect 未启动（没起隧道，调用方无需 disconnect）；
  /// true 已实测通过；false 起了但窗口内取不到数据（由调用方负责 disconnect）。
  Future<bool?> _startAndAwaitProxy(
    ProxyNode node, {
    required Duration establishWindow,
    required Duration pollInterval,
    required String verifyUrl,
  }) async {
    final started = await _v2ray.connect(node);
    if (!started) return null;
    return _awaitCoreProxy(
      window: establishWindow,
      pollInterval: pollInterval,
      verifyUrl: verifyUrl,
    );
  }

  /// 轮询让核心经该节点实测一次，直到成功或超过 [window]。
  /// 用核心而不是本机 HTTP 探针：本 App 的流量被插件有意排除在 VPN 之外，
  /// 自己发请求永远走直连、测不到隧道（真机实证）。
  Future<bool> _awaitCoreProxy({
    required Duration window,
    required Duration pollInterval,
    required String verifyUrl,
  }) async {
    final end = DateTime.now().add(window);
    while (true) {
      if (_cancelled) return false;
      final delay = await _v2ray.verifyConnected(url: verifyUrl);
      if (_cancelled) return false;
      if (delay != null && delay > 0) return true;
      if (!DateTime.now().isBefore(end)) return false;
      await Future.delayed(pollInterval);
    }
  }
}
