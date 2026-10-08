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
        id: 'https://raw.githubusercontent.com/mohammadaz2/v2rayConfigsForYou/main/configs.txt',
        name: 'mohammadaz2',
        url: 'https://raw.githubusercontent.com/mohammadaz2/v2rayConfigsForYou/main/configs.txt',
      ),
    ];

/// 已退役的内置默认源 id（订阅文件早已停止更新）。
/// 迁移时**只**删这些 id，绝不碰用户自己添加的订阅。
const _kRetiredDefaultSubIds = <String>{
  'https://raw.githubusercontent.com/freefq/free/master/v2',
  'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt',
};

/// 把退役的死默认源从存量订阅里摘掉，并补上当前默认源里还没有的那些。
/// 只按 id 精确匹配；用户自建的同名订阅（id 是别的 URL）不受影响。
///
/// 仅在「存量列表里确实还留着退役源」时触发 —— 也就是从旧版本升上来的安装。
/// 摘干净之后就永不再动手，因此用户此后删掉任何内置源都是粘性的，
/// 不会被下次启动重新加回来（除非他自己把退役的 URL 又贴回去）。
/// 返回 null 表示无需迁移，调用方应原样返回且不落盘。
List<ProxySubscription>? migrateDefaultSubscriptions(
  List<ProxySubscription> current,
) {
  final hasRetired = current.any((s) => _kRetiredDefaultSubIds.contains(s.id));
  if (!hasRetired) return null;

  final kept = current
      .where((s) => !_kRetiredDefaultSubIds.contains(s.id))
      .toList();
  final ids = kept.map((s) => s.id).toSet();
  for (final d in defaultSubscriptions()) {
    if (ids.add(d.id)) kept.add(d);
  }
  return kept;
}

class StorageService {
  /// 读订阅列表。存量安装里可能还留着早已停更的旧默认源，
  /// 这里只在「从旧版本升上来、列表里还留着退役源」时迁移一次；迁移过或新装的用户不再受影响，
  /// 从而保证用户自己删掉内置源的操作是粘性的。
  Future<List<ProxySubscription>> loadSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSubscriptionsKey);
    if (raw == null) return defaultSubscriptions();
    final list = jsonDecode(raw) as List<dynamic>;
    final stored = list
        .map((e) => ProxySubscription.fromJson(e as Map<String, dynamic>))
        .toList();
    final migrated = migrateDefaultSubscriptions(stored);
    if (migrated == null) return stored;
    await saveSubscriptions(migrated);
    return migrated;
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
