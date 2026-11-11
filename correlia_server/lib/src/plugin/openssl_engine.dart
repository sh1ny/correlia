import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'plugin_tls.dart';

const _chunk = 16384;
const _bioSize = 32768;
typedef _P = Pointer<Void>;
typedef _Password = Int Function(Pointer<Uint8>, Int, Int, _P);

// These are the public OpenSSL 3 ABI, not Dart VM TLS internals.
final class _OpenSsl {
  final ssl = DynamicLibrary.open('libssl.so.3');
  final crypto = DynamicLibrary.open('libcrypto.so.3');

  late final clientMethod = ssl.lookupFunction<_P Function(), _P Function()>(
    'TLS_client_method',
  );
  late final ctxNew = ssl.lookupFunction<_P Function(_P), _P Function(_P)>(
    'SSL_CTX_new',
  );
  late final ctxFree = ssl.lookupFunction<Void Function(_P), void Function(_P)>(
    'SSL_CTX_free',
  );
  late final ctxCtrl = ssl
      .lookupFunction<
        Long Function(_P, Int, Long, _P),
        int Function(_P, int, int, _P)
      >('SSL_CTX_ctrl');
  late final ctxVerify = ssl
      .lookupFunction<Void Function(_P, Int, _P), void Function(_P, int, _P)>(
        'SSL_CTX_set_verify',
      );
  late final ctxSetStore = ssl
      .lookupFunction<Void Function(_P, _P), void Function(_P, _P)>(
        'SSL_CTX_set_cert_store',
      );
  late final storeNew = crypto.lookupFunction<_P Function(), _P Function()>(
    'X509_STORE_new',
  );
  late final storeFree = crypto
      .lookupFunction<Void Function(_P), void Function(_P)>('X509_STORE_free');
  late final storeAdd = crypto
      .lookupFunction<Int Function(_P, _P), int Function(_P, _P)>(
        'X509_STORE_add_cert',
      );
  late final storeFlags = crypto
      .lookupFunction<Int Function(_P, UnsignedLong), int Function(_P, int)>(
        'X509_STORE_set_flags',
      );
  late final sslNew = ssl.lookupFunction<_P Function(_P), _P Function(_P)>(
    'SSL_new',
  );
  late final sslFree = ssl.lookupFunction<Void Function(_P), void Function(_P)>(
    'SSL_free',
  );
  late final certsClear = ssl
      .lookupFunction<Void Function(_P), void Function(_P)>('SSL_certs_clear');
  late final useCertificate = ssl
      .lookupFunction<Int Function(_P, _P), int Function(_P, _P)>(
        'SSL_use_certificate',
      );
  late final useKey = ssl
      .lookupFunction<Int Function(_P, _P), int Function(_P, _P)>(
        'SSL_use_PrivateKey',
      );
  late final checkKey = ssl.lookupFunction<Int Function(_P), int Function(_P)>(
    'SSL_check_private_key',
  );
  late final localCertificate = ssl
      .lookupFunction<_P Function(_P), _P Function(_P)>('SSL_get_certificate');
  late final setBio = ssl
      .lookupFunction<Void Function(_P, _P, _P), void Function(_P, _P, _P)>(
        'SSL_set_bio',
      );
  late final setConnect = ssl
      .lookupFunction<Void Function(_P), void Function(_P)>(
        'SSL_set_connect_state',
      );
  late final setHost = ssl
      .lookupFunction<
        Int Function(_P, Pointer<Utf8>),
        int Function(_P, Pointer<Utf8>)
      >('SSL_set1_host');
  late final setAlpn = ssl
      .lookupFunction<
        Int Function(_P, Pointer<Uint8>, Uint32),
        int Function(_P, Pointer<Uint8>, int)
      >('SSL_set_alpn_protos');
  late final getAlpn = ssl
      .lookupFunction<
        Void Function(_P, Pointer<Pointer<Uint8>>, Pointer<Uint32>),
        void Function(_P, Pointer<Pointer<Uint8>>, Pointer<Uint32>)
      >('SSL_get0_alpn_selected');
  late final doHandshake = ssl
      .lookupFunction<Int Function(_P), int Function(_P)>('SSL_do_handshake');
  late final getError = ssl
      .lookupFunction<Int Function(_P, Int), int Function(_P, int)>(
        'SSL_get_error',
      );
  late final verifyResult = ssl
      .lookupFunction<Long Function(_P), int Function(_P)>(
        'SSL_get_verify_result',
      );
  late final peerCertificate = ssl
      .lookupFunction<_P Function(_P), _P Function(_P)>(
        'SSL_get1_peer_certificate',
      );
  late final getVersion = ssl
      .lookupFunction<Pointer<Utf8> Function(_P), Pointer<Utf8> Function(_P)>(
        'SSL_get_version',
      );
  late final version = crypto
      .lookupFunction<Pointer<Utf8> Function(Int), Pointer<Utf8> Function(int)>(
        'OpenSSL_version',
      );
  late final info = crypto
      .lookupFunction<Pointer<Utf8> Function(Int), Pointer<Utf8> Function(int)>(
        'OPENSSL_info',
      );
  late final majorVersion = crypto
      .lookupFunction<Uint32 Function(), int Function()>(
        'OPENSSL_version_major',
      );
  late final read = ssl
      .lookupFunction<
        Int Function(_P, _P, Size, Pointer<Size>),
        int Function(_P, _P, int, Pointer<Size>)
      >('SSL_read_ex');
  late final write = ssl
      .lookupFunction<
        Int Function(_P, _P, Size, Pointer<Size>),
        int Function(_P, _P, int, Pointer<Size>)
      >('SSL_write_ex');
  late final bioPair = crypto
      .lookupFunction<
        Int Function(Pointer<_P>, Size, Pointer<_P>, Size),
        int Function(Pointer<_P>, int, Pointer<_P>, int)
      >('BIO_new_bio_pair');
  late final bioFree = crypto
      .lookupFunction<Int Function(_P), int Function(_P)>('BIO_free');
  late final bioMem = crypto
      .lookupFunction<_P Function(_P, Int), _P Function(_P, int)>(
        'BIO_new_mem_buf',
      );
  late final bioRead = crypto
      .lookupFunction<Int Function(_P, _P, Int), int Function(_P, _P, int)>(
        'BIO_read',
      );
  late final bioWrite = crypto
      .lookupFunction<Int Function(_P, _P, Int), int Function(_P, _P, int)>(
        'BIO_write',
      );
  late final bioPending = crypto
      .lookupFunction<Size Function(_P), int Function(_P)>('BIO_ctrl_pending');
  late final bioGuarantee = crypto
      .lookupFunction<Size Function(_P), int Function(_P)>(
        'BIO_ctrl_get_write_guarantee',
      );
  late final decodeCert = crypto
      .lookupFunction<
        _P Function(_P, Pointer<_P>),
        _P Function(_P, Pointer<_P>)
      >('d2i_X509_bio');
  late final encodeCert = crypto
      .lookupFunction<
        Int Function(_P, Pointer<Pointer<Uint8>>),
        int Function(_P, Pointer<Pointer<Uint8>>)
      >('i2d_X509');
  late final pemCert = crypto
      .lookupFunction<
        _P Function(_P, Pointer<_P>, _P, _P),
        _P Function(_P, Pointer<_P>, _P, _P)
      >('PEM_read_bio_X509');
  late final pemKey = crypto
      .lookupFunction<
        _P Function(_P, Pointer<_P>, Pointer<NativeFunction<_Password>>, _P),
        _P Function(_P, Pointer<_P>, Pointer<NativeFunction<_Password>>, _P)
      >('PEM_read_bio_PrivateKey');
  late final certFree = crypto
      .lookupFunction<Void Function(_P), void Function(_P)>('X509_free');
  late final certPublicKey = crypto
      .lookupFunction<_P Function(_P), _P Function(_P)>('X509_get_pubkey');
  late final keyGroup = crypto
      .lookupFunction<
        Int Function(_P, Pointer<Uint8>, Size, Pointer<Size>),
        int Function(_P, Pointer<Uint8>, int, Pointer<Size>)
      >('EVP_PKEY_get_group_name');
  late final keyFree = crypto
      .lookupFunction<Void Function(_P), void Function(_P)>('EVP_PKEY_free');
  late final clearError = crypto
      .lookupFunction<Void Function(), void Function()>('ERR_clear_error');
  late final error = crypto
      .lookupFunction<UnsignedLong Function(), int Function()>('ERR_get_error');
  late final errorString = crypto
      .lookupFunction<
        Void Function(UnsignedLong, Pointer<Utf8>, Size),
        void Function(int, Pointer<Utf8>, int)
      >('ERR_error_string_n');

