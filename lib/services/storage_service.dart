// lib/services/storage_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/proxy_node.dart';
import '../models/subscription.dart';

const _kSubscriptionsKey = 'tarmac.subscriptions';
const _kManualNodesKey = 'tarmac.manual_nodes';
const _kLastConnectedKey = 'tarmac.last_connected_node_id';

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
}
