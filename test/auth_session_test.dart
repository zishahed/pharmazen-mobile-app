import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/cookie_storage.dart';
import 'package:pharmazen_mobile_app/data/remote/token_store.dart';

/// Answers every request with [body] and records what was sent.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body, {this.status = 200, this.failure, this.setCookie});

  final String body;
  final int status;

  /// When set, the request fails this way instead of being answered — how a
  /// request that never reached a server reaches a client.
  final DioExceptionType? failure;

  /// A `Set-Cookie` header value, as the login controller sends for the refresh
  /// token.
  final String? setCookie;

  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final type = failure;
    if (type != null) {
      throw DioException(
        requestOptions: options,
        type: type,
        error: 'Failed host lookup',
      );
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        if (setCookie != null) HttpHeaders.setCookieHeader: [setCookie!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _loginBody = '''
{
  "success": true,
  "message": "Login successful",
  "data": {
    "user": {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Nusrat Jahan",
      "email": "nusrat@example.com",
      "role": "customer",
      "createdAt": "2025-01-01T00:00:00.000Z"
    },
    "accessToken": "the-access-token"
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _StubAdapter adapter;
  late TokenStore tokenStore;
  late ApiClient api;
  late Directory temp;

  /// An [ApiClient] that answers with [stub].
  ///
  /// Built on [ApiClient.baseOptions] rather than a bare Dio: its
  /// `validateStatus` is what decides whether a rejection arrives as a response
  /// or as an exception, so a test on Dio's defaults would not run the code path
  /// the app runs. Leaving [cookieJar] unset is deliberate where the jar itself
  /// is under test.
  ApiClient over(
    _StubAdapter stub, {
    CookieJar? cookieJar,
    AppCookieStorage? cookieStorage,
  }) => ApiClient(
    dio: Dio(ApiClient.baseOptions())..httpClientAdapter = stub,
    tokenStore: tokenStore,
    cookieJar: cookieJar,
    cookieStorage: cookieStorage,
  );

  setUp(() {
    // Installs an in-memory platform, so TokenStore writes are observable
    // without a device keychain.
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    adapter = _StubAdapter(_loginBody);
    tokenStore = TokenStore();
    api = over(adapter, cookieJar: CookieJar());
    temp = Directory.systemTemp.createTempSync('pharmazen-auth');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('login', () {
    test('persists the access token it was handed', () async {
      final user = await AuthApiClient(api).login(
        email: 'nusrat@example.com',
        password: 'secret123',
      );

      expect(user.email, 'nusrat@example.com');
      expect(
        await tokenStore.readAccessToken(),
        'the-access-token',
        reason:
            'login receives the only access token the app will ever see; if it '
            'is not stored, the interceptor has nothing to attach and every '
            'later request goes out unauthenticated',
      );
    });

    test('trims the email before sending it', () async {
      await AuthApiClient(api).login(
        email: '  nusrat@example.com  ',
        password: 'secret123',
      );

      final sent = adapter.requests.single.data! as Map<String, dynamic>;
      expect(sent['email'], 'nusrat@example.com');
    });

    test('persists the refresh cookie in the directory it was given', () async {
      // The refresh token exists only as this cookie, so the jar's storage
      // location is load-bearing — and `cookie_jar`'s own default is the
      // read-only relative `.cookies/...` on Android, which stops every request
      // before it leaves the device. Injecting only the storage means the jar
      // under test is the app's own composition.
      adapter = _StubAdapter(
        _loginBody,
        setCookie: 'refreshToken=rotating-value; Path=/; Max-Age=604800',
      );
      final app = over(
        adapter,
        cookieStorage: AppCookieStorage(directory: () async => temp),
      );

      final user = await AuthApiClient(app).login(
        email: 'nusrat@example.com',
        password: 'secret123',
      );

      expect(user.email, 'nusrat@example.com');
      // Not "a cookie exists in memory" but "it reached the directory": a silent
      // fallback to memory would leave the session dying at every restart.
      expect(
        temp.listSync().whereType<Directory>(),
        isNotEmpty,
        reason: 'the refresh cookie should have been written under $temp',
      );
    });

    test('completes when the cookie jar has nowhere to persist', () async {
      // `CookieManager` reports an unusable jar as a failed request, so a
      // read-only storage location made sign-in report an unreachable server
      // having sent nothing. A parent that is a regular file stands in for one,
      // for any user id.
      final blocker = File('${temp.path}/not-a-directory')
        ..writeAsStringSync('');
      final app = over(
        adapter,
        cookieStorage: AppCookieStorage(
          directory: () async => Directory('${blocker.path}/cookies'),
        ),
      );

      final user = await AuthApiClient(app).login(
        email: 'nusrat@example.com',
        password: 'secret123',
      );

      expect(user.email, 'nusrat@example.com');
      expect(adapter.requests, hasLength(1));
    });
  });

  group('a sign-in that does not succeed', () {
    test('reports what the server said', () async {
      adapter = _StubAdapter(
        '{"success":false,"message":"Invalid email or password"}',
        status: 401,
      );
      api = over(adapter, cookieJar: CookieJar());

      await expectLater(
        AuthApiClient(api).login(
          email: 'nusrat@example.com',
          password: 'wrongpass',
        ),
        throwsA(
          isA<AuthException>()
              .having((e) => e.message, 'message', 'Invalid email or password')
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
        reason:
            'the controller answers 401 for every failure, so the wording has to '
            'come from the server: reporting this as a network problem sends '
            'the user to debug the wrong thing',
      );
      expect(await tokenStore.readAccessToken(), isNull);
    });

    test('says the server was unreachable only when nothing answered', () async {
      adapter = _StubAdapter('', failure: DioExceptionType.connectionError);
      api = over(adapter, cookieJar: CookieJar());

      await expectLater(
        AuthApiClient(api).login(
          email: 'nusrat@example.com',
          password: 'secret123',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach the server'),
          ),
        ),
      );
    });
  });

  group('the Bearer header', () {
    test('is attached to a later request once a session exists', () async {
      await AuthApiClient(api).login(
        email: 'nusrat@example.com',
        password: 'secret123',
      );

      await api.dio.get<Map<String, dynamic>>('/prescriptions');

      final authorised = adapter.requests.last.headers['Authorization'];
      expect(authorised, 'Bearer the-access-token');
    });

    test('is absent before sign-in, rather than sent empty', () async {
      await api.dio.get<Map<String, dynamic>>('/prescriptions');

      expect(adapter.requests.last.headers, isNot(contains('Authorization')));
    });

    test('is omitted on the login call itself', () async {
      // Attaching a stale token to the login request would be pointless and
      // could confuse a server that treats it as a session.
      await AuthApiClient(api).login(
        email: 'nusrat@example.com',
        password: 'secret123',
      );

      expect(adapter.requests.first.headers, isNot(contains('Authorization')));
    });
  });
}