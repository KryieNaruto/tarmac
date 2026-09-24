import 'package:http/http.dart' as http;

abstract class ConnectivityProbe {
  Future<bool> check({Duration timeout = const Duration(seconds: 5)});
}

class HttpConnectivityProbe implements ConnectivityProbe {
  HttpConnectivityProbe({http.Client? client}) : _client = client ?? http.Client();

  static const _probeUrl = 'https://cp.cloudflare.com/generate_204';
  final http.Client _client;

  @override
  Future<bool> check({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final response = await _client.get(Uri.parse(_probeUrl)).timeout(timeout);
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
