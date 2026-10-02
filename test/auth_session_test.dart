import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/token_store.dart';

/// Answers every request with [body] and records what was sent.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body);

  final String body;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
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
  late Dio dio;
  late TokenStore tokenStore;
  late ApiClient api;

  setUp(() {
    // Installs an in-memory platform, so TokenStore writes are observable
    // without a device keychain.
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    adapter = _StubAdapter(_loginBody);
    dio = Dio()..httpClientAdapter = adapter;
    tokenStore = TokenStore();
    api = ApiClient(
      dio: dio,
      tokenStore: tokenStore,
      cookieJar: CookieJar(),
    );
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