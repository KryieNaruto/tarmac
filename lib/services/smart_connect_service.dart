// lib/services/smart_connect_service.dart
import '../models/proxy_node.dart';
import 'connectivity_probe.dart';
import 'v2ray_service.dart';

enum SmartConnectResult {
  success,
  allFailed,
  noCandidates,
  cancelled,

  /// 拿不到直连基线，无法校验任何候选；这不是节点的错。
  egressCheckUnavailable,
}

/// 手动连接单个节点的结果。刻意区分失败原因——尤其要把
/// 「无法校验出口 IP」与「隧道没打通」分开，否则会把用户引向错误的排查方向。
enum ConnectOutcome {
  /// 已连接，且出口 IP 确实变了（真连通）。
  verified,

  /// 拿不到直连基线（探测端点不可达），无法校验，**未发起连接**。
  egressCheckUnavailable,

  /// 未授予 VPN 权限，连接未启动。
  permissionDenied,

  /// 隧道起了但窗口内出口 IP 没变 —— 流量确实没走隧道。
  tunnelNotEstablished,
}

class SmartConnectOutcome {
  SmartConnectOutcome({required this.result, this.node});
  final SmartConnectResult result;
  final ProxyNode? node;
}

class SmartConnectService {
  SmartConnectService(this._v2ray, this._probe);
  final V2rayService _v2ray;
  final ConnectivityProbe _probe;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<SmartConnectOutcome> connectBest(
    List<ProxyNode> nodes, {
    int maxCandidates = 15,
    Duration establishWindow = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 800),
    Duration ipProbeTimeout = const Duration(seconds: 3),
    Duration totalBudget = const Duration(seconds: 60),
    void Function(ProxyNode)? onAttempt,
  }) async {
    _cancelled = false;

    final candidates = nodes.where((n) => n.delayMs != null && n.delayMs! >= 0).toList()
      ..sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    if (candidates.isEmpty) {
      return SmartConnectOutcome(result: SmartConnectResult.noCandidates);
    }

    // 级联开始前，先记下直连时的公网出口 IP 作为基准。后面每个候选都要等到
    // 出口 IP 不再等于它，才算「流量真的走了隧道」。
    final baseline = await _probe.egressIp(timeout: ipProbeTimeout);

    if (_cancelled) {
      await _v2ray.disconnect();
      return SmartConnectOutcome(result: SmartConnectResult.cancelled);
    }

    // 刻意的 fail-closed：基线取不到就无法比对「出口 IP 有没有变」，
    // 这种情况下绝不宣称连通——也不要退回「假连通」（隧道是死的、设备本身有网，
    // 探测照样通过）的老行为。这**不是节点的错**，所以单列
    // egressCheckUnavailable，而不是误导性的 allFailed（会让人去换节点）。
    // 也别为了一个注定判不了的级联白跑 15 个候选（每个还要等 establishWindow）。
    if (baseline == null) {
      return SmartConnectOutcome(
        result: SmartConnectResult.egressCheckUnavailable,
      );
    }

    final deadline = DateTime.now().add(totalBudget);
    for (final node in candidates.take(maxCandidates)) {
      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }
      if (DateTime.now().isAfter(deadline)) break;

      onAttempt?.call(node);
      final result = await _startAndAwaitEgressChange(
        node,
        baseline,
        establishWindow: establishWindow,
        pollInterval: pollInterval,
        ipProbeTimeout: ipProbeTimeout,
      );
      if (result == null) continue;   // connect 未启动：没起隧道，直接试下一个

      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }

      if (result) {
        return SmartConnectOutcome(result: SmartConnectResult.success, node: node);
      }
      // 窗口内出口 IP 始终没变 → 该候选并未真正打通，断开后试下一个。
      await _v2ray.disconnect();
    }

    return SmartConnectOutcome(result: SmartConnectResult.allFailed);
  }

  /// 连接指定节点，并校验流量真的走了隧道（出口 IP 变化）。
  /// 返回 [ConnectOutcome] 如实区分失败原因；只有「隧道起了但没通」这条
  /// 才**自己断开**，其余（无法校验 / 权限被拒）根本没起隧道，不该 disconnect。
  Future<ConnectOutcome> connectAndVerify(
    ProxyNode node, {
    Duration establishWindow = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 800),
    Duration ipProbeTimeout = const Duration(seconds: 3),
  }) async {
    // 每次操作重新开始，与 connectBest 一致（此前可能被 cancel() 置过 true）。
    _cancelled = false;

    final baseline = await _probe.egressIp(timeout: ipProbeTimeout);
    // 刻意的 fail-closed：取不到基线就无法比对「出口 IP 有没有变」，
    // 绝不宣称连通，也别为一个注定判不了的连接白起一次隧道。
    if (baseline == null) return ConnectOutcome.egressCheckUnavailable;

    final result = await _startAndAwaitEgressChange(
      node,
      baseline,
      establishWindow: establishWindow,
      pollInterval: pollInterval,
      ipProbeTimeout: ipProbeTimeout,
    );

    if (result == null) return ConnectOutcome.permissionDenied; // connect 未启动，没起隧道
    if (result) return ConnectOutcome.verified;                 // 校验通过：保持连接
    await _v2ray.disconnect();                                  // 起了但没通：自己收干净
    return ConnectOutcome.tunnelNotEstablished;
  }

  /// 发起连接并等待出口 IP 相对 [baseline] 发生变化（真连通的判据）。
  /// 服务「启动」不代表隧道「已建立」(tun 路由可能还没生效)，所以必须轮询，
  /// 不能只探一次。返回 null 表示 connect 未启动（没起隧道，调用方无需 disconnect）；
  /// true 已校验连通；false 起了隧道但窗口内未变（由调用方负责 disconnect）。
  Future<bool?> _startAndAwaitEgressChange(
    ProxyNode node,
    String baseline, {
    required Duration establishWindow,
    required Duration pollInterval,
    required Duration ipProbeTimeout,
  }) async {
    final started = await _v2ray.connect(node);
    if (!started) return null;
    return _awaitEgressChange(
      baseline,
      window: establishWindow,
      pollInterval: pollInterval,
      ipProbeTimeout: ipProbeTimeout,
    );
  }

  /// 轮询出口 IP，直到它出现且不再等于 [baseline]（判为真连通）或超过 [window]。
  /// 轮询期间尊重取消语义：一发现 `_cancelled` 立即返回 false，由调用方断连。
  Future<bool> _awaitEgressChange(
    String baseline, {
    required Duration window,
    required Duration pollInterval,
    required Duration ipProbeTimeout,
  }) async {
    final end = DateTime.now().add(window);
    while (true) {
      if (_cancelled) return false;
      final ip = await _probe.egressIp(timeout: ipProbeTimeout);
      if (_cancelled) return false;
      if (ip != null && ip != baseline) return true;
      if (!DateTime.now().isBefore(end)) return false;
      await Future.delayed(pollInterval);
    }
  }
}
