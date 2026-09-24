// lib/models/proxy_node.dart
class ProxyNode {
  ProxyNode({
    required this.id,
    required this.remark,
    required this.protocol,
    required this.rawLink,
    required this.sourceSubId,
    this.delayMs,
    this.lastTestedAt,
  });

  final String id;
  final String remark;
  final String protocol;
  final String rawLink;
  final String sourceSubId;
  final int? delayMs;
  final DateTime? lastTestedAt;

  ProxyNode copyWith({
    String? remark,
    int? delayMs,
    DateTime? lastTestedAt,
  }) {
    return ProxyNode(
      id: id,
      remark: remark ?? this.remark,
      protocol: protocol,
      rawLink: rawLink,
      sourceSubId: sourceSubId,
      delayMs: delayMs ?? this.delayMs,
      lastTestedAt: lastTestedAt ?? this.lastTestedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'remark': remark,
        'protocol': protocol,
        'rawLink': rawLink,
        'sourceSubId': sourceSubId,
        'delayMs': delayMs,
        'lastTestedAt': lastTestedAt?.toIso8601String(),
      };

  factory ProxyNode.fromJson(Map<String, dynamic> json) => ProxyNode(
        id: json['id'] as String,
        remark: json['remark'] as String,
        protocol: json['protocol'] as String,
        rawLink: json['rawLink'] as String,
        sourceSubId: json['sourceSubId'] as String,
        delayMs: json['delayMs'] as int?,
        lastTestedAt: json['lastTestedAt'] == null
            ? null
            : DateTime.parse(json['lastTestedAt'] as String),
      );
}
