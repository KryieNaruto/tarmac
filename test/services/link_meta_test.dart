// test/services/link_meta_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/services/link_meta.dart';

void main() {
  test('extracts remark from trojan share link fragment', () {
    final link = 'trojan://uuid@host:443?security=tls#%F0%9F%87%AF%F0%9F%87%B5Japan';
    final meta = extractLinkMeta(link);
    expect(meta, isNotNull);
    expect(meta!.protocol, 'trojan');
    expect(meta.remark, '🇯🇵Japan');
  });

  test('extracts remark from vless share link fragment', () {
    final link = 'vless://uuid@host:443?encryption=none#US-node';
    final meta = extractLinkMeta(link);
    expect(meta!.protocol, 'vless');
    expect(meta.remark, 'US-node');
  });

  test('falls back to generic remark when fragment missing', () {
    final link = 'ss://base64stuff@host:8388';
    final meta = extractLinkMeta(link);
    expect(meta!.protocol, 'ss');
    expect(meta.remark, 'ss节点');
  });

  test('decodes vmess base64 json payload for remark', () {
    final payload = base64Encode(utf8.encode(jsonEncode({
      'v': '2',
      'ps': '🇸🇬 Singapore',
      'add': 'host.example',
      'port': '443',
      'id': 'uuid',
      'aid': '0',
      'net': 'ws',
    })));
    final link = 'vmess://$payload';
    final meta = extractLinkMeta(link);
    expect(meta!.protocol, 'vmess');
    expect(meta.remark, '🇸🇬 Singapore');
  });

  test('malformed vmess payload degrades to fallback remark instead of throwing', () {
    final link = 'vmess://not-valid-base64!!!';
    final meta = extractLinkMeta(link);
    expect(meta, isNotNull);
    expect(meta!.protocol, 'vmess');
    expect(meta.remark, '未知节点');
  });

  test('vmess payload missing ps field falls back to generic remark', () {
    final payload = base64Encode(utf8.encode(jsonEncode({
      'add': 'host.example',
      'port': '443',
      'id': 'uuid',
    })));
    final meta = extractLinkMeta('vmess://$payload');
    expect(meta!.remark, 'vmess节点');
  });

  test('returns null for unrecognized scheme', () {
    expect(extractLinkMeta('http://example.com'), isNull);
  });

  test('returns null for unparsable garbage line', () {
    expect(extractLinkMeta('not a link at all, just noise'), isNull);
  });
}
