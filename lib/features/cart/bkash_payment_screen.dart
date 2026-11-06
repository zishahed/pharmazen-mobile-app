import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/app_colors.dart';
import '../../data/remote/order_api_client.dart';

class BkashPaymentScreen extends StatefulWidget {
  const BkashPaymentScreen({
    super.key,
    required this.session,
    required this.client,
  });

  final PaymentSession session;
  final OrderApiClient client;

  @override
  State<BkashPaymentScreen> createState() => _BkashPaymentScreenState();
}

class _BkashPaymentScreenState extends State<BkashPaymentScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _openBkash() async {
    final uri = Uri.tryParse(widget.session.bkashUrl);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      setState(
        () => _error = 'Could not open bKash. Use the payment button below.',
      );
    }
  }

  Future<void> _complete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final transactionId = await widget.client.executePayment(
        widget.session.paymentId,
      );
      if (mounted) Navigator.of(context).pop(transactionId);
    } on OrderException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pay with bKash')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.account_balance_wallet,
                size: 72,
                color: Colors.pink,
              ),
              const SizedBox(height: 18),
              const Text(
                'Complete your payment',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              Text(
                'Amount: ৳${widget.session.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 18,
                  color: AppColors.textSecondary,
                ),
              ),
              if (widget.session.isMock)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Sandbox payment mode',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openBkash,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open bKash'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _complete,
                  child: Text(
                    _busy ? 'Verifying...' : 'I have completed payment',
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
