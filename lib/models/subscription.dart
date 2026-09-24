// lib/models/subscription.dart
class ProxySubscription {
  ProxySubscription({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.lastFetchedAt,
    this.nodeCount = 0,
    this.lastError,
  });

  final String id;
  String name;
  String url;
  bool enabled;
  DateTime? lastFetchedAt;
  int nodeCount;
  String? lastError;

  ProxySubscription copyWith({
    bool? enabled,
    DateTime? lastFetchedAt,
    int? nodeCount,
    String? lastError,
    bool clearError = false,
  }) {
    return ProxySubscription(
      id: id,
      name: name,
      url: url,
      enabled: enabled ?? this.enabled,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      nodeCount: nodeCount ?? this.nodeCount,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'lastFetchedAt': lastFetchedAt?.toIso8601String(),
        'nodeCount': nodeCount,
        'lastError': lastError,
      };

  factory ProxySubscription.fromJson(Map<String, dynamic> json) =>
      ProxySubscription(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        enabled: json['enabled'] as bool? ?? true,
        lastFetchedAt: json['lastFetchedAt'] == null
            ? null
            : DateTime.parse(json['lastFetchedAt'] as String),
        nodeCount: json['nodeCount'] as int? ?? 0,
        lastError: json['lastError'] as String?,
      );
}