  void resolve() {
    // Reading each lazy field resolves the complete ABI before socket acquisition.
    [
      clientMethod,
      ctxNew,
      ctxFree,
      ctxCtrl,
      ctxVerify,
      ctxSetStore,
      storeNew,
      storeFree,
      storeAdd,
      storeFlags,
      sslNew,
      sslFree,
      certsClear,
      useCertificate,
      useKey,
      checkKey,
      localCertificate,
      setBio,
      setConnect,
      setHost,
      setAlpn,
      getAlpn,
      doHandshake,
      getError,
      verifyResult,
      peerCertificate,
      getVersion,
      version,
      info,
      majorVersion,
      read,
      write,
      bioPair,
      bioFree,
      bioMem,
      bioRead,
      bioWrite,
      bioPending,
      bioGuarantee,
      decodeCert,
      encodeCert,
      pemCert,
      pemKey,
      certFree,
      certPublicKey,
      keyGroup,
      keyFree,
      clearError,
      error,
      errorString,
    ];
  }
}

_OpenSsl? _backend;
int _noPassword(Pointer<Uint8> buffer, int size, int writing, _P data) => 0;
final _passwordCallback = Pointer.fromFunction<_Password>(_noPassword, 0);

/// A nonblocking, pin-verified OpenSSL client with bounded memory BIOs.
final class NativeTlsEngine {
  /// Creates an engine trusting only [peerCertificateDer].
  factory NativeTlsEngine({
    required List<int> peerCertificateDer,
    List<int>? certificatePem,
    List<int>? privateKeyPem,
    PluginTlsTestControls testControls = const PluginTlsTestControls(),
  }) {
    verifyBackend(testControls);
    final engine = NativeTlsEngine._(peerCertificateDer, testControls);
    try {
      engine._initialize(certificatePem, privateKeyPem, testControls);
      return engine;
    } catch (_) {
      engine.dispose();
      rethrow;
    }
  }

