import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/api_client.dart';
import '../../data/remote/auth_api_client.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final authApiClientProvider = Provider<AuthApiClient>(
  (ref) => AuthApiClient(ref.watch(apiClientProvider)),
);

/// Session state.
///
/// [AuthUnknown] is distinct from [AuthSignedOut] because "we have not asked
/// the server yet" and "the server says there is no session" need different
/// screens: the first must not flash the login form on every cold start.
sealed class AuthState {
  const AuthState();
}

class AuthUnknown extends AuthState {
  const AuthUnknown();
}

class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

class AuthSignedIn extends AuthState {
  const AuthSignedIn(this.user);

  final AuthUser user;
}

final authProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Deferred so the notifier is mounted before state is replaced; a cold
    // start must not block on the network before the first frame.
    scheduleMicrotask(_restore);
    return const AuthUnknown();
  }

  Future<void> _restore() async {
    final user = await ref.read(authApiClientProvider).restoreSession();
    state = user == null ? const AuthSignedOut() : AuthSignedIn(user);
  }

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    final user = await ref
        .read(authApiClientProvider)
        .login(email: email, password: password);
    state = AuthSignedIn(user);
  }

  Future<void> signOut() async {
    // Local state flips first: the network call may fail offline and the user
    // asked to be signed out now.
    state = const AuthSignedOut();
    await ref.read(authApiClientProvider).logout();
  }
}