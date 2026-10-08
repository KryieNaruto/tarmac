import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 经 App 自己核心的 SOCKS5 inbound 发一次**真实 HTTPS 请求**，判断目标可达性。
///
/// 为什么不用插件的 getConnectedServerDelay：真机实测它会对**根本连不通的目标**
/// （twitter.com 的 TLS 握手被重置）返回一个正数延迟，于是「过不了 Twitter」被
/// 误判成通过。它的返回值语义不可信。
/// 而经 SOCKS 走真实 HTTP 没有这个歧义：TLS 握手失败就是失败。
abstract class TunnelProbe {
  /// 经隧道请求 https://host:port/path；拿到 HTTP 响应即视为可达。
  Future<bool> canReach(
    String host, {
    int port = 443,
    String path = '/',
    Duration timeout = const Duration(seconds: 8),
  });
}

/// 走 App 核心 SOCKS5 inbound（默认 127.0.0.1:10807）的真实连通性探针。
///
/// 只用 dart:io，不引入任何依赖。判据：经 SOCKS 建连、完成 TLS 握手、拿回一个
/// HTTP 响应头 —— 只要读到以 "HTTP/" 开头的字节就算这条链路通。
/// 被 SNI 阻断的目标在 TLS 阶段就断，走不到这一步，因此判据干净可分辨。
class SocksTunnelProbe implements TunnelProbe {
  SocksTunnelProbe({this.proxyHost = '127.0.0.1', this.proxyPort = 10807});

  /// SOCKS5 inbound 的地址（对应插件 lib/url/url.dart 里写的 127.0.0.1:10807）。
  final String proxyHost;
  final int proxyPort;

  @override
  Future<bool> canReach(
    String host, {
    int port = 443,
    String path = '/',
    Duration timeout = const Duration(seconds: 8),
  }) {
    // 全程总超时：任何一步卡住都在这里统一收口成 false。
    return _probe(host, port, path).timeout(timeout, onTimeout: () => false);
  }

  Future<bool> _probe(String host, int port, String path) async {
    Socket? socket;
    try {
      // 1) 连上本机核心的 SOCKS5 inbound。
      socket = await Socket.connect(proxyHost, proxyPort);

      // 2) SOCKS5 方法协商：版本5、1 种方法、无认证(0x00)。
      socket.add(const <int>[0x05, 0x01, 0x00]);
      await socket.flush();

      final reader = _SocketReader(socket);
      final method = await reader.read(2);
      if (method[0] != 0x05 || method[1] != 0x00) return false;

      // 3) SOCKS5 CONNECT：用域名形式(0x03)让代理解析 DNS。
      final hostBytes = utf8.encode(host);
      if (hostBytes.isEmpty || hostBytes.length > 255) return false;
      socket.add(<int>[
        0x05, 0x01, 0x00, 0x03, hostBytes.length, ...hostBytes,
        (port >> 8) & 0xff, port & 0xff,
      ]);
      await socket.flush();

      final reply = await reader.read(4);
      // 前两字节 = 版本5、成功(0x00)；非成功即失败。
      if (reply[0] != 0x05 || reply[1] != 0x00) return false;
      // 按第 4 字节（地址类型）把随回复附带的绑定地址 + 端口字节读掉，
      // 否则这些字节会在升级 TLS 前被当成 TLS 记录、把握手搞脏。
      switch (reply[3]) {
        case 0x01: // IPv4：4 + 2
          await reader.read(4 + 2);
          break;
        case 0x03: // 域名：1(len) + len + 2
          final len = (await reader.read(1))[0];
          await reader.read(len + 2);
          break;
        case 0x04: // IPv6：16 + 2
          await reader.read(16 + 2);
          break;
        default:
          return false;
      }

      // 4) 在**已建立的 SOCKS 连接**上升级 TLS。必须传 host 作 SNI，
      //    否则 Cloudflare 会直接拒绝。
      final secure = await SecureSocket.secure(
        socket,
        host: host,
        supportedProtocols: const <String>['http/1.1'],
      );
      socket = secure; // 所有权转移给 SecureSocket，finally 统一关它

      // 5) 发一个最小 HTTP/1.1 请求。
      secure.write(
        'GET $path HTTP/1.1\r\n'
        'Host: $host\r\n'
        'User-Agent: tarmac\r\n'
        'Connection: close\r\n\r\n',
      );
      await secure.flush();

      // 6) 只要读回以 "HTTP/" 开头的内容就算链通（不要求 2xx：能拿到 HTTP
      //    响应就说明链路是通的；被 SNI 阻断的目标在 TLS 阶段就已断开）。
      final first = await secure.first;
      return utf8.decode(first, allowMalformed: true).startsWith('HTTP/');
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}

/// 逐字节读取辅助：把 socket 数据流缓冲起来，支持「读满 N 字节」。
///
/// 刻意**不暂停、也不取消**订阅 —— 读够 SOCKS 应答后，socket 还要交给
/// [SecureSocket.secure] 接管，底层订阅必须是活的（暂停的订阅会被 TLS 升级拒绝）。
/// 因此这里只持有缓冲，不做任何 pause/cancel。
class _SocketReader {
  _SocketReader(Stream<List<int>> stream) {
    stream.listen(
      (data) {
        _bytes.addAll(data);
        _signal();
      },
      onError: (Object e, StackTrace st) {
        _error = e;
        _signal();
      },
      onDone: () {
        _closed = true;
        _signal();
      },
      cancelOnError: false,
    );
  }

  final List<int> _bytes = <int>[];
  Completer<void>? _waiter;
  Object? _error;
  bool _closed = false;

  void _signal() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<void> _waitForMore() {
    if (_error != null || _closed) return Future<void>.value();
    final waiter = Completer<void>();
    _waiter = waiter;
    return waiter.future.whenComplete(() => _waiter = null);
  }

  /// 阻塞直到缓冲里凑够 [n] 字节，返回并**消费**它们。
  Future<List<int>> read(int n) async {
    while (_bytes.length < n) {
      if (_error != null) throw _error!;
      if (_closed) throw const SocketException('SOCKS 代理提前关闭了连接');
      await _waitForMore();
    }
    final out = _bytes.sublist(0, n);
    _bytes.removeRange(0, n);
    return out;
  }
}
