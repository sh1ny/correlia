import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ingest/bootstrap.dart';

const _keySize = 32;
const _nonceSize = 12;
const _tagSize = 16;
const _setTag = 0x11; // EVP_CTRL_AEAD_SET_TAG
const _getTag = 0x10; // EVP_CTRL_AEAD_GET_TAG

typedef _Ptr = Pointer<Void>;
typedef _Bytes = Pointer<Uint8>;

/// An authenticated record could not be opened.
final class SecretIntegrityError implements Exception {
  /// Creates an error without exposing record material or OpenSSL diagnostics.
  const SecretIntegrityError();

  @override
  String toString() => 'secret_integrity';
}

/// Seals and opens AES-256-GCM records using OpenSSL 3.
final class SecretAead {
  /// Creates an AEAD bound to the 32-byte [key].
  SecretAead(Uint8List key) : _key = _copyKey(key), _crypto = _OpenSsl.instance;

  final Uint8List _key;
  final _OpenSsl _crypto;

  static Uint8List _copyKey(Uint8List key) {
    if (key.length != _keySize) {
      throw ArgumentError('Invalid AES-256 key length');
    }
    return Uint8List.fromList(key);
  }

  /// Seals [plaintext] with a new random nonce, authenticating [aad].
  ({Uint8List nonce, Uint8List ciphertext}) seal(
    Uint8List plaintext,
    Uint8List aad,
  ) => _run(plaintext, aad, null);

  /// Opens ciphertext with a trailing tag, or throws [SecretIntegrityError].
  Uint8List open(Uint8List nonce, Uint8List ciphertext, Uint8List aad) {
    if (nonce.length != _nonceSize || ciphertext.length < _tagSize) {
      throw const SecretIntegrityError();
    }
    return _run(ciphertext, aad, nonce).ciphertext;
  }

  // Both modes use the same EVP pipeline; only nonce/tag direction differs.
  ({Uint8List nonce, Uint8List ciphertext}) _run(
    Uint8List input,
    Uint8List aad,
    Uint8List? suppliedNonce,
  ) {
    final encrypt = suppliedNonce == null;
    final length = encrypt ? input.length : input.length - _tagSize;
    final allocationSize =
        sizeOf<Int>() +
        _keySize +
        _nonceSize +
        aad.length +
        length * 2 +
        _tagSize +
        16;
    final buffer = calloc<Uint8>(allocationSize);
    var context = nullptr.cast<Void>();
    try {
      context = _crypto.contextNew();
      _require(context != nullptr, encrypt);
      final written = buffer.cast<Int>();
      final key = buffer + sizeOf<Int>();
      final nonce = key + _keySize;
      final associated = nonce + _nonceSize;
      final source = associated + aad.length;
      final output = source + length + _tagSize;
      final none = nullptr.cast<Uint8>();
      key.asTypedList(_keySize).setAll(0, _key);
      if (suppliedNonce == null) {
        _require(_crypto.random(nonce, _nonceSize) == 1, true);
      } else {
        nonce.asTypedList(_nonceSize).setAll(0, suppliedNonce);
      }
      _require(
        _crypto.initialize(
              context,
              _crypto.cipher,
              nullptr,
              key,
              nonce,
              encrypt ? 1 : 0,
            ) ==
            1,
        encrypt,
      );
      if (aad.isNotEmpty) {
        associated.asTypedList(aad.length).setAll(0, aad);
        _require(
          _crypto.update(context, none, written, associated, aad.length) == 1,
          encrypt,
        );
      }
      final sourceLength = input.length;
      if (sourceLength != 0) source.asTypedList(sourceLength).setAll(0, input);
      if (length != 0) {
        _require(
          _crypto.update(context, output, written, source, length) == 1 &&
              written.value == length,
          encrypt,
        );
      }
      if (!encrypt) {
        _require(
          _crypto.control(
                context,
                _setTag,
                _tagSize,
                (source + length).cast(),
              ) ==
              1,
          false,
        );
      }
      _require(
        _crypto.finish(context, output + length, written) == 1 &&
            written.value == 0,
        encrypt,
      );
      if (encrypt) {
        _require(
          _crypto.control(
                context,
                _getTag,
                _tagSize,
                (output + length).cast(),
              ) ==
              1,
          true,
        );
      }
      return (
        nonce:
            suppliedNonce ?? Uint8List.fromList(nonce.asTypedList(_nonceSize)),
        ciphertext: Uint8List.fromList(
          output.asTypedList(length + (encrypt ? _tagSize : 0)),
        ),
      );
    } finally {
      if (context != nullptr) _crypto.contextFree(context);
      _crypto.cleanse(buffer.cast(), allocationSize);
      calloc.free(buffer);
    }
  }
}

void _require(bool success, bool encrypt) {
  if (success) return;
  if (encrypt) throw const BootstrapError('secret_key', r'$', 'crypto_failed');
  throw const SecretIntegrityError();
}

final class _OpenSsl {
  _OpenSsl(DynamicLibrary lib)
    : contextNew = lib.lookupFunction<_Ptr Function(), _Ptr Function()>(
        'EVP_CIPHER_CTX_new',
      ),
      contextFree = lib
          .lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
            'EVP_CIPHER_CTX_free',
          ),
      cipher = lib.lookupFunction<_Ptr Function(), _Ptr Function()>(
        'EVP_aes_256_gcm',
      )(),
      initialize = lib
          .lookupFunction<
            Int Function(_Ptr, _Ptr, _Ptr, _Bytes, _Bytes, Int),
            int Function(_Ptr, _Ptr, _Ptr, _Bytes, _Bytes, int)
          >('EVP_CipherInit_ex'),
      update = lib
          .lookupFunction<
            Int Function(_Ptr, _Bytes, Pointer<Int>, _Bytes, Int),
            int Function(_Ptr, _Bytes, Pointer<Int>, _Bytes, int)
          >('EVP_CipherUpdate'),
      finish = lib
          .lookupFunction<
            Int Function(_Ptr, _Bytes, Pointer<Int>),
            int Function(_Ptr, _Bytes, Pointer<Int>)
          >('EVP_CipherFinal_ex'),
      control = lib
          .lookupFunction<
            Int Function(_Ptr, Int, Int, _Ptr),
            int Function(_Ptr, int, int, _Ptr)
          >('EVP_CIPHER_CTX_ctrl'),
      random = lib
          .lookupFunction<Int Function(_Bytes, Int), int Function(_Bytes, int)>(
            'RAND_bytes',
          ),
      cleanse = lib
          .lookupFunction<Void Function(_Ptr, Size), void Function(_Ptr, int)>(
            'OPENSSL_cleanse',
          );

  static final instance = _load();

  static _OpenSsl _load() {
    try {
      return _OpenSsl(DynamicLibrary.open('libcrypto.so.3'));
    } on ArgumentError {
      throw const BootstrapError('secret_key', r'$', 'crypto_unavailable');
    }
  }

  final _Ptr Function() contextNew;
  final void Function(_Ptr) contextFree;
  final _Ptr cipher;
  final int Function(_Ptr, _Ptr, _Ptr, _Bytes, _Bytes, int) initialize;
  final int Function(_Ptr, _Bytes, Pointer<Int>, _Bytes, int) update;
  final int Function(_Ptr, _Bytes, Pointer<Int>) finish;
  final int Function(_Ptr, int, int, _Ptr) control;
  final int Function(_Bytes, int) random;
  final void Function(_Ptr, int) cleanse;
}
