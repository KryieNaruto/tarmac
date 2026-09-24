import '../models/proxy_node.dart';
import 'v2ray_gateway.dart';

class V2rayService {
  V2rayService(this._gateway);
  final V2rayGateway _gateway;

  Future<void> initialize() => _gateway.initialize();

  Future<List<ProxyNode>> testDelays(
    List<ProxyNode> nodes, {
    int concurrency = 8,
  }) async {
    final results = <ProxyNode>[];
    for (var i = 0; i < nodes.length; i += concurrency) {
      final batch = nodes.sublist(i, (i + concurrency).clamp(0, nodes.length));
      final tested = await Future.wait(batch.map((node) async {
        final delay = await _gateway.getServerDelay(node.rawLink);
        return node.copyWith(delayMs: delay ?? -1, lastTestedAt: DateTime.now());
      }));
      results.addAll(tested);
    }
    return results;
  }

  Future<bool> connect(ProxyNode node) async {
    final granted = await _gateway.requestPermission();
    if (!granted) return false;
    await _gateway.start(remark: node.remark, rawLink: node.rawLink);
    return true;
  }

  Future<void> disconnect() => _gateway.stop();

  Stream<V2rayConnectionState> get stateStream => _gateway.stateStream;
}
