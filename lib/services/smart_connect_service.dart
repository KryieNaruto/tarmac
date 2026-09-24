// lib/services/smart_connect_service.dart
import '../models/proxy_node.dart';
import 'connectivity_probe.dart';
import 'v2ray_service.dart';

enum SmartConnectResult { success, allFailed, noCandidates, cancelled }

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
    Duration probeTimeout = const Duration(seconds: 5),
    Duration totalBudget = const Duration(seconds: 60),
    void Function(ProxyNode)? onAttempt,
  }) async {
    _cancelled = false;

    final candidates = nodes.where((n) => n.delayMs != null && n.delayMs! >= 0).toList()
      ..sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    if (candidates.isEmpty) {
      return SmartConnectOutcome(result: SmartConnectResult.noCandidates);
    }

    final deadline = DateTime.now().add(totalBudget);
    for (final node in candidates.take(maxCandidates)) {
      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }
      if (DateTime.now().isAfter(deadline)) break;

      onAttempt?.call(node);
      final started = await _v2ray.connect(node);
      if (!started) continue;

      final ok = await _probe.check(timeout: probeTimeout);

      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }

      if (ok) {
        return SmartConnectOutcome(result: SmartConnectResult.success, node: node);
      }
      await _v2ray.disconnect();
    }

    return SmartConnectOutcome(result: SmartConnectResult.allFailed);
  }
}
