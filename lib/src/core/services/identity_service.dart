import 'package:hollow/src/rust/api/identity.dart' as ffi;

/// Thin wrapper around the FFI identity layer for testability.
class IdentityService {
  Future<ffi.IdentityInfo> loadOrCreateIdentity() =>
      ffi.loadOrCreateIdentity();

  Future<ffi.IdentityInfo> generateNewIdentity() =>
      ffi.generateNewIdentity();
}
