import 'dart:convert';
import 'dart:io';

import 'package:correlia_client/correlia_client.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'child_server.dart';

final _tokenBytes = List<int>.filled(32, 203);
final operatorToken = base64Url.encode(_tokenBytes).replaceAll('=', '');
const operatorMachine = 'demo-runner';

/// Configures the isolated test machine with its precomputed bearer digest.
Future<File> operatorCredentials(String path) async {
  final file = await File(path).writeAsString(
    jsonEncode({operatorMachine: sha256.convert(_tokenBytes).toString()}),
  );
  expect((await Process.run('chmod', ['600', file.path])).exitCode, 0);
  return file;
}

final class _OperatorHeader implements ClientAuthKeyProvider {
  const _OperatorHeader();

  @override
  Future<String?> get authHeaderValue async => 'Bearer $operatorToken';
}

/// Returns the generated RPC client with the test machine's bearer header.
Client operatorClient(ChildServer child) => Client(
  'http://127.0.0.1:${child.apiPort}/',
)..authKeyProvider = const _OperatorHeader();
