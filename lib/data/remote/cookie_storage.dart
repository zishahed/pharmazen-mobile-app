import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';

/// Cookie storage rooted in the app's own directory.
///
/// `cookie_jar`'s [FileStorage] takes its directory as a constructor argument
/// and, left unset, falls back to the *relative* path `.cookies/4/...`, which
/// resolves against `Directory.current`. On Android that is `/`, which is
/// read-only, so the jar's first `loadForRequest` — that is, before *every*
/// request `ApiClient` makes — throws `PathAccessException`. `CookieManager`
/// reports a failed storage as a failed request, so sign-in reported that the
/// server could not be reached when nothing had ever left the device.
///
/// [path_provider] answers asynchronously and [FileStorage]'s path cannot be,
/// so the directory is resolved in [init] — the one storage method
/// [PersistCookieJar] already awaits before it touches the filesystem. The
/// constructor stays synchronous, which keeps `ApiClient` a plain `Provider`.
class AppCookieStorage implements Storage {
  AppCookieStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Storage? _storage;
  Future<Storage>? _opening;
  final _MemoryStorage _memory = _MemoryStorage();

  /// The storage actually in use, opened on first use.
  ///
  /// A jar always calls [init] before anything else, so this is normally the
  /// already-open file storage; the fallback keeps a direct caller from
  /// reaching a `FileStorage` whose path was never initialised.
  Future<Storage> get _ready async {
    final storage = _storage;
    if (storage != null) return storage;
    final opening = _opening;
    if (opening != null) return opening;
    return _memory;
  }

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) {
    final opening = _open(persistSession, ignoreExpires).then((storage) {
      _storage = storage;
      _opening = null;
      return storage;
    });
    _opening = opening;
    return opening;
  }

  /// Opens the first candidate storage that works.
  ///
  /// Files are preferred because the refresh token is only ever a cookie, so an
  /// app that cannot write them loses the session every time the 15 minute
  /// access token expires. When no directory can be created the cookies stay in
  /// memory for the life of the process, which costs a re-login after a restart
  /// instead of making every request fail — being unable to sign in at all is
  /// not a trade worth making.
  Future<Storage> _open(bool persistSession, bool ignoreExpires) async {
    try {
      final files = FileStorage((await _directory()).path);
      // `init` creates the directory, so an unusable location fails here rather
      // than on the first cookie write.
      await files.init(persistSession, ignoreExpires);
      return files;
    } on Exception {
      await _memory.init(persistSession, ignoreExpires);
      return _memory;
    }
  }

  @override
  Future<String?> read(String key) async => (await _ready).read(key);

  @override
  Future<void> write(String key, String value) async =>
      (await _ready).write(key, value);

  @override
  Future<void> delete(String key) async => (await _ready).delete(key);

  @override
  Future<void> deleteAll(List<String> keys) async =>
      (await _ready).deleteAll(keys);
}

/// Keeps cookies in a map, for when there is nowhere on disk to put them.
///
/// Deliberately not `FileStorage()` with no directory: that is the read-only
/// relative path this class exists to avoid.
class _MemoryStorage implements Storage {
  final Map<String, String> _entries = <String, String>{};

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String value) async {
    _entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }

  @override
  Future<void> deleteAll(List<String> keys) async {
    for (final key in keys) {
      _entries.remove(key);
    }
  }
}