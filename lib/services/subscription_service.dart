// lib/services/subscription_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/proxy_node.dart';
import '../models/subscription.dart';
import 'link_meta.dart';

/// Auto-detects whether a subscription body is a base64-encoded blob or
/// already plain-text share links, and returns the plain-text form either way.
String normalizeContent(String rawBody) {
  final trimmed = rawBody.trim();
  try {
    final decoded = utf8.decode(base64.decode(base64.normalize(trimmed)));
    if (decoded.contains('://')) return decoded;
  } catch (_) {
    // not valid base64 — fall through to plain-text handling
  }
  return rawBody;
}

class FetchResult {
  FetchResult({required this.nodes, this.error});
  final List<ProxyNode> nodes;
  final String? error;
}

/// 单次请求的内部结果。比 [FetchResult] 多带一个 [retryable] 标志，
/// 只供 [SubscriptionService.fetchAndParse] 判断要不要再试一次；
/// 对外返回的仍然是形状不变的 [FetchResult]。
class _AttemptResult {
  _AttemptResult({required this.nodes, this.error, this.retryable = false});
  final List<ProxyNode> nodes;
  final String? error;
  final bool retryable;
}

class SubscriptionService {
  /// 拉取并解析一个订阅源。
  ///
  /// [maxAttempts] 是**总尝试次数**（含首次），默认 2 = 首次 + 重试 1 次；
  /// 每次尝试之间等待 [retryBackoff]（最后一次失败后不再等待）。
  /// 只有「可重试」的失败才会重试，见 [_attempt]。
  Future<FetchResult> fetchAndParse(
    ProxySubscription sub, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
    int maxAttempts = 2,
    Duration retryBackoff = const Duration(milliseconds: 500),
  }) async {
    final httpClient = client ?? http.Client();
    var last = FetchResult(nodes: const [], error: '未发起请求');
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final result = await _attempt(httpClient, sub, timeout);
      last = FetchResult(nodes: result.nodes, error: result.error);
      if (result.error == null) return last;
      if (!result.retryable) return last;
      // 最后一次失败后不再退避等待，直接返回。
      if (attempt < maxAttempts) await Future.delayed(retryBackoff);
    }
    return last;
  }

  /// 发起单次请求并解析。失败时标注是否值得重试：
  /// 网络类异常、以及 5xx / 429（限流或服务端临时故障）可重试；
  /// 其余 4xx（404 / 403 / 401 等）重试无意义，不重试。
  Future<_AttemptResult> _attempt(
    http.Client httpClient,
    ProxySubscription sub,
    Duration timeout,
  ) async {
    try {
      final response = await httpClient.get(Uri.parse(sub.url)).timeout(timeout);
      if (response.statusCode != 200) {
        final retryable =
            response.statusCode >= 500 || response.statusCode == 429;
        return _AttemptResult(
          nodes: const [],
          error: 'HTTP ${response.statusCode}',
          retryable: retryable,
        );
      }
      final content = normalizeContent(response.body);
      final nodes = <ProxyNode>[];
      for (final line in content.split('\n')) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty) continue;
        final meta = extractLinkMeta(trimmedLine);
        if (meta == null) continue;
        nodes.add(ProxyNode(
          id: trimmedLine,
          remark: meta.remark,
          protocol: meta.protocol,
          rawLink: trimmedLine,
          sourceSubId: sub.id,
        ));
      }
      return _AttemptResult(nodes: nodes);
    } catch (e) {
      // TimeoutException / SocketException / http.ClientException /
      // HandshakeException 等一律算网络类失败：限流丢连接时，
      // 光等没用，重开一条连接才有用，所以标为可重试。
      return _AttemptResult(
        nodes: const [],
        error: e.toString(),
        retryable: true,
      );
    }
  }
}

/// Collapses nodes with the same rawLink across subscriptions, keeping the
/// first occurrence encountered.
List<ProxyNode> dedupeNodes(List<ProxyNode> nodes) {
  final seen = <String>{};
  final result = <ProxyNode>[];
  for (final node in nodes) {
    if (seen.add(node.id)) result.add(node);
  }
  return result;
}

/// 把缓存的延迟按 rawLink 合回刚拉取的节点。
/// 命中的节点带上 delayMs 与 testedAt；未命中的保持原样（delayMs 仍为 null）。
/// 纯函数，不改入参。
List<ProxyNode> applyCachedDelays(
  List<ProxyNode> nodes,
  Map<String, int> cachedDelays, {
  DateTime? testedAt,
}) {
  // 空缓存直接返回原列表，避免无谓拷贝。
  if (cachedDelays.isEmpty) return nodes;
  return [
    for (final node in nodes)
      if (cachedDelays.containsKey(node.rawLink))
        node.copyWith(
          delayMs: cachedDelays[node.rawLink],
          lastTestedAt: testedAt,
        )
      else
        node,
  ];
}

/// 按延迟排序：可用节点（delayMs 非 null 且 >= 0）按延迟升序排在前面；
/// 未测速（null）与超时（< 0）保持它们原本的相对顺序、整体沉底。
///
/// 注意：这里用「稳定分区」而不是对整条 list 调 sort —— Dart 的 List.sort
/// 不是稳定排序，会把未测速那一段每次打乱，列表会无谓地乱跳。
List<ProxyNode> sortByDelay(List<ProxyNode> nodes) {
  // 稳定分区：只对可用节点排序，其余按原相对顺序沉底。
  final usable = <ProxyNode>[];
  final rest = <ProxyNode>[];
  for (final node in nodes) {
    final delay = node.delayMs;
    if (delay != null && delay >= 0) {
      usable.add(node);
    } else {
      rest.add(node);
    }
  }
  usable.sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
  return [...usable, ...rest];
}
