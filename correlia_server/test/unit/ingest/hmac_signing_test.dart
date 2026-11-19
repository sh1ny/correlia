import 'dart:convert';
import 'dart:typed_data';

import 'package:correlia_server/src/ingest/hmac_signing.dart';
import 'package:test/test.dart';

void main() {
  test('published_signing_vector', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final body = utf8.encode('{"status":"firing"}');
    expect(
      signIngress(key, ingressSigningPrefix('1794960000', 'hook-42'), body),
      'd1f085472bf0810321dfd82e0fe82b030183b0d5fac61e04e1b177cf190c29e1',
    );
    expect(
      signIngress(key, ingressSigningPrefix('1794960000', null), body),
      '1312b999043956efa24658369e0edfd4a94820d000efa08437b9a6ac4ee00e99',
    );
  });
}
