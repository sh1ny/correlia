import 'dart:convert';
import 'dart:typed_data';

import '../ingest/bootstrap.dart';

/// Reads a canonical unpadded 32-byte key from a private file.
///
/// [effectiveUid] permits exercising the owner check in unprivileged tests.
Future<Uint8List> loadSecretKey(String path, {int? effectiveUid}) async {
  final bytes = await readBootstrapFile(
    path,
    'secret_key',
    cap: 44,
    private: true,
    effectiveUid: effectiveUid,
  );
  const invalid = BootstrapError('secret_key', r'$', 'format');
  try {
    if (bytes.length != 43 && !(bytes.length == 44 && bytes[43] == 10)) {
      throw invalid;
    }
    final text = String.fromCharCodes(bytes, 0, 43);
    final key = base64Url.decode('$text=');
    if (key.length != 32 || base64Url.encode(key) != '$text=') throw invalid;
    return key;
  } on FormatException {
    throw invalid;
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}
