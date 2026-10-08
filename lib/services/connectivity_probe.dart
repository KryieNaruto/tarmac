import 'package:http/http.dart' as http;

abstract class ConnectivityProbe {
  /// 当前公网出口 IP；取不到返回 null（拿不到就**不能**判定连通）。
  Future<String?> egressIp({Duration timeout = const Duration(seconds: 5)});
}

class HttpConnectivityProbe implements ConnectivityProbe {
  HttpConnectivityProbe({http.Client? client}) : _client = client ?? http.Client();

  // 与旧的 /generate_204 同一主机：直连和走隧道都能到达，因此两个方向的
  // 出口 IP 可比对。纯文本响应里有一行 `ip=<公网出口 IP>`。
  static const _probeUrl = 'https://cp.cloudflare.com/cdn-cgi/trace';
  final http.Client _client;

  @override
  Future<String?> egressIp({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final response = await _client.get(Uri.parse(_probeUrl)).timeout(timeout);
      // 仅在 200 时解析；其余状态码一律视作「取不到」。
      if (response.statusCode != 200) return null;
      // 按行找以 `ip=` 开头的那一行，取等号后面的值。
      for (final line in response.body.split('\n')) {
        if (line.startsWith('ip=')) {
          final value = line.substring('ip='.length).trim();
          return value.isEmpty ? null : value;
        }
      }
      return null;
    } catch (_) {
      // 网络异常、解析异常、超时 → 一律 null（判定不了，不冒充连通）。
      return null;
    }
  }
}
