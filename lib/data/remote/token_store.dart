import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the auth tokens between launches.
///
/// Uses `flutter_secure_storage` rather than `shared_preferences` because these
/// are bearer credentials for a pharmacy account. `shared_preferences` is an
/// unencrypted XML file: it is included in unencrypted device backups and is
/// trivially readable on a rooted device, which would hand over a live session
/// token rather than a display preference.
///
/// The access token is the only credential kept here. The refresh token is
/// owned by the cookie jar, because the backend issues it as an httpOnly cookie
/// and never in the response body -- see `AuthApiClient`.
class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'pharmazen.access_token';

  final FlutterSecureStorage _storage;

  Future<String?> readAccessToken() async {
    try {
      return await _storage.read(key: _accessTokenKey);
    } on Exception {
      // A corrupt keystore entry must not brick the app on launch; the user
      // signs in again instead.
      return null;
    }
  }

  Future<void> writeAccessToken(String token) async {
    try {
      await _storage.write(key: _accessTokenKey, value: token);
    } on Exception {
      // Losing persistence degrades to "signed out after restart", which is
      // recoverable. Failing the request here would block a valid login.
    }
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _accessTokenKey);
    } on Exception {
      /* nothing useful to do */
    }
  }
}