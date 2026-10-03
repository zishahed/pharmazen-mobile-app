import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/data/remote/cookie_storage.dart';

final _uri = Uri.parse('https://pharmazen-backend.vercel.app/api/auth/refresh');

Cookie _refreshCookie() =>
    Cookie('refreshToken', 'rotating-value')..path = '/';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pharmazen-cookies');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('AppCookieStorage', () {
    test('persists cookies across a restart, so the refresh token survives', () async {
      // The refresh token exists nowhere else: it is never in a response body,
      // so losing the jar's files ends the session 15 minutes into every launch.
      final first = PersistCookieJar(storage: AppCookieStorage(
        directory: () async => temp,
      ));
      await first.saveFromResponse(_uri, [_refreshCookie()]);

      // A second jar over the same directory is what the next app launch is:
      // same storage location, nothing carried over in memory.
      final relaunched = PersistCookieJar(storage: AppCookieStorage(
        directory: () async => temp,
      ));
      final loaded = await relaunched.loadForRequest(_uri);

      expect(loaded.map((cookie) => cookie.name), contains('refreshToken'));
      expect(loaded.firstWhere((c) => c.name == 'refreshToken').value,
          'rotating-value');
    });

    test('does not fail a request when no directory can be created', () async {
      // On Android the package default resolves `.cookies/...` against `/`, which
      // throws `PathAccessException`; `CookieManager` reports that as a failed
      // request, so sign-in said the server was unreachable having sent nothing.
      // A parent that is a regular file stands in for an unwritable root and
      // fails the same way, for any user id.
      final blocker = File('${temp.path}/not-a-directory')..writeAsStringSync('');
      final jar = PersistCookieJar(storage: AppCookieStorage(
        directory: () async => Directory('${blocker.path}/cookies'),
      ));

      // The condition the interceptor hits before every request.
      await expectLater(jar.loadForRequest(_uri), completes);

      // And the write that has to work for a session to survive a restart.
      await jar.saveFromResponse(_uri, [_refreshCookie()]);
      final loaded = await jar.loadForRequest(_uri);
      expect(loaded.map((cookie) => cookie.name), contains('refreshToken'));
    });

    test('falls back to memory when the directory lookup itself fails', () async {
      // `path_provider` has no platform channel in a plain Dart host; an app
      // must still be able to sign in, so the jar degrades instead of throwing.
      final jar = PersistCookieJar(storage: AppCookieStorage(
        directory: () async => throw const FileSystemException('no plugin'),
      ));

      await jar.saveFromResponse(_uri, [_refreshCookie()]);
      final loaded = await jar.loadForRequest(_uri);
      expect(loaded.map((cookie) => cookie.name), contains('refreshToken'));
    });
  });
}