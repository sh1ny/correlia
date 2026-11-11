import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:correlia_server/src/plugin/openssl_engine.dart';
import 'package:correlia_server/src/plugin/plugin_tls.dart';
import 'package:ffi/ffi.dart';

final class _TrackingAllocator implements Allocator {
  final Set<int> live = {};
  int allocations = 0;
  int? failAt;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    if (allocations++ == failAt)
      throw StateError('injected allocation failure');
    final pointer = calloc.allocate<T>(byteCount, alignment: alignment);
    if (!live.add(pointer.address)) throw StateError('duplicate allocation');
    return pointer;
  }

  @override
  void free(Pointer<NativeType> pointer) {
    if (!live.remove(pointer.address)) throw StateError('unknown allocation');
    calloc.free(pointer);
  }
}

Future<void> main(List<String> args) async {
  final library = DynamicLibrary.open(args[0]);
  final install = library.lookupFunction<Int Function(), int Function()>(
    'probe_install_allocation_hooks',
  );
  final live = library.lookupFunction<Uint64 Function(), int Function()>(
    'probe_live_allocations',
  );
  if (install() != 1)
    throw StateError('OpenSSL allocation hooks installed too late');
  final certificate = await File(args[1]).readAsBytes();
  final key = await File(args[2]).readAsBytes();
  final pem = utf8
      .decode(certificate)
      .replaceAll('-----BEGIN CERTIFICATE-----', '')
      .replaceAll('-----END CERTIFICATE-----', '')
      .replaceAll(RegExp(r'\s'), '');
  final pin = base64.decode(pem);
  final allocator = _TrackingAllocator();
  final controls = PluginTlsTestControls(allocator: allocator);

  void attempt() {
    NativeTlsEngine(
      peerCertificateDer: pin,
      certificatePem: certificate,
      privateKeyPem: key,
      testControls: controls,
    ).dispose();
    var rejected = false;
    try {
      NativeTlsEngine(
        peerCertificateDer: pin,
        certificatePem: certificate,
        privateKeyPem: utf8.encode('invalid private key'),
        testControls: controls,
      ).dispose();
    } on HandshakeException {
      rejected = true;
    }
    if (!rejected || allocator.live.isNotEmpty)
      throw StateError(
        'partial initialization retained Dart allocations or accepted invalid key',
      );
  }

  for (var i = 0; i < 16; i++) {
    attempt();
  }
  final before = live();
  for (var i = 0; i < 100; i++) {
    attempt();
  }
  final after = live();
  if (before != after)
    throw StateError('OpenSSL live allocations changed: $before -> $after');

  allocator.allocations = 0;
  NativeTlsEngine(
    peerCertificateDer: pin,
    certificatePem: certificate,
    privateKeyPem: key,
    testControls: controls,
  ).dispose();
  final allocationCount = allocator.allocations;
  if (allocationCount == 0 || allocator.live.isNotEmpty)
    throw StateError('allocator was not used or retained allocations');
  for (var i = 0; i < allocationCount; i++) {
    allocator.allocations = 0;
    allocator.failAt = i;
    var failed = false;
    try {
      NativeTlsEngine(
        peerCertificateDer: pin,
        certificatePem: certificate,
        privateKeyPem: key,
        testControls: controls,
      ).dispose();
    } on Object {
      failed = true;
    }
    if (!failed || allocator.live.isNotEmpty)
      throw StateError('allocation failure $i leaked or was ignored');
    if (live() != after)
      throw StateError(
        'OpenSSL allocation imbalance at failure $i: baseline=$after current=${live()}',
      );
  }
  stdout.writeln(
    jsonEncode({
      'iterations': 100,
      'native_live_before': before,
      'native_live_after': after,
      'dart_allocation_sites': allocationCount,
      'dart_live': allocator.live.length,
    }),
  );
}