  NativeTlsEngine._(List<int> pin, PluginTlsTestControls controls)
    : _pin = _checkedCopy(pin, 'peer certificate'),
      _allocator = controls.allocator ?? calloc,
      _api = _backend!;

  /// Resolves the genuine system ABI before acquiring connection resources.
  static void verifyBackend(PluginTlsTestControls controls) {
    if (!Platform.isLinux) throw UnsupportedError('OpenSSL TLS requires Linux');
    if (controls.nativeFault == PluginNativeTlsFault.unavailableLibrary) {
      DynamicLibrary.open('/dev/null/correlia-openssl-unavailable.so');
      throw StateError('Unavailable library unexpectedly loaded');
    }
    if (controls.nativeFault == PluginNativeTlsFault.missingAbiSymbol) {
      DynamicLibrary.open(
        'libssl.so.3',
      ).lookup<Void>('correlia_openssl_missing_abi_symbol');
      throw StateError('Missing ABI symbol unexpectedly found');
    }
    if (_backend != null) return;
    final backend = _OpenSsl();
    backend.resolve();
    if (backend.majorVersion() != 3) {
      throw UnsupportedError('OpenSSL 3 is required');
    }
    _backend = backend;
  }

  final Uint8List _pin;
  final Allocator _allocator;
  final _OpenSsl _api;
  _P _ctx = nullptr;
  _P _ssl = nullptr;
  _P _external = nullptr;
  Pointer<Uint8> _input = nullptr;
  Pointer<Uint8> _output = nullptr;
  Pointer<Uint8> _writeBuffer = nullptr;
  Pointer<Size> _count = nullptr;
  bool _disposed = false;
  bool _handshaken = false;
  bool _peerClosed = false;
  int? _pendingOffset;
  int _pendingLength = 0;
  PluginTlsEvidence? _evidence;

