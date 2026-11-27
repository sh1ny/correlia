part of 'bootstrap.dart';

// Linux statx returns a 256-byte struct on every supported architecture. Only
// this initial portion is needed; the buffer passed to libc is the full size.
final class _StatxHeader extends Struct {
  @Uint32()
  external int mask;
  @Uint32()
  external int blockSize;
  @Uint64()
  external int attributes;
  @Uint32()
  external int links;
  @Uint32()
  external int uid;
  @Uint32()
  external int gid;
  @Uint16()
  external int mode;
  @Uint16()
  external int spare;
  @Uint64()
  external int inode;
  @Uint64()
  external int size;
}

final _libc = DynamicLibrary.process();
final _openPrivate = _libc
    .lookupFunction<
      Int Function(Pointer<Utf8>, Int, VarArgs<(UnsignedInt,)>),
      int Function(Pointer<Utf8>, int, int)
    >('open');
final _statx = _libc
    .lookupFunction<
      Int Function(Int, Pointer<Utf8>, Int, UnsignedInt, Pointer<Uint8>),
      int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
    >('statx');
final _geteuid = _libc.lookupFunction<UnsignedInt Function(), int Function()>(
  'geteuid',
);
final _readPrivate = _libc
    .lookupFunction<
      IntPtr Function(Int, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _closePrivate = _libc
    .lookupFunction<Int Function(Int), int Function(int)>('close');

Uint8List _readPrivateBootstrapFile(
  String path,
  String kind,
  int cap,
  int? effectiveUid,
) {
  if (!Platform.isLinux || path.contains('\u0000')) {
    _bad(kind, r'$', 'regular_file');
  }
  // Reject final symlinks and avoid blocking if the path names a FIFO.
  const closeOnExec = 0x80000;
  const nonblocking = 0x800;
  final noFollow = switch (Abi.current()) {
    Abi.linuxArm || Abi.linuxArm64 => 0x8000,
    _ => 0x20000,
  };
  final fd = using(
    (arena) => _openPrivate(
      path.toNativeUtf8(allocator: arena),
      closeOnExec | nonblocking | noFollow,
      0,
    ),
  );
  if (fd < 0) _bad(kind, r'$', 'regular_file');
  try {
    return using((arena) {
      const emptyPath = 0x1000;
      const requiredFields =
          0x20b; // STATX_TYPE | STATX_MODE | STATX_UID | STATX_SIZE.
      final info = arena<Uint8>(256);
      final result = _statx(
        fd,
        ''.toNativeUtf8(allocator: arena),
        emptyPath,
        requiredFields,
        info,
      );
      final stat = info.cast<_StatxHeader>().ref;
      if (result != 0 ||
          (stat.mask & requiredFields) != requiredFields ||
          (stat.mode & 0xf000) != 0x8000) {
        _bad(kind, r'$', 'regular_file');
      }
      if ((stat.mode & 0xe7f) != 0) _bad(kind, r'$', 'permissions');
      if (stat.uid != (effectiveUid ?? _geteuid())) _bad(kind, r'$', 'owner');
      final size = stat.size;
      if (size > cap) _bad(kind, r'$', 'bound');
      // Read an extra byte to detect growth. A private startup file must stay
      // the same size while it is read; rotate it by replacing the path.
      final buffer = arena<Uint8>(size + 1);
      final bytes = buffer.asTypedList(size + 1);
      try {
        var offset = 0;
        while (offset <= size) {
          final count = _readPrivate(fd, buffer + offset, size + 1 - offset);
          if (count < 0) _bad(kind, r'$', 'read_or_parse');
          if (count == 0) break;
          offset += count;
        }
        if (offset > cap) _bad(kind, r'$', 'bound');
        if (offset != size) _bad(kind, r'$', 'read_or_parse');
        return bytes.sublist(0, size);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    });
  } finally {
    _closePrivate(fd);
  }
}
