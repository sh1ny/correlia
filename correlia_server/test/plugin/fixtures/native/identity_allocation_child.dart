import 'dart:ffi';

import 'package:correlia_server/src/plugin/openssl_engine.dart';

void main(List<String> args) {
  final library = DynamicLibrary.open(args.single);
  final install = library.lookupFunction<Int Function(), int Function()>(
    'probe_install_allocation_hooks',
  );
  final live = library.lookupFunction<Uint64 Function(), int Function()>(
    'probe_live_allocations',
  );
  if (install() != 1) {
    throw StateError('OpenSSL allocation hooks installed too late');
  }
  for (var i = 0; i < 20; i++) {
    mintPluginIdentity();
  }
  final before = live();
  for (var i = 0; i < 100; i++) {
    mintPluginIdentity();
  }
  final after = live();
  if (before != after) {
    throw StateError('OpenSSL identity allocations changed: $before -> $after');
  }
}