  static Uint8List _checkedCopy(List<int> value, String name) {
    if (value.isEmpty ||
        value.length > _chunk ||
        value.any((v) => v < 0 || v > 255)) {
      throw HandshakeException('Invalid $name length or bytes');
    }
    return Uint8List.fromList(value);
  }

  void _initialize(
    List<int>? cert,
    List<int>? key,
    PluginTlsTestControls controls,
  ) {
    if ((cert == null) != (key == null)) {
      throw HandshakeException('Both client certificate and key are required');
    }
    _api.clearError();
    _ctx = _api.ctxNew(_api.clientMethod());
    _require(_ctx != nullptr, 'Creating TLS context');
    // Respect a configured upper bound rather than silently lifting host policy.
    final maximum = _api.ctxCtrl(_ctx, 131, 0, nullptr);
    _require(
      maximum == 0 || maximum >= 0x0304,
      'Checking configured maximum TLS version',
    );
    _require(
      _api.ctxCtrl(_ctx, 123, 0x0304, nullptr) == 1,
      'Setting minimum TLS version',
    );
    _api.ctxCtrl(_ctx, 51, _chunk, nullptr);
    _api.ctxVerify(_ctx, 1, nullptr);
    final trusted = _parse(_pin, false, false);
    _P store = nullptr;
    try {
      store = _api.storeNew();
      _require(store != nullptr, 'Creating pinned trust store');
      _require(
        _api.storeAdd(store, trusted) == 1,
        'Adding pinned trust anchor',
      );
      _require(
        _api.storeFlags(store, 0x84000) == 1,
        'Setting trust verification flags',
      );
      // set1 replaces any independently configured verification store; the
      // ordinary store setter takes ownership of our original reference.
      _require(
        _api.ctxCtrl(_ctx, 106, 1, store) == 1,
        'Replacing verification store',
      );
      _api.ctxSetStore(_ctx, store);
      store = nullptr;
    } finally {
      if (store != nullptr) _api.storeFree(store);
      _api.certFree(trusted);
    }
    if (controls.withoutP521Signatures) {
      final sigalgs = 'ECDSA+SHA256'.toNativeUtf8(allocator: _allocator);
      try {
        _require(
          _api.ctxCtrl(_ctx, 98, 0, sigalgs.cast()) == 1,
          'Restricting signature algorithms',
        );
      } finally {
        _allocator.free(sigalgs);
      }
    }
    _ssl = _api.sslNew(_ctx);
    _require(_ssl != nullptr, 'Creating TLS connection');
    // Clear every inherited certificate, key and chain on this session before
    // installing the caller's identity, including the no-identity case.
    _api.certsClear(_ssl);
    if (cert != null && key != null) {
      final clientCert = _parse(
        _checkedCopy(cert, 'client certificate'),
        true,
        false,
      );
      try {
        _require(
          _api.useCertificate(_ssl, clientCert) == 1,
          'Installing client certificate',
        );
      } finally {
        _api.certFree(clientCert);
      }
      final clientKey = _parse(_checkedCopy(key, 'client key'), true, true);
      try {
        _require(
          _api.useKey(_ssl, clientKey) == 1 && _api.checkKey(_ssl) == 1,
          'Installing client key',
        );
      } finally {
        _api.keyFree(clientKey);
      }
    }
    final host = 'localhost'.toNativeUtf8(allocator: _allocator);
    Pointer<Uint8> alpn = nullptr;
    try {
      alpn = _allocator<Uint8>(3);
      alpn.asTypedList(3).setAll(0, [2, 104, 50]);
      _require(_api.setHost(_ssl, host) == 1, 'Setting hostname');
      _require(_api.setAlpn(_ssl, alpn, 3) == 0, 'Setting ALPN');
    } finally {
      _allocator.free(host);
      if (alpn != nullptr) _allocator.free(alpn);
    }
    Pointer<_P> internal = nullptr;
    Pointer<_P> external = nullptr;
    try {
      internal = _allocator<_P>();
      external = _allocator<_P>();
      internal.value = nullptr;
      external.value = nullptr;
      _require(
        _api.bioPair(internal, _bioSize, external, _bioSize) == 1,
        'Creating BIO pair',
      );
      _external = external.value;
      // SSL_set_bio takes ownership of the shared internal BIO reference.
      _api.setBio(_ssl, internal.value, internal.value);
      _api.setConnect(_ssl);
    } finally {
      if (internal != nullptr) _allocator.free(internal);
      if (external != nullptr) _allocator.free(external);
    }
    _input = _allocator<Uint8>(_chunk);
    _output = _allocator<Uint8>(_chunk);
    _writeBuffer = _allocator<Uint8>(_chunk);
    _count = _allocator<Size>();
  }

