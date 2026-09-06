import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_colors.dart';
import '../../data/providers/medicine_providers.dart';
import '../../data/repositories/medicine_repository.dart';
import '../medicines/widgets/medicines_widgets.dart';

class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key, required this.mode});

  final MedicineSearchMode mode;

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  static const _topPadding = 8.0;

  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _headerKeys = {};
  final GlobalKey _firstItemKey = GlobalKey();
  final ValueNotifier<int> _activeIndex = ValueNotifier(0);

  List<String> _letters = const [];
  Map<String, List<String>> _sections = const {};
  bool _loading = true;
  String? _error;

  double? _headerHeight;
  double? _itemHeight;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _activeIndex.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values =
          await ref.read(medicineRepositoryProvider).allValues(widget.mode);
      if (!mounted) return;
      _groupValues(values);
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureSizes());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _groupValues(List<String> values) {
    final sections = <String, List<String>>{};
    for (final value in values) {
      final first = value.trim().isNotEmpty ? value.trim()[0].toUpperCase() : '#';
      final letter = RegExp('[A-Za-z]').hasMatch(first) ? first : '#';
      (sections[letter] ??= []).add(value);
    }
    _sections = sections;
    _letters = sections.keys.toList(growable: false);
    _headerKeys
      ..clear()
      ..addEntries(_letters.map((letter) => MapEntry(letter, GlobalKey())));
  }

  void _measureSizes() {
    final headerBox = _headerKeys[_letters.firstOrNull]?.currentContext
        ?.findRenderObject() as RenderBox?;
    final itemBox = _firstItemKey.currentContext?.findRenderObject() as RenderBox?;
    final headerHeight = headerBox?.size.height;
    final itemHeight = itemBox?.size.height;
    if (headerHeight == null || itemHeight == null) return;
    if (_headerHeight == headerHeight && _itemHeight == itemHeight) return;
    setState(() {
      _headerHeight = headerHeight;
      _itemHeight = itemHeight;
    });
  }

  List<double> _sectionOffsets() {
    final headerHeight = _headerHeight;
    final itemHeight = _itemHeight;
    if (headerHeight == null || itemHeight == null) return const [];

    final offsets = <double>[];
    var offset = _topPadding;
    for (final letter in _letters) {
      offsets.add(offset);
      offset += headerHeight + (_sections[letter]?.length ?? 0) * itemHeight;
    }
    return offsets;
  }

  int _activeSectionForOffset(double pixels) {
    final offsets = _sectionOffsets();
    if (offsets.isEmpty) return 0;
    var active = 0;
    for (var i = 0; i < offsets.length; i++) {
      if (offsets[i] <= pixels) active = i;
    }
    return active;
  }

  void _onScroll() {
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    final active = _activeSectionForOffset(
      position.pixels.clamp(0, position.maxScrollExtent),
    );
    if (active != _activeIndex.value) {
      _activeIndex.value = active;
    }
  }

  void _onIndexHover(int index) {
    if (index != _activeIndex.value) {
      _activeIndex.value = index;
    }
  }

  void _onIndexSelected(int index) {
    _onIndexHover(index);
    final offsets = _sectionOffsets();
    if (offsets.isEmpty || index >= offsets.length) return;
    final target = offsets[index].clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.mode.browseTitle)),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return MessagePlaceholder(
        icon: Icons.error_outline_rounded,
        message: 'Something went wrong while loading.',
        trailing: TextButton(onPressed: _load, child: const Text('Try again')),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AlphabetIndex(
          letters: _letters,
          activeIndex: _activeIndex,
          onHover: _onIndexHover,
          onSelected: _onIndexSelected,
        ),
        Expanded(
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.only(top: 8, bottom: 20),
            children: _buildRows(),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRows() {
    final rows = <Widget>[];
    var firstItem = true;
    for (final letter in _letters) {
      rows.add(
        Container(
          key: _headerKeys[letter],
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          color: AppColors.lightGreen,
          child: Text(
            letter,
            style: const TextStyle(
              color: AppColors.primaryGreen,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
        ),
      );
      for (final value in _sections[letter]!) {
        rows.add(
          ListTile(
            key: firstItem ? _firstItemKey : null,
            onTap: () => context.push(
              '/browse/results'
              '?type=${widget.mode.name}'
              '&value=${Uri.encodeQueryComponent(value)}',
            ),
            leading: const Icon(
              Icons.medication_outlined,
              color: AppColors.primaryBlue,
            ),
            title: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.border,
            ),
          ),
        );
        firstItem = false;
      }
    }
    return rows;
  }
}

class _AlphabetIndex extends StatefulWidget {
  const _AlphabetIndex({
    required this.letters,
    required this.activeIndex,
    required this.onHover,
    required this.onSelected,
  });

  final List<String> letters;
  final ValueListenable<int> activeIndex;
  final ValueChanged<int> onHover;
  final ValueChanged<int> onSelected;

  @override
  State<_AlphabetIndex> createState() => _AlphabetIndexState();
}

class _AlphabetIndexState extends State<_AlphabetIndex> {
  int _lastHover = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.letters.isEmpty) {
      return const SizedBox(width: 26);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _onSelect(context, details.localPosition),
          onVerticalDragDown: (details) =>
              _onHover(context, details.localPosition),
          onVerticalDragUpdate: (details) =>
              _onHover(context, details.localPosition),
          onVerticalDragEnd: (_) => widget.onSelected(_lastHover),
          onVerticalDragCancel: () => widget.onSelected(_lastHover),
          child: SizedBox(
            width: 26,
            child: ValueListenableBuilder<int>(
              valueListenable: widget.activeIndex,
              builder: (context, active, _) {
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < widget.letters.length; i++)
                      Expanded(
                        child: Center(
                          child: Container(
                            width: 18,
                            height: 18,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: i == active
                                  ? AppColors.primaryBlue
                                  : Colors.transparent,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              widget.letters[i],
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: i == active
                                    ? AppColors.surface
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  int _indexAt(BuildContext context, Offset position) {
    final box = context.findRenderObject() as RenderBox?;
    final height = box?.size.height ?? 0;
    if (height == 0 || widget.letters.isEmpty) return 0;
    var index = (position.dy / height * widget.letters.length).floor();
    if (index < 0) index = 0;
    if (index >= widget.letters.length) index = widget.letters.length - 1;
    return index;
  }

  void _onHover(BuildContext context, Offset position) {
    _lastHover = _indexAt(context, position);
    widget.onHover(_lastHover);
  }

  void _onSelect(BuildContext context, Offset position) {
    _lastHover = _indexAt(context, position);
    widget.onSelected(_lastHover);
  }
}