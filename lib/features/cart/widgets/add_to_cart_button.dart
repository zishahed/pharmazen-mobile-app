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
/// same way: an unsynced medicine (no server id) and a signed-out user both get
/// an explanation rather than a dead button.
class AddToCartButton extends ConsumerStatefulWidget {
  const AddToCartButton({super.key, required this.medicine});

  final Medicine medicine;

  @override
  ConsumerState<AddToCartButton> createState() => _AddToCartButtonState();
}

class _AddToCartButtonState extends ConsumerState<AddToCartButton> {
  bool _busy = false;

  Future<void> _add() async {
    final remoteId = widget.medicine.remoteId;
    if (remoteId == null) {
      _notify('This medicine is not available to order yet.');
      return;
    }
    if (ref.read(authProvider) is! AuthSignedIn) {
      _notify('Sign in to add items to your cart.');
      return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(cartProvider.notifier).add(remoteId);
      _notify('${widget.medicine.brandName} added to cart.');
    } on CartException catch (error) {
      _notify(error.message);
    } catch (_) {
      _notify('Could not add to cart. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
