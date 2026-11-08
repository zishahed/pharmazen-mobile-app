import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../data/remote/auth_api_client.dart';
import 'auth_providers.dart';
import 'login_screen.dart';

class RegistrationScreen extends StatelessWidget {
  const RegistrationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(child: RegistrationForm()),
    );
  }
}

class RegistrationForm extends ConsumerStatefulWidget {
  const RegistrationForm({super.key});

  @override
  ConsumerState<RegistrationForm> createState() => _RegistrationFormState();
}

class _RegistrationFormState extends ConsumerState<RegistrationForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirmation = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  String? _emailValidator(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) return 'Enter your email';
    if (!email.contains('@') || !email.contains('.')) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? _passwordValidator(String? value) {
    final password = value ?? '';
    if (password.length < 8) return 'Use at least 8 characters';
    if (!RegExp(r'[A-Za-z]').hasMatch(password) ||
        !RegExp(r'\d').hasMatch(password)) {
      return 'Use both letters and numbers';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref
          .read(authApiClientProvider)
          .register(
            name: _name.text,
            email: _email.text,
            password: _password.text,
          );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const LoginScreen(
            registrationMessage: 'Account created. You can now sign in.',
          ),
        ),
      );
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Registration failed. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _RegistrationBrand(),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _name,
                  enabled: !_busy,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Enter your name' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _email,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline_rounded),
                  ),
                  validator: _emailValidator,
                ),
                const SizedBox(height: 16),
                _passwordField(
                  controller: _password,
                  label: 'Password',
                  obscure: _obscurePassword,
                  onToggle: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  validator: _passwordValidator,
                ),
                const SizedBox(height: 16),
                _passwordField(
                  controller: _confirmPassword,
                  label: 'Confirm password',
                  obscure: _obscureConfirmation,
                  onToggle: () => setState(
                    () => _obscureConfirmation = !_obscureConfirmation,
                  ),
                  validator: (value) =>
                      value != _password.text ? 'Passwords do not match' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  _RegistrationError(message: _error!),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Create account'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => const LoginScreen(),
                          ),
                        ),
                  child: const Text('Already have an account? Sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_busy,
      obscureText: obscure,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        suffixIcon: IconButton(
          onPressed: onToggle,
          icon: Icon(
            obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          ),
        ),
      ),
      validator: validator,
    );
  }
}

class _RegistrationBrand extends StatelessWidget {
  const _RegistrationBrand();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 64,
          width: 64,
          decoration: BoxDecoration(
            color: AppColors.lightGreen,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(
            Icons.local_pharmacy_rounded,
            size: 32,
            color: AppColors.primaryGreen,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Create your account',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Join Pharmazen to manage your medicines and prescriptions',
          style: TextStyle(color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _RegistrationError extends StatelessWidget {
  const _RegistrationError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: const TextStyle(color: AppColors.error, fontSize: 13),
    );
  }
}
