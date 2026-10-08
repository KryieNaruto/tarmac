// test/fakes/fake_tunnel_probe.dart
import 'dart:async';
import 'package:tarmac/services/tunnel_probe.dart';

/// 测试替身：按 [reachable] 集合判断可达性，或用 [results] 脚本顺序给出结果。
///
/// - [reachable]：静态判定 —— host 在集合里就返回 true。
/// - [results]：可选脚本，按调用顺序消费；只剩一个元素时反复返回它
///   （列表不会被耗尽）。给 null 时退回 [reachable] 的静态判定。
/// - [pending]：可选闸门，非 null 时先 await 它，用于测取消竞态。
/// - [asked]：记录问过哪些 host，便于断言调用轨迹。
class FakeTunnelProbe implements TunnelProbe {
  FakeTunnelProbe({this.reachable = const <String>{}, List<bool>? results})
      : _results = results == null ? null : List<bool>.of(results);

  /// 可达的 host 集合。
  final Set<String> reachable;

  /// 顺序消费的结果脚本（null = 使用 [reachable]）。
  final List<bool>? _results;

  /// 可选闸门：不为 null 时先 await 它再返回结果。
  Completer<bool>? pending;

  /// 记录问过哪些 host。
  final List<String> asked = [];

  @override
  Future<bool> canReach(
    String host, {
    int port = 443,
    String path = '/',
    Duration timeout = const Duration(seconds: 8),
  }) {
    asked.add(host);
    final gate = pending;
    if (gate != null) return gate.future;
    final results = _results;
    if (results != null && results.isNotEmpty) {
      return Future<bool>.value(
        results.length == 1 ? results.first : results.removeAt(0),
      );
    }
    return Future<bool>.value(reachable.contains(host));
  }
}
