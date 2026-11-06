import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A small dependency-free shimmer placeholder used while remote/local data
/// loads. Keeping the animation here avoids a spinner replacing the whole page.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = 8,
  });

  final double width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1.5 + (_controller.value * 3), 0),
            end: Alignment(-0.5 + (_controller.value * 3), 0),
            colors: const [
              AppColors.border,
              Color(0xFFF4F7FA),
              AppColors.border,
            ],
          ),
        ),
        child: child,
      ),
      child: SizedBox(width: widget.width, height: widget.height),
    );
  }
}

class MedicineListSkeleton extends StatelessWidget {
  const MedicineListSkeleton({
    super.key,
    this.count = 6,
    this.scrollable = true,
  });

  final int count;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (var index = 0; index < count; index++) ...[
        const _MedicineSkeletonTile(),
        if (index < count - 1) const SizedBox(height: 10),
      ],
    ];
    if (scrollable) {
      return ListView(
        physics: const NeverScrollableScrollPhysics(),
        children: tiles,
      );
    }
    return Column(
      children: tiles,
    );
  }
}

class _MedicineSkeletonTile extends StatelessWidget {
  const _MedicineSkeletonTile();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const SkeletonBox(width: 48, height: 48, radius: 24),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 150, height: 16),
                  SizedBox(height: 8),
                  SkeletonBox(width: 110, height: 12),
                  SizedBox(height: 6),
                  SkeletonBox(width: 180, height: 10),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SkeletonBox(width: 32, height: 32, radius: 16),
          ],
        ),
      ),
    );
  }
}

class CartSkeleton extends StatelessWidget {
  const CartSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        SkeletonBox(width: 120, height: 24),
        SizedBox(height: 20),
        _CartSkeletonCard(),
        SizedBox(height: 10),
        _CartSkeletonCard(),
        SizedBox(height: 18),
        SkeletonBox(width: double.infinity, height: 170),
      ],
    );
  }
}

class _CartSkeletonCard extends StatelessWidget {
  const _CartSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return const SkeletonBox(width: double.infinity, height: 116);
  }
}

class OrderHistorySkeleton extends StatelessWidget {
  const OrderHistorySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBox(width: 160, height: 20),
        SizedBox(height: 10),
        SkeletonBox(width: 240, height: 13),
        SizedBox(height: 20),
        SkeletonBox(width: double.infinity, height: 112),
        SizedBox(height: 10),
        SkeletonBox(width: double.infinity, height: 112),
      ],
    );
  }
}
