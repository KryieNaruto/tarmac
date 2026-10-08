// lib/services/v2ray_gateway.dart
import 'dart:async';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';

enum V2rayConnectionState { disconnected, connecting, connected }

abstract class V2rayGateway {
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<int?> getServerDelay(String rawLink);

  /// 通过**当前已连接**的核心实测一次请求（走活动代理）。
  /// 成功返回毫秒数；核心未连接 / 超时 / 取不到数据一律返回 null。
  Future<int?> getConnectedDelay(String url);

  Future<void> start({required String remark, required String rawLink});
  Future<void> stop();
  Stream<V2rayConnectionState> get stateStream;
}

/// Thin wrapper over flutter_v2ray_client. Platform-channel dependent —
/// validated on a real device (see the on-device check at the end of this
/// plan), not by host-machine unit tests.
class FlutterV2rayGateway implements V2rayGateway {
  FlutterV2rayGateway() {
    _v2ray = V2ray(onStatusChanged: (status) {
      _controller.add(
        status.state == 'CONNECTED'
            ? V2rayConnectionState.connected
            : V2rayConnectionState.disconnected,
      );
    });
  }

  late final V2ray _v2ray;
  final _controller = StreamController<V2rayConnectionState>.broadcast();

  @override
  Future<void> initialize() => _v2ray.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );

  @override
  Future<bool> requestPermission() => _v2ray.requestPermission();

  @override
  Future<int?> getServerDelay(String rawLink) async {
    try {
      final parser = V2ray.parseFromURL(rawLink);
      return await _v2ray.getServerDelay(config: parser.getFullConfiguration());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> getConnectedDelay(String url) async {
    try {
      final delay = await _v2ray.getConnectedServerDelay(url: url);
      return delay > 0 ? delay : null; // 插件的失败返回值 <= 0
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> start({required String remark, required String rawLink}) async {
    _controller.add(V2rayConnectionState.connecting);
    final parser = V2ray.parseFromURL(rawLink);
    await _v2ray.startV2Ray(
      remark: remark,
      config: parser.getFullConfiguration(),
      blockedApps: null,
      bypassSubnets: null,
      proxyOnly: false,
    );
  }

  @override
  Future<void> stop() async {
    await _v2ray.stopV2Ray();
    _controller.add(V2rayConnectionState.disconnected);
  }

  @override
  Stream<V2rayConnectionState> get stateStream => _controller.stream;
}
