// test/services/tunnel_probe_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/services/tunnel_probe.dart';

/// 测试用的小工具：把服务端 socket 的数据流缓冲起来，支持「读满 N 字节」。
/// 刻意不用 `.first` —— 那会取消订阅、关掉 receive 方向，读不了多段。
class _Buf {
  _Buf(Stream<List<int>> stream) {
    stream.listen(
      (data) {
        _bytes.addAll(data);
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      cancelOnError: false,
    );
  }

  final List<int> _bytes = <int>[];
  bool _closed = false;
  Completer<void>? _waiter;

  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<List<int>> read(int n) async {
    while (_bytes.length < n) {
      if (_closed) throw StateError('服务端连接已关闭');
      final waiter = Completer<void>();
      _waiter = waiter;
      await waiter.future;
      _waiter = null;
    }
    final out = _bytes.sublist(0, n);
    _bytes.removeRange(0, n);
    return out;
  }
}

Future<ServerSocket> _bind() =>
    ServerSocket.bind(InternetAddress.loopbackIPv4, 0);

void main() {
  test('SOCKS5 握手被代理拒绝（返回非 [0x05,0x00]）→ false', () async {
    final server = await _bind();
    addTearDown(server.close);
    server.listen((client) async {
      final buf = _Buf(client);
      await buf.read(3); // 客户端发来的方法协商
      client.add(const <int>[0x05, 0xFF]); // 没有可接受的方法
    });

    final probe = SocksTunnelProbe(proxyPort: server.port);
    final ok = await probe.canReach(
      'example.com',
      timeout: const Duration(seconds: 2),
    );

    expect(ok, isFalse);
  });

  test('SOCKS5 CONNECT 失败（返回非 0x00）→ false', () async {
    final server = await _bind();
    addTearDown(server.close);
    server.listen((client) async {
      final buf = _Buf(client);
      await buf.read(3); // 方法协商
      client.add(const <int>[0x05, 0x00]); // 接受：无认证
      final head = await buf.read(5); // ver cmd rsv atyp len
      final len = head[4];
      await buf.read(len + 2); // 域名 + 端口
      // 版本5、rep=0x05（连接被拒），再补一段地址占位。
      client.add(const <int>[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
    });

    final probe = SocksTunnelProbe(proxyPort: server.port);
    final ok = await probe.canReach(
      'example.com',
      timeout: const Duration(seconds: 2),
    );

    expect(ok, isFalse);
  });

  test('连不上代理端口 → false', () async {
    // 先占一个端口再放掉，拿一个几乎没人用的端口去连。
    final tmp = await _bind();
    final port = tmp.port;
    await tmp.close();

    final probe = SocksTunnelProbe(proxyPort: port);
    final ok = await probe.canReach(
      'example.com',
      timeout: const Duration(seconds: 2),
    );

    expect(ok, isFalse);
  });

  test('极小 SOCKS5 假服务器一接受就关闭 → false', () async {
    final server = await _bind();
    addTearDown(server.close);
    server.listen((client) => client.destroy());

    final probe = SocksTunnelProbe(proxyPort: server.port);
    final ok = await probe.canReach(
      'example.com',
      timeout: const Duration(seconds: 2),
    );

    expect(ok, isFalse);
  });
}
