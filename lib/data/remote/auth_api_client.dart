import 'package:dio/dio.dart';

import 'api_client.dart';

/// The signed-in user, as returned by `/api/auth/*`.
///
/// Field names mirror the backend select in `auth.service.js` — notably `name`,
/// not `fullName`. `createdAt` is absent from the refresh response, so it is
/// nullable and deliberately not persisted.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.createdAt,
  });

  final String id;
  final String name;
  final String email;
  final String role;
  final String? createdAt;

  bool get isCustomer => role == 'customer';

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    email: (json['email'] as String?) ?? '',
    role: (json['role'] as String?) ?? 'customer',
    createdAt: json['createdAt'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'role': role,
    if (createdAt != null) 'createdAt': createdAt,
  };

  @override
  bool operator ==(Object other) =>
      other is AuthUser &&
      other.id == id &&
      other.name == name &&
      other.email == email &&
      other.role == role;

  @override
  int get hashCode => Object.hash(id, name, email, role);
}

/// A failure from the auth endpoints, carrying the server's own message so the
/// UI does not have to invent one.
class AuthException implements Exception {
  const AuthException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to `/api/auth` on top of the shared [ApiClient].
///
/// The access token is persisted here; the refresh cookie is captured by
/// `ApiClient`'s interceptor as a side effect and never read directly.
class AuthApiClient {
  AuthApiClient(this._api);

  final ApiClient _api;

  /// Signs in and persists the access token.
  ///
  /// The controller answers 401 for every failure — including a genuine server
  /// fault — so the status alone must never be rendered as "wrong password";
  /// the message comes from the server instead.
  Future<AuthUser> login({
    required String email,
    required String password,
  }) async {
    final response = await _api.dio.post<Map<String, dynamic>>(
      '/auth/login',
      data: <String, dynamic>{
        'email': email.trim(),
        'password': password,
      },
    );

    if (response.statusCode != 200) {
      throw AuthException(
        ApiClient.messageOf(response.data) ?? 'Could not sign in. Try again.',
        statusCode: response.statusCode,
      );
    }

    final data = response.data?['data'] as Map<String, dynamic>?;
    final token = data?['accessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw const AuthException('The server did not return a session token.');
    }

    // Before the interceptor can attach it on any later request.
    await _api.adoptAccessToken(token);

    return AuthUser.fromJson(data!['user'] as Map<String, dynamic>);
  }

  /// Validates a persisted access token on launch.
  ///
  /// Returns null when there is no token or it is no longer usable. A 401 here
  /// has already had one silent refresh attempted by [ApiClient], so a null
  /// means the session is genuinely gone.
  Future<AuthUser?> restoreSession() async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>('/auth/me');
      if (response.statusCode != 200) return null;
      final data = response.data?['data'] as Map<String, dynamic>?;
      return data == null
          ? null
          : AuthUser.fromJson(data['user'] as Map<String, dynamic>);
    } on DioException {
      return null;
    }
  }

  /// Ends the session server-side, then locally.
  ///
  /// Local state is cleared even if the network call fails: a user tapping
  /// "sign out" offline must still end up signed out on this device.
  Future<void> logout() async {
    try {
      await _api.dio.post<Map<String, dynamic>>('/auth/logout');
    } on DioException {
      /* cleared locally regardless */
    }
    await _api.clearSession();
  }
}