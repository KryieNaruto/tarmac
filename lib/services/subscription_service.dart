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

class SubscriptionService {
  Future<FetchResult> fetchAndParse(
    ProxySubscription sub, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.get(Uri.parse(sub.url)).timeout(timeout);
      if (response.statusCode != 200) {
        return FetchResult(nodes: const [], error: 'HTTP ${response.statusCode}');
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
      return FetchResult(nodes: nodes, error: null);
    } catch (e) {
      return FetchResult(nodes: const [], error: e.toString());
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
