// lib/services/link_meta.dart
import 'dart:convert';

class LinkMeta {
  LinkMeta({required this.protocol, required this.remark});
  final String protocol;
  final String remark;
}

const _knownSchemes = {'vmess', 'vless', 'trojan', 'ss', 'socks'};

LinkMeta? extractLinkMeta(String rawLink) {
  final schemeEnd = rawLink.indexOf('://');
  if (schemeEnd == -1) return null;
  final scheme = rawLink.substring(0, schemeEnd).toLowerCase();
  if (!_knownSchemes.contains(scheme)) return null;

  if (scheme == 'vmess') {
    return LinkMeta(protocol: 'vmess', remark: _vmessRemark(rawLink.substring(schemeEnd + 3)));
  }

  final uri = Uri.tryParse(rawLink);
  final fragment = uri?.fragment ?? '';
  final remark = fragment.isNotEmpty ? Uri.decodeComponent(fragment) : '$scheme节点';
  return LinkMeta(protocol: scheme, remark: remark);
}

String _vmessRemark(String base64Payload) {
  try {
    final normalized = base64.normalize(base64Payload.trim());
    final jsonStr = utf8.decode(base64.decode(normalized));
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    final ps = map['ps'] as String?;
    if (ps != null && ps.trim().isNotEmpty) return ps;
    return 'vmess节点';
  } catch (_) {
    return '未知节点';
  }
}
