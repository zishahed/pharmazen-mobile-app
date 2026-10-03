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

/// A single row of the browse list: either a letter header or a value.
class _BrowseRow {
  const _BrowseRow.header(this.letter) : value = null;

  const _BrowseRow.item(this.value) : letter = null;

  final String? letter;
  final String? value;

  bool get isHeader => letter != null;
}

/// Reports the real total height of the list. Without this the viewport would
/// extrapolate it from the rows it happens to have built, which leaves the
/// deepest letters unreachable.
class _BrowseRowDelegate extends SliverChildBuilderDelegate {
  _BrowseRowDelegate({
    required NullableIndexedWidgetBuilder itemBuilder,
    required int childCount,
    required this.contentExtent,
  }) : super(itemBuilder, childCount: childCount);

  final double contentExtent;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => contentExtent;

  @override
  bool shouldRebuild(_BrowseRowDelegate oldDelegate) =>
      super.shouldRebuild(oldDelegate) ||
      contentExtent != oldDelegate.contentExtent;
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  static const _topPadding = 8.0;
  static const _bottomPadding = 20.0;
  static const _headerPadding = EdgeInsets.fromLTRB(16, 12, 16, 8);
  static const _headerTextStyle = TextStyle(
    color: AppColors.primaryGreen,
    fontWeight: FontWeight.w800,
    fontSize: 16,
  );
  static const _itemTextStyle = TextStyle(fontSize: 14);

  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<int> _activeIndex = ValueNotifier(0);

  // Offscreen copies of the two row shapes. Their heights are measured once and
  // then handed to the sliver, so every offset below stays exact without having
  // to lay out the whole list.
  final GlobalKey _sampleHeaderKey = GlobalKey();
  final GlobalKey _sampleItemKey = GlobalKey();

  List<String> _letters = const [];
  List<_BrowseRow> _rows = const [];
  List<double> _sectionOffsets = const [];

  bool _loading = true;
  String? _error;

  double _headerExtent = 0;
  double _itemExtent = 0;
  double _contentExtent = 0;

  bool get _extentsReady => _headerExtent > 0 && _itemExtent > 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme, text scale or metrics may have changed, so the cached heights can
    // no longer be trusted.
    _headerExtent = 0;
    _itemExtent = 0;
    _rebuildSectionOffsets();
    _scheduleMeasurement();
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
      setState(() {
        _groupValues(values);
        _loading = false;
      });
      _scheduleMeasurement();
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
      final trimmed = value.trim();
      final first = trimmed.isEmpty ? '' : trimmed[0].toUpperCase();
      final letter = RegExp('[A-Za-z]').hasMatch(first) ? first : '#';
      (sections[letter] ??= <String>[]).add(value);
    }

    final rows = <_BrowseRow>[];
    for (final entry in sections.entries) {
      rows.add(_BrowseRow.header(entry.key));
      for (final value in entry.value) {
        rows.add(_BrowseRow.item(value));
      }
    }

    _letters = sections.keys.toList(growable: false);
    _rows = List<_BrowseRow>.unmodifiable(rows);
    _rebuildSectionOffsets();
  }

  void _scheduleMeasurement() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(_measureExtents);
    });
  }

  /// Every header has the same height and so does every value row, which makes
  /// the offset of any letter a plain sum of the two.
  void _measureExtents() {
    if (_rows.length < 2) return;
    final headerBox =
        _sampleHeaderKey.currentContext?.findRenderObject() as RenderBox?;
    final itemBox =
        _sampleItemKey.currentContext?.findRenderObject() as RenderBox?;
    final headerExtent = headerBox?.size.height ?? 0;
    final itemExtent = itemBox?.size.height ?? 0;
    if (headerExtent <= 0 || itemExtent <= 0) return;
    if (headerExtent == _headerExtent && itemExtent == _itemExtent) return;
    _headerExtent = headerExtent;
    _itemExtent = itemExtent;
    _rebuildSectionOffsets();
  }

  void _rebuildSectionOffsets() {
    if (!_extentsReady || _rows.isEmpty) {
      _sectionOffsets = const [];
      _contentExtent = 0;
      return;
    }

    var offset = _topPadding;
    final offsets = <double>[];
    for (final row in _rows) {
      if (row.isHeader) {
        offsets.add(offset);
        offset += _headerExtent;
      } else {
        offset += _itemExtent;
      }
    }
    _contentExtent = offset - _topPadding;
    _sectionOffsets = List<double>.unmodifiable(offsets);
  }

  int _activeSectionForOffset(double pixels) {
    final offsets = _sectionOffsets;
    if (offsets.isEmpty) return 0;
    var low = 0;
    var high = offsets.length - 1;
    var active = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (offsets[mid] <= pixels) {
        active = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return active;
  }

  void _onScroll() {
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    final active = _activeSectionForOffset(
      position.pixels.clamp(0.0, position.maxScrollExtent),
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
    if (index < 0 || index >= _sectionOffsets.length) return;
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;

    final target = _sectionOffsets[index].clamp(0.0, position.maxScrollExtent);
    final distance = (target - position.pixels).abs();

    // Animating across tens of thousands of pixels builds and throws away
    // hundreds of rows per frame, which is what used to freeze the UI, so long
    // hops are applied at once instead.
    if (distance <= position.viewportDimension * 2) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(target);
    }
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

    return Stack(
      children: [
        Positioned.fill(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AlphabetIndex(
                letters: _letters,
                activeIndex: _activeIndex,
                onHover: _onIndexHover,
                onSelected: _onIndexSelected,
              ),
              // The list needs the measured row heights, so it waits one frame
              // for them.
              Expanded(
                child: _extentsReady ? _buildList() : const SizedBox.expand(),
              ),
            ],
          ),
        ),
        if (_rows.length > 1) _buildRowSamples(),
      ],
    );
  }

  Widget _buildList() {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(
            top: _topPadding,
            bottom: _bottomPadding,
          ),
          sliver: SliverVariedExtentList(
            itemExtentBuilder: (index, _) =>
                _rows[index].isHeader ? _headerExtent : _itemExtent,
            delegate: _BrowseRowDelegate(
              itemBuilder: _buildRow,
              childCount: _rows.length,
              contentExtent: _contentExtent,
            ),
          ),
        ),
      ],
    );
  }

  /// Laid out but never painted, purely so the two row heights can be read.
  Widget _buildRowSamples() {
    return Positioned.fill(
      child: Offstage(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(_letters.first, key: _sampleHeaderKey),
            _buildItem(_rows[1].value!, key: _sampleItemKey),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final row = _rows[index];
    final letter = row.letter;
    if (letter != null) return _buildHeader(letter);
    return _buildItem(row.value!);
  }

  Widget _buildHeader(String letter, {Key? key}) {
    return Container(
      key: key,
      width: double.infinity,
      padding: _headerPadding,
      color: AppColors.lightGreen,
      child: Text(letter, style: _headerTextStyle),
    );
  }

  Widget _buildItem(String value, {Key? key}) {
    return ListTile(
      key: key,
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
        style: _itemTextStyle,
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppColors.border,
      ),
    );
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
