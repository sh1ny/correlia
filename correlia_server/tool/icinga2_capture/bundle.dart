import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The sender and the definitions a capture runs, read once.
///
/// The manifest's hashes, the files installed into the container and the
/// settings rendered from `correlia.conf` all come from these bytes, so a
/// rebuild or an edit of the inputs while the capture runs cannot make the
/// manifest name a bundle other than the one Icinga 2 ran.
final class CaptureBundle {
  CaptureBundle._(this.sender, this.contrib);

  /// Reads [sender] and every file of [contrib].
  factory CaptureBundle.read(File sender, Directory contrib) {
    final files = contrib.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return CaptureBundle._(sender.readAsBytesSync(), {
      for (final file in files)
        file.uri.pathSegments.last: file.readAsBytesSync(),
    });
  }

  /// The sender binary.
  final Uint8List sender;

  /// The definitions directory's files by name, in name order.
  final Map<String, Uint8List> contrib;

  /// The SHA-256 of [sender], in hex.
  String get senderSha256 => sha256.convert(sender).toString();

  /// The SHA-256 of each file of [contrib], in hex, by name.
  Map<String, String> get contribSha256 => {
    for (final MapEntry(:key, :value) in contrib.entries)
      key: sha256.convert(value).toString(),
  };

  /// The definition files Icinga 2 loads: the `.conf` files of [contrib].
  Map<String, Uint8List> get definitions => {
    for (final MapEntry(:key, :value) in contrib.entries)
      if (key.endsWith('.conf')) key: value,
  };

  /// The shipped `correlia.conf`, the operator settings file.
  String get shippedSettings {
    final bytes = contrib['correlia.conf'];
    if (bytes == null) {
      throw StateError('the definitions hold no correlia.conf');
    }
    return utf8.decode(bytes);
  }
}
