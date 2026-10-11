import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../data/providers/sync_providers.dart';

/// A slim strip at the top of the shell that reports network state.
///
/// The two halves behave differently on purpose:
///
/// * **offline** stays on screen until the network returns, because that is
///   information the user needs while acting;
/// * **online** is a confirmation, shown for [_visibleFor] and then removed, so
///   it does not permanently eat a row of the screen.
class ConnectivityBanner extends ConsumerStatefulWidget {
  const ConnectivityBanner({super.key});

  @override
  ConsumerState<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends ConsumerState<ConnectivityBanner> {
  static const _visibleFor = Duration(seconds: 2);

  bool _online = true;
  bool _visible = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // listenManual rather than listen: this reacts to a stream and drives
    // imperative state, which is not safe to do inside `build`.
    ref.listenManual<AsyncValue<bool>>(connectivityStatusProvider, (_, next) {
        final online = next.value;
      if (online != null) _apply(online);
    }, fireImmediately: true);
  }

  void _apply(bool online) {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _online = online;
      _visible = true;
    });
    // Only the online confirmation times out; offline has no timer, which is
    // what keeps it on screen.
    if (online) {
      _hideTimer = Timer(_visibleFor, () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: _visible
          ? _Banner(online: _online)
          : const SizedBox(width: double.infinity),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final foreground = online ? AppColors.primaryGreen : AppColors.error;
    final background = online
        ? AppColors.lightGreen
        : AppColors.error.withValues(alpha: 0.08);

    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Text(
            online ? 'You are online' : 'You are offline',
            style: TextStyle(
              color: foreground,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
