// lib/services/storage_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/proxy_node.dart';
import '../models/subscription.dart';

const _kSubscriptionsKey = 'tarmac.subscriptions';
const _kManualNodesKey = 'tarmac.manual_nodes';
const _kLastConnectedKey = 'tarmac.last_connected_node_id';
const _kNodeDelaysKey = 'tarmac.node_delays';       // JSON: {rawLink: delayMs}
const _kLastRetestAtKey = 'tarmac.last_retest_at';  // ISO8601 字符串

List<ProxySubscription> defaultSubscriptions() => [
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/freefq/free/master/v2',
        name: 'freefq',
        url: 'https://raw.githubusercontent.com/freefq/free/master/v2',
      ),
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub',
        name: 'Pawdroid',
        url: 'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub',
      ),
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt',
        name: 'ermaozi',
        url: 'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt',
      ),
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt',
        name: 'V2RayAggregator',
        url: 'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt',
      ),
    ];

class StorageService {
  Future<List<ProxySubscription>> loadSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSubscriptionsKey);
    if (raw == null) return defaultSubscriptions();
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => ProxySubscription.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveSubscriptions(List<ProxySubscription> subs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kSubscriptionsKey,
      jsonEncode(subs.map((s) => s.toJson()).toList()),
    );
  }

  Future<List<ProxyNode>> loadManualNodes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kManualNodesKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => ProxyNode.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveManualNodes(List<ProxyNode> nodes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kManualNodesKey,
      jsonEncode(nodes.map((n) => n.toJson()).toList()),
    );
  }

  Future<String?> loadLastConnectedNodeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastConnectedKey);
  }

  Future<void> saveLastConnectedNodeId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_kLastConnectedKey);
    } else {
      await prefs.setString(_kLastConnectedKey, id);
    }
  }

  /// 已缓存的节点延迟，按 rawLink 索引。没有缓存或解析失败时返回空 map。
  ///
  /// 与 [loadSubscriptions] 不同，这里刻意容错：坏数据只丢弃、不抛。
  Future<Map<String, int>> loadNodeDelays() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kNodeDelaysKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, int>{};
      decoded.forEach((key, value) {
        // JSON 里的 42 可能被解成 42.0，用 num 宽容转换；null / 字符串直接跳过。
        if (key is String && value is num) {
          result[key] = value.toInt();
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  /// 保存延迟缓存与本次测速时间。**只写传进来的这些节点**（调用方负责裁剪）。
  /// 空 map 也照常写（是否该写由调用方决定）。
  Future<void> saveNodeDelays(
    Map<String, int> byRawLink,
    DateTime testedAt,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNodeDelaysKey, jsonEncode(byRawLink));
    await prefs.setString(_kLastRetestAtKey, testedAt.toIso8601String());
  }

  /// 上次测速时间；从未测过或解析失败返回 null。
  Future<DateTime?> loadLastRetestAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastRetestAtKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }
}
