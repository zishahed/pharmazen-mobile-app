import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../data/remote/cart_api_client.dart';
import '../../../domain/models/medicine.dart';
import '../../auth/auth_providers.dart';
import '../cart_providers.dart';

/// The "add to cart" affordance shared by the medicine list and the detail
/// screen.
///
/// It owns the session and availability checks so every entry point behaves the
/// same way.
class AddToCartButton extends ConsumerStatefulWidget {
  const AddToCartButton({super.key, required this.medicine});

  final Medicine medicine;

  @override
  ConsumerState<AddToCartButton> createState() => _AddToCartButtonState();
}

class _AddToCartButtonState extends ConsumerState<AddToCartButton> {
  bool _busy = false;

  Future<void> _add() async {
    if (ref.read(authProvider) is! AuthSignedIn) {
      _notify('Sign in to add items to your cart.');
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    _showAddingFeedback(messenger);
    try {
      final cartApi = ref.read(cartApiClientProvider);
      final remoteId =
          widget.medicine.remoteId ??
          await cartApi.findMedicineId(widget.medicine.brandName);
      if (remoteId == null || remoteId.isEmpty) {
        _notify(
          'We could not find this medicine online. Check your connection and '
          'try again.',
        );
        return;
      }
      await ref.read(cartProvider.notifier).add(remoteId);
      _notify('${widget.medicine.brandName} added to cart.');
    } on CartException catch (error) {
      _notify(error.message);
    } catch (_) {
      _notify('Could not add to cart. Try again.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      } else {
        // The cart write must finish even if the user leaves the screen, but
        // its loading snackbar must not outlive the route that started it.
        messenger?.hideCurrentSnackBar();
      }
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          backgroundColor: AppColors.lightGreen,
          elevation: 3,
          content: Text(
            message,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
  }

  void _showAddingFeedback(ScaffoldMessengerState? messenger) {
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          duration: Duration(hours: 1),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
          backgroundColor: AppColors.lightGreen,
          elevation: 3,
          content: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primaryGreen,
                ),
              ),
              SizedBox(width: 12),
              Text(
                'Adding medicine to your cart',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _busy ? null : _add,
      tooltip: 'Add to cart',
      color: AppColors.primaryBlue,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add_shopping_cart_rounded),
    );
  }
}