  _P _parse(Uint8List bytes, bool pem, bool key) {
    final data = _allocator<Uint8>(bytes.length);
    _P bio = nullptr;
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      _api.clearError();
      bio = _api.bioMem(data.cast(), bytes.length);
      _require(bio != nullptr, 'Creating credential buffer');
      final result = key
          ? _api.pemKey(bio, nullptr, _passwordCallback, nullptr)
          : pem
          ? _api.pemCert(bio, nullptr, nullptr, nullptr)
          : _api.decodeCert(bio, nullptr);
      _require(result != nullptr, 'Parsing credential');
      if (!pem && _api.bioPending(bio) != 0) {
        _api.certFree(result);
        throw HandshakeException('Trailing data in pinned certificate');
      }
      return result;
    } finally {
      if (bio != nullptr) _api.bioFree(bio);
      data.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      _allocator.free(data);
    }
  }

  void _require(bool condition, String operation) {
    if (!condition) throw HandshakeException('$operation: ${_errorText()}');
    _api.clearError();
  }

  String _errorText() {
    final code = _api.error();
    if (code == 0) return 'OpenSSL reported no further detail';
    // The OpenSSL reason string contains no credential bytes.
    final buffer = _allocator<Uint8>(256);
    try {
      _api.errorString(code, buffer.cast(), 256);
      return buffer.cast<Utf8>().toDartString();
    } finally {
      _allocator.free(buffer);
    }
  }

  void _checkOpen() {
    if (_disposed) throw StateError('TLS engine is disposed');
  }

  void _checkReady() {
    _checkOpen();
    if (!_handshaken) {
      throw StateError('TLS handshake has not been authenticated');
    }
  }

  Never _fail(String operation, int error) {
    final detail = _errorText();
    dispose();
    throw HandshakeException('$operation failed (SSL error $error): $detail');
  }

  /// The remaining capacity for inbound ciphertext.
  int get receiveCapacity {
    _checkOpen();
    return _api.bioGuarantee(_external);
  }

  /// Supplies ciphertext without blocking.
  void receive(List<int> encrypted) {
    _checkOpen();
    if (encrypted.length > _chunk ||
        encrypted.length > receiveCapacity ||
        encrypted.any((v) => v < 0 || v > 255)) {
      throw ArgumentError(
        'Ciphertext exceeds available capacity or contains invalid bytes',
      );
    }
    if (encrypted.isEmpty) return;
    _input.asTypedList(encrypted.length).setAll(0, encrypted);
    _api.clearError();
    if (_api.bioWrite(_external, _input.cast(), encrypted.length) !=
        encrypted.length) {
      _fail('Writing ciphertext to BIO', 0);
    }
  }

  /// Drains pending ciphertext into [destination].
  int takeCipher(Uint8List destination) {
    _checkOpen();
    final pending = _api.bioPending(_external);
    var count = destination.length < pending ? destination.length : pending;
    if (count > _chunk) count = _chunk;
    if (count == 0) return 0;
    _api.clearError();
    final read = _api.bioRead(_external, _output.cast(), count);
    if (read <= 0) _fail('Reading ciphertext from BIO', 0);
    destination.setRange(0, read, _output.asTypedList(read));
    return read;
  }

  String? _curve(_P certificate) {
    if (certificate == nullptr) return null;
    _api.clearError();
    final key = _api.certPublicKey(certificate);
    _require(key != nullptr, 'Obtaining certificate public key');
    try {
      // The fixed native output buffer is ample for an OpenSSL group name.
      final result = _api.keyGroup(key, _output, 256, _count);
      if (result != 1) {
        _api.clearError();
        return null;
      }
      final name = _output.cast<Utf8>().toDartString();
      return name == 'secp521r1' ? 'P-521' : name;
    } finally {
      _api.keyFree(key);
    }
  }

  /// Advances the handshake and authenticates the peer before success.
  bool handshake() {
    _checkOpen();
    if (_handshaken) return true;
    _api.clearError();
    final result = _api.doHandshake(_ssl);
    if (result != 1) {
      final error = _api.getError(_ssl, result);
      if (error == 2 || error == 3) return false;
      _fail('TLS handshake', error);
    }
    try {
      _require(_api.verifyResult(_ssl) == 0, 'Verifying peer certificate');
      final peer = _api.peerCertificate(_ssl);
      _require(peer != nullptr, 'Obtaining peer certificate');
      String? serverCurve;
      try {
        final length = _api.encodeCert(peer, nullptr);
        _require(
          length == _pin.length && length <= _chunk,
          'Checking peer certificate pin',
        );
        final cursor = _allocator<Pointer<Uint8>>();
        try {
          cursor.value = _output;
          _require(
            _api.encodeCert(peer, cursor) == length,
            'Encoding peer certificate',
          );
          final encoded = _output.asTypedList(length);
          var difference = 0;
          for (var i = 0; i < length; i++) {
            difference |= encoded[i] ^ _pin[i];
          }
          _require(difference == 0, 'Checking peer certificate pin');
        } finally {
          _allocator.free(cursor);
        }
        serverCurve = _curve(peer);
      } finally {
        _api.certFree(peer);
      }
      Pointer<Pointer<Uint8>> selected = nullptr;
      Pointer<Uint32> length = nullptr;
      try {
        selected = _allocator<Pointer<Uint8>>();
        length = _allocator<Uint32>();
        _api.getAlpn(_ssl, selected, length);
        _require(
          length.value == 2 &&
              selected.value != nullptr &&
              selected.value[0] == 104 &&
              selected.value[1] == 50,
          'Checking ALPN h2',
        );
      } finally {
        if (selected != nullptr) _allocator.free(selected);
        if (length != nullptr) _allocator.free(length);
      }
      final protocol = _api.getVersion(_ssl).toDartString();
      _require(protocol == 'TLSv1.3', 'Checking negotiated TLS version');
      final environment = <String, String?>{
        for (final name in [
          'OPENSSL_CONF',
          'OPENSSL_CONF_INCLUDE',
          'OPENSSL_MODULES',
        ])
          name: Platform.environment[name],
      };
      final directory = _api.info(1001);
      _require(
        directory != nullptr,
        'Obtaining OpenSSL configuration directory',
      );
      final configDirectory = directory.toDartString();
      _evidence = PluginTlsEvidence(
        backendVersion: _api.version(0).toDartString(),
        protocol: protocol,
        serverCertificateCurve: serverCurve,
        clientCertificateCurve: _curve(_api.localCertificate(_ssl)),
        configurationPolicy: 'system/OPENSSL_CONF',
        configurationSource:
            'OPENSSL_CONF=${environment['OPENSSL_CONF'] ?? '(default)'}; compiled default directory=$configDirectory',
        configurationEnvironment: environment,
      );
      _handshaken = true;
      return true;
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  /// Writes plaintext while preserving the native buffer across WANT retries.
  int writePlain(List<int> bytes, int offset, int length) {
    _checkReady();
    RangeError.checkValidRange(offset, offset + length, bytes.length);
    if (length < 0 || length > _chunk) {
      throw RangeError.range(length, 0, _chunk, 'length');
    }
    if (_pendingOffset != null) {
      if (offset != _pendingOffset || length != _pendingLength) {
        throw StateError('Inconsistent TLS write retry');
      }
      for (var i = 0; i < length; i++) {
        if (bytes[offset + i] != _writeBuffer[i]) {
          throw StateError('Changed TLS write retry');
        }
      }
    } else {
      if (length == 0) return 0;
      for (var i = 0; i < length; i++) {
        final byte = bytes[offset + i];
        if (byte < 0 || byte > 255) {
          throw ArgumentError('Invalid plaintext byte');
        }
        _writeBuffer[i] = byte;
      }
      _pendingOffset = offset;
      _pendingLength = length;
    }
    _api.clearError();
    final result = _api.write(_ssl, _writeBuffer.cast(), length, _count);
    if (result != 1) {
      final error = _api.getError(_ssl, result);
      if (error == 2 || error == 3) return 0;
      _fail('TLS write', error);
    }
    final accepted = _count.value;
    _pendingOffset = null;
    _pendingLength = 0;
    return accepted;
  }

  /// Reads a detached plaintext chunk, or `null` on WANT or clean closure.
  Uint8List? readPlain() {
    _checkReady();
    if (_peerClosed) return null;
    _api.clearError();
    final result = _api.read(_ssl, _input.cast(), _chunk, _count);
    if (result != 1) {
      final error = _api.getError(_ssl, result);
      if (error == 2 || error == 3) return null;
      if (error == 6) {
        _peerClosed = true;
        return null;
      }
      _fail('TLS read', error);
    }
    return Uint8List.fromList(_input.asTypedList(_count.value));
  }

  /// Whether the peer sent a clean TLS shutdown.
  bool get peerClosed {
    _checkOpen();
    return _peerClosed;
  }

  /// The negotiated protocol version.
  String get tlsVersion {
    _checkReady();
    return _evidence!.protocol;
  }

  /// The system OpenSSL library version.
  String get libraryVersion {
    _checkOpen();
    return _api.version(0).toDartString();
  }

  /// The detached observations from the verified handshake.
  PluginTlsEvidence get evidence {
    _checkReady();
    return _evidence!;
  }

  /// Releases owned native resources; repeated calls have no effect.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ssl != nullptr) _api.sslFree(_ssl);
    if (_external != nullptr) _api.bioFree(_external);
    if (_ctx != nullptr) _api.ctxFree(_ctx);
    if (_input != nullptr) {
      _input.asTypedList(_chunk).fillRange(0, _chunk, 0);
      _allocator.free(_input);
    }
    if (_output != nullptr) _allocator.free(_output);
    if (_writeBuffer != nullptr) {
      _writeBuffer.asTypedList(_chunk).fillRange(0, _chunk, 0);
      _allocator.free(_writeBuffer);
    }
    if (_count != nullptr) _allocator.free(_count);
    // Failed PEM decoding can leave additional thread-local error data behind.
    // No later connection may inherit this operation's diagnostic allocations.
    _api.clearError();
  }
}
