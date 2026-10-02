import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../core/config/api_config.dart';
import 'token_store.dart';

/// The single authenticated Dio for the app.
///
/// Owns the two credentials that make a request succeed:
///
/// * the **access token** (15 min) is attached as a `Bearer` header and kept in
///   `flutter_secure_storage`, because Dart has no browser to hold it;
/// * the **refresh token** (7 days, rotated) is set by the backend as an httpOnly
///   cookie and never appears in a response body. Dio has no built-in cookie
///   persistence, so a `PersistCookieJar` backs the interceptor — without it
///   every app restart silently loses the ability to refresh and the user is
///   bounced to the login screen.
///
/// Endpoints under [_unauthenticatedPaths] are sent without a `Bearer` header,
/// because they are the ones that mint or destroy the token.
class ApiClient {
  ApiClient({Dio? dio, TokenStore? tokenStore, CookieJar? cookieJar})
    : _tokens = tokenStore ?? TokenStore(),
      _cookies = cookieJar ?? PersistCookieJar() {
    _dio = dio ?? Dio(_options());
    _dio.interceptors
      ..add(CookieManager(_cookies))
      ..add(InterceptorsWrapper(onRequest: _onRequest, onError: _onError));

    // Refresh runs on a separate Dio with no auth interceptor, so a 401 from the
    // refresh call itself cannot recurse back into another refresh.
    _refreshDio = Dio(_options());
    _refreshDio.interceptors.add(CookieManager(_cookies));
  }

  final TokenStore _tokens;
  final CookieJar _cookies;
  late final Dio _dio;
  late final Dio _refreshDio;

  Dio get dio => _dio;

  /// De-duplicates concurrent refreshes: several in-flight requests can hit a
  /// 401 at once, and rotating the refresh token means a second parallel refresh
  /// would try to redeem an already-redeemed token and log the user out.
  Future<String?>? _refreshing;

  static const _unauthenticatedPaths = {
    '/auth/login',
    '/auth/refresh',
    '/auth/logout',
  };

  static BaseOptions _options() => BaseOptions(
    baseUrl: ApiConfig.apiBaseUrl,
    connectTimeout: ApiConfig.requestTimeout,
    receiveTimeout: ApiConfig.requestTimeout,
    // Let non-2xx statuses reach the error path instead of throwing inside Dio,
    // so callers can read the server's own message.
    validateStatus: (code) => code != null && code >= 200 && code < 300,
  );

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_unauthenticatedPaths.contains(options.path)) {
      final token = await _tokens.readAccessToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  Future<void> _onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    final refreshable =
        err.response?.statusCode == 401 &&
        !_unauthenticatedPaths.contains(request.path) &&
        request.extra['authRetried'] != true;

    if (!refreshable) return handler.next(err);

    request.extra['authRetried'] = true;
    final token = await _refresh();
    if (token == null) {
      // The refresh token is gone or expired. Drop the stale access token so the
      // UI cannot keep retrying with a credential the server rejects.
      await _tokens.clear();
      return handler.next(err);
    }

    try {
      request.headers['Authorization'] = 'Bearer $token';
      handler.resolve(await _dio.fetch<dynamic>(request));
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  /// Exchanges the refresh cookie for a new access token, at most one call in
  /// flight. Returns null when the session can no longer be renewed.
  Future<String?> _refresh() {
    return _refreshing ??= _performRefresh().whenComplete(() {
      _refreshing = null;
    });
  }

  Future<String?> _performRefresh() async {
    try {
      final response = await _refreshDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: const <String, dynamic>{},
      );
      final data = response.data?['data'] as Map<String, dynamic>?;
      final token = data?['accessToken'] as String?;
      if (token == null || token.isEmpty) return null;
      await _tokens.writeAccessToken(token);
      return token;
    } on DioException {
      return null;
    }
  }

  /// Hands a freshly issued access token to the store.
  ///
  /// [AuthApiClient.login] must call this. The token in the login body is the
  /// only credential the app holds at that moment — the refresh token is a
  /// cookie — so dropping it means [TokenStore] stays empty, [ApiClient] attaches
  /// no `Authorization` header, and every call goes out unauthenticated until an
  /// incidental 401 happens to trigger a refresh.
  Future<void> adoptAccessToken(String token) async {
    await _tokens.writeAccessToken(token);
  }

  Future<void> clearSession() async {
    await _tokens.clear();
    await _cookies.deleteAll();
  }

  static String? messageOf(dynamic body) {
    if (body is! Map) return null;
    final value = body['error'] ?? body['message'];
    return value is String ? value : null;
  }
}