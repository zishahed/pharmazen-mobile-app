import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../data/remote/cart_api_client.dart';
import '../auth/auth_providers.dart';
import 'cart_providers.dart';

/// The Cart tab.
///
/// Server-owned: every mutation returns the whole cart, so the list here is
/// whatever the last reply said rather than a local tally that can drift.
/// Signed-out callers see a prompt rather than a fetch, because the endpoint is
/// authenticated.
class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
  /// Lines with a request in flight, so their stepper cannot be double-tapped.
  final _busy = <String>{};

  Future<void> _changeQuantity(CartItem item, int delta) async {
    final next = item.quantity + delta;
    if (next < 1 || next > cartMaxQuantity || _busy.contains(item.medicineId)) {
      return;
    }

    setState(() => _busy.add(item.medicineId));
    try {
      await ref.read(cartProvider.notifier).setQuantity(item.medicineId, next);
    } on CartException catch (error) {
      _notify(error.message);
    } catch (_) {
      _notify('Could not update the cart.');
    } finally {
      if (mounted) setState(() => _busy.remove(item.medicineId));
    }
  }

  Future<void> _remove(CartItem item) async {
    if (_busy.contains(item.medicineId)) return;
    setState(() => _busy.add(item.medicineId));
    try {
      await ref.read(cartProvider.notifier).remove(item.medicineId);
    } on CartException catch (error) {
      _notify(error.message);
    } catch (_) {
      _notify('Could not remove the medicine.');
    } finally {
      if (mounted) setState(() => _busy.remove(item.medicineId));
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
    if (ref.watch(authProvider) is! AuthSignedIn) {
      return const _CenteredMessage(
        icon: Icons.lock_outline_rounded,
        title: 'Sign in to use your cart',
        message:
            'Your cart is tied to your account. Sign in from the '
            'Profile tab to start adding medicines.',
      );
    }

    final async = ref.watch(cartProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => _CenteredMessage(
        icon: Icons.error_outline_rounded,
        title: 'Could not load your cart',
        message: 'Check your connection and try again.',
        trailing: TextButton(
          onPressed: () => ref.read(cartProvider.notifier).refresh(),
          child: const Text('Try again'),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const _CenteredMessage(
            icon: Icons.shopping_cart_outlined,
            title: 'Your cart is empty',
            message:
                'Add a medicine from the catalogue and it will show up '
                'here.',
          );
        }
        return _buildCart(items);
      },
    );
  }

  Widget _buildCart(List<CartItem> items) {
    final count = items.fold<int>(0, (sum, item) => sum + item.quantity);
    final total = items.fold<double>(0, (sum, item) => sum + item.subtotal);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Your cart',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  '$count ${count == 1 ? 'item' : 'items'}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => ref.read(cartProvider.notifier).refresh(),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _CartItemCard(
                      item: item,
                      busy: _busy.contains(item.medicineId),
                      onDecrease: () => _changeQuantity(item, -1),
                      onIncrease: () => _changeQuantity(item, 1),
                      onRemove: () => _remove(item),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            _Summary(count: count, total: total),
          ],
        ),
      ),
    );
  }
}

class _CartItemCard extends StatelessWidget {
  const _CartItemCard({
    required this.item,
    required this.busy,
    required this.onDecrease,
    required this.onIncrease,
    required this.onRemove,
  });

  final CartItem item;
  final bool busy;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(
                backgroundColor: AppColors.lightGreen,
                foregroundColor: AppColors.primaryGreen,
                child: Icon(Icons.medication_outlined),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (item.genericName != null &&
                        item.genericName!.isNotEmpty)
                      Text(
                        item.genericName!,
                        style: const TextStyle(
                          color: AppColors.primaryBlue,
                          fontSize: 13,
                        ),
                      ),
                    if (item.requiresPrescription)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          'Prescription required',
                          style: TextStyle(
                            color: AppColors.error,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: busy ? null : onRemove,
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline_rounded),
                color: AppColors.error,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                _money(item.price),
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              _Stepper(
                quantity: item.quantity,
                busy: busy,
                onDecrease: onDecrease,
                onIncrease: onIncrease,
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 78,
                child: Text(
                  _money(item.subtotal),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.quantity,
    required this.busy,
    required this.onDecrease,
    required this.onIncrease,
  });

  final int quantity;
  final bool busy;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            icon: Icons.remove_rounded,
            enabled: !busy && quantity > 1,
            onPressed: onDecrease,
          ),
          SizedBox(
            width: 30,
            child: Text(
              '$quantity',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add_rounded,
            enabled: !busy && quantity < cartMaxQuantity,
            onPressed: onIncrease,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      color: AppColors.primaryBlue,
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.count, required this.total});

  final int count;
  final double total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Subtotal ($count ${count == 1 ? 'item' : 'items'})',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const Spacer(),
              Text(
                _money(total),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'Delivery',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const Spacer(),
              const Text(
                'Free',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryGreen,
                ),
              ),
            ],
          ),
          const Divider(height: 22),
          Row(
            children: [
              const Text(
                'Total',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                _money(total),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primaryBlue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.border),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (trailing != null) ...[const SizedBox(height: 4), trailing!],
          ],
        ),
      ),
    );
  }
}

String _money(double amount) => '৳${amount.toStringAsFixed(2)}';
