import 'dart:async';
import 'dart:io' show HttpDate;
import 'dart:math';

import 'package:dio/dio.dart';

import '../../core/config/api_config.dart';
import 'sync_manifest.dart';

/// Result of `GET /api/sync/manifest`, including the validator so a repeat call
/// can be served from cache.
class SyncManifestResult {
  const SyncManifestResult({
    required this.entries,
    this.etag,
    this.notModified = false,
  });

  final List<SyncManifestEntry> entries;
  final String? etag;

  /// True when the server answered 304 and [entries] came from the cache.
  final bool notModified;
}

/// Reads the public sync endpoints. No auth: these are rate-limited and
/// ETag-protected instead.
///
/// Retries are implemented here rather than as a Dio interceptor so that the
/// backoff delay and jitter source are injectable, making the retry behaviour
/// testable without real time passing.
class SyncApiClient {
  SyncApiClient({
    Dio? dio,
    String? baseUrl,
    Future<void> Function(Duration)? sleep,
    double Function()? jitter,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _jitter = jitter ?? _defaultJitter,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl ?? ApiConfig.apiBaseUrl,
               connectTimeout: ApiConfig.requestTimeout,
               receiveTimeout: ApiConfig.requestTimeout,
               sendTimeout: ApiConfig.requestTimeout,
// Status codes are inspected explicitly in _send so that a 5xx can
                // be retried with backoff instead of being thrown at us as a
                // badResponse, which is classified as permanent.
                validateStatus: (status) => status != null && status < 600,
               headers: const {'Accept': 'application/json'},
             ),
           );

  final Dio _dio;
  final Future<void> Function(Duration) _sleep;
  final double Function() _jitter;

  List<SyncManifestEntry>? _cachedEntries;
  String? _cachedEtag;

  static double _defaultJitter() => Random().nextDouble();

  /// One page of the `?since=` delta. [since] is the cursor string handed back
  /// by the previous successful run; [cursor] continues a page sequence.
  Future<SyncDeltaPage> fetchDelta({String? since, String? cursor}) async {
    final response = await _get('/sync', query: {
      if (since != null && since.isNotEmpty) 'since': since,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    });

    _requireOk(response, '/api/sync');

    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw SyncProtocolException(
        'Expected a JSON object from /api/sync, got ${data.runtimeType}.',
      );
    }
    return SyncDeltaPage.fromJson(data);
  }

  /// `GET /api/sync/manifest`, using the stored ETag so an unchanged manifest
  /// costs a 304 with no body.
  Future<SyncManifestResult> fetchManifest() async {
    final etag = _cachedEtag;
    final response = await _get(
      '/sync/manifest',
      query: const {},
      headers: etag == null ? null : {'If-None-Match': etag},
    );

    if (response.statusCode == 304 && _cachedEntries != null) {
      return SyncManifestResult(
        entries: _cachedEntries!,
        etag: _cachedEtag,
        notModified: true,
      );
    }

    _requireOk(response, '/api/sync/manifest');

    final data = response.data;
    if (data is! List) {
      throw SyncProtocolException(
        'Expected a JSON array from /api/sync/manifest, '
        'got ${data.runtimeType}.',
      );
    }

    final entries = <SyncManifestEntry>[];
    for (final pair in data) {
      // One malformed pair must not discard an otherwise good manifest.
      if (pair is List && pair.length >= 2) {
        try {
          entries.add(SyncManifestEntry.fromJson(pair));
        } on Object {
          continue;
        }
      }
    }

    _cachedEntries = entries;
    _cachedEtag = response.headers.value('etag');
    return SyncManifestResult(entries: entries, etag: _cachedEtag);
  }

  /// Rejects anything that is not a 2xx before the body is interpreted.
  ///
  /// A 404 is the expected answer until Phase 2 ships, and it becomes
  /// [SyncProtocolException] so the engine can report "endpoint not there yet"
  /// rather than "failed". Parsing an error body as if it were a page would be
  /// far worse: it reads as a valid empty delta and the cursor would advance
  /// over data that was never fetched.
  void _requireOk(Response<dynamic> response, String path) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    throw SyncProtocolException('$path returned HTTP $status.');
  }

  Future<Response<dynamic>> _get(
    String path, {
    required Map<String, String> query,
    Map<String, String>? headers,
  }) {
    return _send(() => _dio.get<dynamic>(
      path,
      queryParameters: query.isEmpty ? null : query,
      options: headers == null ? null : Options(headers: headers),
    ));
  }

  /// Retries transport failures, 408/429 and 5xx with exponential backoff and
  /// full jitter. 4xx other than those are permanent and surface immediately.
  Future<Response<dynamic>> _send(
    Future<Response<dynamic>> Function() attempt,
  ) async {
    Object? lastError;
    int? lastStatus;

    for (var i = 0; i < ApiConfig.maxAttempts; i++) {
      final isLast = i == ApiConfig.maxAttempts - 1;
      try {
        final response = await attempt();
        final status = response.statusCode ?? 0;
        if (!_isRetryableStatus(status)) return response;

        lastStatus = status;
        // Falling out of the loop with lastStatus set is what turns an exhausted
        // 5xx into a thrown SyncNetworkException. Returning the final response
        // instead would hand the caller an error body to parse as a valid page.
        if (isLast) break;

        // Honour Retry-After when the server sends it, capped so a hostile or
        // mistaken value cannot park the sync lock for an hour.
        final retryAfter = _parseRetryAfter(response.headers.value('retry-after'));
        if (retryAfter != null) {
          await _sleep(retryAfter);
          continue;
        }
      } on DioException catch (error) {
        if (isLast || !_isRetryableError(error)) rethrow;
        lastError = error;
      }

      final backoff = ApiConfig.retryBaseDelay * (1 << i);
      await _sleep(Duration(microseconds: (backoff.inMicroseconds * _jitter())
          .round()));
    }

    throw SyncNetworkException(
      'Sync request failed after ${ApiConfig.maxAttempts} attempts'
      '${lastStatus != null ? ' (last status $lastStatus)' : ''}'
      '${lastError != null ? ': $lastError' : ''}.',
    );
  }

  static bool _isRetryableStatus(int status) =>
      status == 408 || status == 429 || status >= 500;

  static bool _isRetryableError(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      // Bad response means we already got headers; a 5xx is handled above and a
      // 4xx is a real answer from the server.
      DioExceptionType.badResponse => false,
      DioExceptionType.cancel => false,
      DioExceptionType.badCertificate => false,
      DioExceptionType.unknown => true,
      DioExceptionType.transformTimeout => true,
    };
  }

  /// `Retry-After` is either delta-seconds or an HTTP date; both are accepted,
  /// and anything unparseable or absurd is ignored in favour of normal backoff.
  static Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(0, 60));
    }
    final date = _tryParseHttpDate(value);
    if (date == null) return null;
    final delay = date.difference(DateTime.now());
    if (delay.isNegative || delay.inMinutes > 1) return null;
    return delay;
  }

  static DateTime? _tryParseHttpDate(String value) {
    try {
      return HttpDate.parse(value);
    } on FormatException {
      return null;
    }
  }
}

/// The endpoint answered, but not with anything this client can use.
class SyncProtocolException implements Exception {
  SyncProtocolException(this.message);
  final String message;
  @override
  String toString() => 'SyncProtocolException: $message';
}

/// Every retry was exhausted.
class SyncNetworkException implements Exception {
  SyncNetworkException(this.message);
  final String message;
  @override
  String toString() => 'SyncNetworkException: $message';
}