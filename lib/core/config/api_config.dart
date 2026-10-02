/// Build-time configuration, supplied with `--dart-define`.
///
/// Kept free of `flutter_dotenv` so no asset needs to be bundled or decrypted
/// at runtime:
///
/// ```
/// flutter run --dart-define=API_BASE_URL=https://pharmazen-backend.vercel.app/api
/// ```
class ApiConfig {
  const ApiConfig._();

  /// Base URL for every request, including the `/api` suffix.
  ///
  /// Defaults to the deployed production backend so a plain `flutter run`
  /// works without flags; CI and staging override it. An empty override is
  /// rejected in [apiBaseUrl] rather than silently producing requests against
  /// the current origin.
  static const String apiBaseUrlOverride = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://pharmazen-backend.vercel.app/api',
  );

  /// Seconds before a request is abandoned. Mobile networks stall often enough
  /// that a long timeout just holds the sync lock.
  static const Duration requestTimeout = Duration(seconds: 15);

  /// Attempts per request, including the first. Three keeps the worst case
  /// (~15s + 2s + 30s + 4s) inside the connectivity debounce window.
  static const int maxAttempts = 3;

  /// First backoff delay; doubles per attempt with jitter applied by the client.
  static const Duration retryBaseDelay = Duration(seconds: 2);

  /// Rows per write transaction. Large enough to keep round-trips low, small
  /// enough that a writer does not block readers on the background isolate for
  /// long — Drift serialises queries behind writes.
  static const int applyBatchSize = 500;

  /// Floor between automatic syncs. Matches the cadence in SYNC.md and stops a
  /// flapping connection from turning into a request loop.
  static const Duration minSyncInterval = Duration(minutes: 15);

  /// Coalescing window for connectivity-regained triggers: a network bouncing
  /// between wifi and mobile fires many events in a couple of seconds.
  static const Duration connectivityDebounce = Duration(seconds: 3);

  static String get apiBaseUrl {
    final value = apiBaseUrlOverride.trim();
    if (value.isEmpty) {
      throw StateError(
        'API_BASE_URL is empty. Pass '
        '--dart-define=API_BASE_URL=<origin>/api or remove the override.',
      );
    }
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  /// True when a request to [apiBaseUrl] is at all possible.
  static bool get isConfigured => apiBaseUrlOverride.trim().isNotEmpty;
}