// lib/widgets/route_finder_widgets.dart
//
// All private widget classes used by RouteFinderPage.
// Extracted to keep route_finder_page.dart focused on state logic.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:thesis_app/data/jeepney_routes.dart';
import 'package:thesis_app/services/jeepney_router.dart';
import 'package:thesis_app/models/routing_models.dart';
import 'package:thesis_app/services/fare_calculator.dart';
import 'package:thesis_app/services/location_search_service.dart';

// ══════════════════════════════════════════════════════════════════════════════
// NEARBY ROUTE RESULT  (shared between page state and NearbyRoutesPanel)
// ══════════════════════════════════════════════════════════════════════════════

class RfNearbyRouteResult {
  final JeepneyRoute route;
  final double       nearestMeters;
  const RfNearbyRouteResult({required this.route, required this.nearestMeters});
}

// ══════════════════════════════════════════════════════════════════════════════
// SEARCH PANEL  (unchanged)
// ══════════════════════════════════════════════════════════════════════════════

class RfSearchPanel extends StatelessWidget {
  final TextEditingController originCtrl;
  final TextEditingController destCtrl;
  final bool         searchingOrigin;
  final bool         searchingDest;
  final VoidCallback onSearchOrigin;
  final VoidCallback onSearchDest;
  final VoidCallback onClearOrigin;
  final VoidCallback onClearDest;
  final VoidCallback onReset;
  final FocusNode    originFocusNode;
  final FocusNode    destFocusNode;

  const RfSearchPanel({
    required this.originCtrl,
    required this.destCtrl,
    required this.searchingOrigin,
    required this.searchingDest,
    required this.onSearchOrigin,
    required this.onSearchDest,
    required this.onClearOrigin,
    required this.onClearDest,
    required this.onReset,
    required this.originFocusNode,
    required this.destFocusNode,
  });

  @override
  Widget build(BuildContext context) => Material(
        elevation:    4,
        borderRadius: BorderRadius.circular(14),
        color:        Colors.white,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            children: [
              RfSearchRow(
                controller: originCtrl,
                hint:       'Origin — e.g. SM City Cebu',
                dotColor:   const Color(0xFF34A853),
                label:      'A',
                isLoading:  searchingOrigin,
                onSubmit:   onSearchOrigin,
                onClear:    onClearOrigin,
                focusNode:  originFocusNode,
              ),
              const Divider(height: 10, thickness: 0.5),
              RfSearchRow(
                controller: destCtrl,
                hint:       'Destination — e.g. Ayala Center',
                dotColor:   const Color(0xFFEA4335),
                label:      'B',
                isLoading:  searchingDest,
                onSubmit:   onSearchDest,
                onClear:    onClearDest,
                focusNode:  destFocusNode,
              ),
            ],
          ),
        ),
      );
}

class RfSearchRow extends StatefulWidget {
  final TextEditingController controller;
  final String       hint;
  final Color        dotColor;
  final String       label;
  final bool         isLoading;
  final VoidCallback onSubmit;
  final VoidCallback onClear;
  final FocusNode?   focusNode;

  const RfSearchRow({
    required this.controller,
    required this.hint,
    required this.dotColor,
    required this.label,
    required this.isLoading,
    required this.onSubmit,
    required this.onClear,
    this.focusNode,
  });

  @override
  State<RfSearchRow> createState() => RfSearchRowState();
}

class RfSearchRowState extends State<RfSearchRow> {
  bool        _hasText   = false;
  bool        _isFocused = false;
  FocusNode?  _localFocusNode;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_localFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_onControllerChanged);
    _effectiveFocusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _effectiveFocusNode.removeListener(_onFocusChanged);
    _localFocusNode?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    final focused = _effectiveFocusNode.hasFocus;
    if (focused != _isFocused) setState(() => _isFocused = focused);
  }

  void _onControllerChanged() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _onChanged(String value) {
    final hasText = value.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    // No auto-search on type — user must press Enter or tap the search button.
  }

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 26, height: 26,
            decoration: BoxDecoration(
                color: widget.dotColor, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(widget.label,
                style: const TextStyle(
                    color:      Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize:   12)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller:  widget.controller,
              focusNode:   _effectiveFocusNode,
              decoration: InputDecoration(
                hintText:       widget.hint,
                border:         InputBorder.none,
                isDense:        true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged:   _onChanged,
              onSubmitted: (_) => widget.onSubmit(),
            ),
          ),
          if (widget.isLoading)
            const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
          else if (_isFocused && _hasText)
            // Active with text — blue search button
            IconButton(
              icon:        const Icon(Icons.search, size: 20),
              color:       const Color(0xFF1A73E8),
              onPressed:   widget.onSubmit,
              padding:     EdgeInsets.zero,
              constraints: const BoxConstraints(),
            )
          else if (!_isFocused && _hasText)
            // Inactive with text — grey clear button
            IconButton(
              icon:        const Icon(Icons.close, size: 20),
              color:       Colors.grey[500],
              onPressed:   widget.onClear,
              padding:     EdgeInsets.zero,
              constraints: const BoxConstraints(),
            )
          else
            // Empty — static grey search icon
            Icon(Icons.search, size: 20, color: Colors.grey[400]),
        ],
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// RESULTS PANEL  (unchanged)
// ══════════════════════════════════════════════════════════════════════════════

class RfResultsPanel extends StatelessWidget {
  final List<SearchResult>          results;
  final bool                        forOrigin;
  final void Function(SearchResult) onSelect;
  final VoidCallback                onDismiss;

  const RfResultsPanel({
    required this.results,
    required this.forOrigin,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final hColor =
        forOrigin ? const Color(0xFF34A853) : const Color(0xFFEA4335);
    final hLabel =
        forOrigin ? 'Set Origin (A)' : 'Set Destination (B)';

    return Material(
      elevation:    12,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      color:        Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color:        hColor,
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(hLabel,
                      style: const TextStyle(
                          color:      Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize:   12)),
                ),
                const Spacer(),
                Text(
                  '${results.length} result${results.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap:  onDismiss,
                  child:  const Icon(Icons.close, size: 20, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45),
            child: results.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No results found.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.separated(
                    shrinkWrap:  true,
                    padding:     const EdgeInsets.only(bottom: 16),
                    itemCount:   results.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 56),
                    itemBuilder: (context, i) {
                      final r   = results[i];
                      final sub = r.displayName
                          .split(', ').skip(1).take(2).join(', ');
                      final distTxt = r.distanceMeters == double.infinity
                          ? null
                          : r.distanceMeters < 1000
                              ? '${r.distanceMeters.round()} m'
                              : '${(r.distanceMeters / 1000).toStringAsFixed(1)} km';
                      return ListTile(
                        leading: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                              color: hColor.withOpacity(0.1),
                              shape: BoxShape.circle),
                          child: Icon(Icons.location_on,
                              color: hColor, size: 18),
                        ),
                        title: Text(r.shortName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: sub.isNotEmpty
                            ? Text(sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[600]))
                            : null,
                        trailing: distTxt != null
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                    color: Colors.grey[100],
                                    borderRadius: BorderRadius.circular(12)),
                                child: Text(distTxt,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color:    Colors.grey[700])))
                            : null,
                        onTap: () => onSelect(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// RECOMMENDATIONS SHEET  — horizontal carousel, collapsible
// ══════════════════════════════════════════════════════════════════════════════

class RfRecommendationsSheet extends StatefulWidget {
  final RoutingResult      result;
  final int                selectedIndex;
  final bool               isMinimized;
  final VoidCallback       onToggleMinimized;
  final void Function(int) onSelectIndex;

  const RfRecommendationsSheet({
    required this.result,
    required this.selectedIndex,
    required this.isMinimized,
    required this.onToggleMinimized,
    required this.onSelectIndex,
  });

  @override
  State<RfRecommendationsSheet> createState() => RfRecommendationsSheetState();
}

class RfRecommendationsSheetState extends State<RfRecommendationsSheet> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage:      widget.selectedIndex,
      viewportFraction: 0.88,
    );
  }

  @override
  void didUpdateWidget(RfRecommendationsSheet old) {
    super.didUpdateWidget(old);
    // Keep PageView in sync when the parent changes selectedIndex.
    if (widget.selectedIndex != old.selectedIndex &&
        _pageController.hasClients) {
      _pageController.animateToPage(
        widget.selectedIndex,
        duration: const Duration(milliseconds: 300),
        curve:    Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final success     = widget.result is RoutingSuccess
        ? widget.result as RoutingSuccess
        : null;
    final isSuccess   = success != null;
    final maxCarouselH = MediaQuery.of(context).size.height * 0.52;

    return Material(
      elevation:    16,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      color:        Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [

          // ── Handle: chevron pill (top) + centered title (below) ────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap:    widget.onToggleMinimized,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                // Chevron pill button
                AnimatedContainer(
                  duration:   const Duration(milliseconds: 250),
                  padding:    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color:        widget.isMinimized
                        ? const Color(0xFF1A73E8)
                        : Colors.grey[200],
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: AnimatedRotation(
                    turns:    widget.isMinimized ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 250),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size:  18,
                      color: widget.isMinimized ? Colors.white : Colors.grey[600],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Centered route count / status
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isSuccess) ...[
                      const Icon(Icons.directions_bus,
                          color: Color(0xFF1A73E8), size: 16),
                      const SizedBox(width: 6),
                      Text(
                        '${success!.recommendations.length} '
                        'route${success!.recommendations.length == 1 ? '' : 's'} found',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize:   14,
                            color:      Colors.black87),
                      ),
                    ] else ...[
                      const Icon(Icons.info_outline,
                          color: Colors.orange, size: 16),
                      const SizedBox(width: 6),
                      const Text('No route found',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize:   14,
                              color:      Colors.black87)),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),

          // ── Fallback banner (shown when all quality filters were suppressed) ─
          if (isSuccess && success!.isFallback)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color:        Colors.amber[50],
                  borderRadius: BorderRadius.circular(10),
                  border:       Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: Colors.amber[800]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Best available — quality filters suppressed all results',
                        style: TextStyle(
                            fontSize:   11,
                            color:      Colors.amber[900],
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Animated body (hidden when minimized) ───────────────────────────
          // Visibility(maintainState: true) keeps the Column — and the PageView
          // inside it — permanently in the widget tree. AnimatedSize sees the
          // child report Size.zero while invisible (Offstage behaviour) and
          // animates height 0 ↔ full. Because the PageView is never unmounted,
          // the PageController retains its scroll position across minimize/expand
          // cycles with no jumpToPage restoration needed.
          ClipRect(
            child: AnimatedSize(
              duration:  const Duration(milliseconds: 280),
              curve:     Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: Visibility(
                visible:       !widget.isMinimized,
                maintainState: true,
                child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Divider(height: 1),
                        const SizedBox(height: 10),
                        if (widget.result is RoutingFailure) ...[
                          RfFailureBanner(
                              failure: widget.result as RoutingFailure),
                          const SizedBox(height: 16),
                        ] else if (isSuccess) ...[
                          // Transfer badge row
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                      color: success!.hasTransfers
                                          ? Colors.purple[50]
                                          : Colors.green[50],
                                      borderRadius:
                                          BorderRadius.circular(12),
                                      border: Border.all(
                                          color: success.hasTransfers
                                              ? Colors.purple.shade200
                                              : Colors.green.shade200)),
                                  child: Text(
                                    success.hasTransfers
                                        ? 'Includes transfers'
                                        : 'No transfer',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: success.hasTransfers
                                            ? Colors.purple[700]
                                            : Colors.green[700]),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Dot indicators
                          RfCarouselDots(
                            count:         success.recommendations.length,
                            selectedIndex: widget.selectedIndex,
                          ),
                          const SizedBox(height: 6),
                          // Carousel — height tracks the tallest visible card.
                          RfAutoHeightPageView(
                            controller:       _pageController,
                            count:            success.recommendations.length,
                            maxHeight:        maxCarouselH,
                            viewportFraction: 0.88,
                            onPageChanged:    widget.onSelectIndex,
                            itemBuilder:      (_, i) => Padding(
                              padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
                              child: RfJourneyCard(
                                journey:    success.recommendations[i],
                                rank:       i + 1,
                                isSelected: i == widget.selectedIndex,
                                onTap:      () => widget.onSelectIndex(i),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
              ),    // Visibility
            ),      // AnimatedSize
          ),        // ClipRect
        ],
      ),
    );
  }
}

// ── Auto-height PageView ──────────────────────────────────────────────────────
// Measures each card's height by rendering them in an off-screen Overlay-style
// layer via a zero-size Stack with Clip.hardEdge, then drives a SizedBox-
// constrained PageView at the tallest measured height.

class RfAutoHeightPageView extends StatefulWidget {
  final PageController                     controller;
  final int                                count;
  final double                             maxHeight;
  final double                             viewportFraction;
  final void Function(int)                 onPageChanged;
  final Widget Function(BuildContext, int) itemBuilder;

  const RfAutoHeightPageView({
    required this.controller,
    required this.count,
    required this.maxHeight,
    required this.onPageChanged,
    required this.itemBuilder,
    this.viewportFraction = 0.88,
  });

  @override
  State<RfAutoHeightPageView> createState() => RfAutoHeightPageViewState();
}

class RfAutoHeightPageViewState extends State<RfAutoHeightPageView> {
  final Map<int, GlobalKey> _keys  = {};
  double                    _height = 0;

  GlobalKey _keyFor(int i) => _keys.putIfAbsent(i, GlobalKey.new);

  void _measure() {
    double max = 0;
    for (final k in _keys.values) {
      final box = k.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.size.height > max) {
        max = box.size.height;
      }
    }
    if (max > 0 && mounted && max != _height) {
      setState(() => _height = max.clamp(0.0, widget.maxHeight));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final pageWidth = constraints.maxWidth * widget.viewportFraction;

      // Schedule measurement every build.
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

      // Probe: all cards stacked at pageWidth.
      // The Stack uses Clip.hardEdge so absolutely nothing paints outside
      // the zero-height boundary — no ghost text, no bleed-through.
      final probe = Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            // Push the cards 10 000 px to the left — completely off-screen —
            // so they are laid out (allowing GlobalKey measurement) but the
            // hard-edge clip means zero pixels are ever painted on screen.
            left: -10000,
            width: pageWidth,
            top: 0,
            child: IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(widget.count, (i) => KeyedSubtree(
                  key: _keyFor(i),
                  child: widget.itemBuilder(ctx, i),
                )),
              ),
            ),
          ),
        ],
      );

      if (_height == 0) {
        // First frame: reserve no space; probe is invisible and measures.
        return SizedBox(height: 0, child: probe);
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Probe always present but zero-height so it never takes layout space.
          SizedBox(height: 0, child: probe),
          SizedBox(
            height: _height,
            child: PageView.builder(
              controller:    widget.controller,
              itemCount:     widget.count,
              onPageChanged: widget.onPageChanged,
              itemBuilder:   (c, i) => SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child:   widget.itemBuilder(c, i),
              ),
            ),
          ),
        ],
      );
    });
  }
}

// ── Carousel dot indicators ───────────────────────────────────────────────────

class RfCarouselDots extends StatelessWidget {
  final int count;
  final int selectedIndex;

  const RfCarouselDots({required this.count, required this.selectedIndex});

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isSelected = i == selectedIndex;
        return AnimatedContainer(
          duration:   const Duration(milliseconds: 200),
          margin:     const EdgeInsets.symmetric(horizontal: 3),
          width:      isSelected ? 18 : 7,
          height:     7,
          decoration: BoxDecoration(
            color:        isSelected
                ? const Color(0xFF1A73E8)
                : Colors.grey[300],
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

// ── FailureBanner  (unchanged) ───────────────────────────────────────────────

class RfFailureBanner extends StatefulWidget {
  final RoutingFailure failure;
  const RfFailureBanner({required this.failure});
  @override
  State<RfFailureBanner> createState() => RfFailureBannerState();
}

class RfFailureBannerState extends State<RfFailureBanner> {
  bool _expanded = false;

  String _fmt(double? m) {
    if (m == null) return '';
    return m < 1000
        ? '${m.round()} m away'
        : '${(m / 1000).toStringAsFixed(1)} km away';
  }

  @override
  Widget build(BuildContext context) {
    final f            = widget.failure;
    final hasBreakdown = f.rejections.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color:        Colors.orange[50],
                borderRadius: BorderRadius.circular(12),
                border:       Border.all(color: Colors.orange.shade200)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, color: Colors.orange, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(f.reason,
                      style: TextStyle(fontSize: 13, color: Colors.orange[900])),
                ),
              ],
            ),
          ),

          if (hasBreakdown) ...[
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                    color:        Colors.grey[100],
                    borderRadius: BorderRadius.circular(10)),
                child: Row(
                  children: [
                    const Icon(Icons.bug_report_outlined,
                        size: 16, color: Colors.grey),
                    const SizedBox(width: 8),
                    Text(
                      'Why ${f.rejections.length} '
                      'route${f.rejections.length == 1 ? '' : 's'} failed',
                      style: const TextStyle(
                          fontSize:   13,
                          fontWeight: FontWeight.w600,
                          color:      Colors.black87),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 18, color: Colors.grey,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: [
                if (f.countOriginTooFar > 0)
                  RfGateChip(
                    icon:  Icons.near_me_disabled,
                    label: '${f.countOriginTooFar} origin too far',
                    color: Colors.red,
                    hint:  f.closestOriginMiss?.nearestOriginMeters != null
                        ? 'Closest: ${_fmt(f.closestOriginMiss!.nearestOriginMeters)}'
                        : null,
                  ),
                if (f.countDestTooFar > 0)
                  RfGateChip(
                    icon:  Icons.location_off,
                    label: '${f.countDestTooFar} dest too far',
                    color: Colors.deepOrange,
                    hint:  f.closestDestMiss?.nearestDestMeters != null
                        ? 'Closest: ${_fmt(f.closestDestMiss!.nearestDestMeters)}'
                        : null,
                  ),
                if (f.countWrongDirection > 0)
                  RfGateChip(
                    icon:  Icons.swap_horiz,
                    label: '${f.countWrongDirection} wrong direction',
                    color: Colors.purple,
                  ),
                if (f.countRideTooShort > 0)
                  RfGateChip(
                    icon:  Icons.straighten,
                    label: '${f.countRideTooShort} ride too short',
                    color: Colors.blueGrey,
                  ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                    border:       Border.all(color: Colors.grey.shade200),
                    borderRadius: BorderRadius.circular(10)),
                child: ListView.separated(
                  shrinkWrap:  true,
                  physics:     const NeverScrollableScrollPhysics(),
                  padding:     const EdgeInsets.symmetric(vertical: 4),
                  itemCount:   f.rejections.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 48),
                  itemBuilder: (_, i) {
                    final r = f.rejections[i];
                    return ListTile(
                      dense:   true,
                      leading: Container(
                        width: 30, height: 30,
                        decoration: BoxDecoration(
                            color: r.route.color.withOpacity(0.15),
                            shape: BoxShape.circle),
                        child: Center(
                          child: Text(r.route.routeId,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize:   7,
                                  fontWeight: FontWeight.bold,
                                  color:      r.route.color)),
                        ),
                      ),
                      title: Text(r.route.routeName,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w500)),
                      subtitle: Text(r.detail,
                          style: TextStyle(
                              fontSize: 11, color: _gateColor(r.gate))),
                      trailing: Icon(_gateIcon(r.gate),
                          size: 14, color: _gateColor(r.gate)),
                    );
                  },
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Color _gateColor(RejectionGate gate) {
    switch (gate) {
      case RejectionGate.originTooFar:   return Colors.red;
      case RejectionGate.destTooFar:     return Colors.deepOrange;
      case RejectionGate.wrongDirection: return Colors.purple;
      case RejectionGate.rideTooShort:   return Colors.blueGrey;
    }
  }

  IconData _gateIcon(RejectionGate gate) {
    switch (gate) {
      case RejectionGate.originTooFar:   return Icons.near_me_disabled;
      case RejectionGate.destTooFar:     return Icons.location_off;
      case RejectionGate.wrongDirection: return Icons.swap_horiz;
      case RejectionGate.rideTooShort:   return Icons.straighten;
    }
  }
}

// ── Gate chip  (unchanged) ────────────────────────────────────────────────────

class RfGateChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  final String?  hint;

  const RfGateChip({
    required this.icon,
    required this.label,
    required this.color,
    this.hint,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
            color:        color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border:       Border.all(color: color.withOpacity(0.25))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize:   11,
                        color:      color,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint!,
                  style: TextStyle(
                      fontSize: 10, color: color.withOpacity(0.75))),
            ],
          ],
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// JOURNEY CARD  (replaces _RecommendationCard; handles 1..N segments)
// ══════════════════════════════════════════════════════════════════════════════

class RfJourneyCard extends StatelessWidget {
  final RouteJourney journey;
  final int          rank;
  final bool         isSelected;
  final VoidCallback onTap;

  const RfJourneyCard({
    required this.journey,
    required this.rank,
    required this.isSelected,
    required this.onTap,
  });

  String _fmt(double m) =>
      m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  String _fmtMin(double mins) =>
      mins < 60
          ? '~${mins.round()} min'
          : '~${(mins / 60).toStringAsFixed(1)} hr';

  // Use the first segment's route colour as the card accent.
  Color get _accentColor => journey.segments.first.route.color;

  @override
  Widget build(BuildContext context) {
    final color   = _accentColor;
    final isDirect = journey.isDirect;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration:   const Duration(milliseconds: 200),
        margin:     const EdgeInsets.symmetric(vertical: 5),
        padding:    const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        isSelected ? color.withOpacity(0.06) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(
              color: isSelected ? color : Colors.grey.shade200,
              width: isSelected ? 2 : 1),
          boxShadow: isSelected
              ? [BoxShadow(
                  color:      color.withOpacity(0.15),
                  blurRadius: 8,
                  offset:     const Offset(0, 3))]
              : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Header row: rank badge, route circles, walk + time summary ──
            Row(
              children: [
                if (rank == 1) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color:        Colors.amber[700],
                        borderRadius: BorderRadius.circular(6)),
                    child: const Text('Best',
                        style: TextStyle(
                            color:      Colors.white,
                            fontSize:   10,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 6),
                ],

                // Route circle(s) — stacked slightly for multi-segment
                SizedBox(
                  width: journey.segments.length == 1 ? 38 : 54,
                  height: 38,
                  child: Stack(
                    children: [
                      for (int i = 0; i < journey.segments.length && i < 3; i++)
                        Positioned(
                          left: i * 16.0,
                          child: RfRouteCircle(
                              route: journey.segments[i].route, size: 36),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // Route name(s)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        journey.segments.map((s) => s.route.routeId).join(' + '),
                        maxLines:  1,
                        overflow:  TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Text(
                        journey.segments.map((s) => s.route.routeName).join(' → '),
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),

                // Total walk badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color:        color.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(20),
                      border:       Border.all(color: color.withOpacity(0.3))),
                  child: Text(
                    '${_fmt(journey.totalWalkingMeters)} walk',
                    style: TextStyle(
                        fontSize:   11,
                        color:      color,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // ── Transfer badge (only for multi-route journeys) ───────────────
            if (!isDirect) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color:        Colors.purple[50],
                    borderRadius: BorderRadius.circular(8),
                    border:       Border.all(color: Colors.purple.shade200)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.transfer_within_a_station,
                        size: 13, color: Colors.purple[700]),
                    const SizedBox(width: 4),
                    Text(
                      '${journey.transferCount} transfer'
                      '${journey.transferCount > 1 ? 's' : ''}',
                      style: TextStyle(
                          fontSize:   11,
                          color:      Colors.purple[700],
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ── Per-segment board/alight details ────────────────────────────
            ...List.generate(journey.segments.length, (i) {
              final seg = journey.segments[i];
              return Padding(
                padding: EdgeInsets.only(bottom: i < journey.segments.length - 1 ? 6 : 0),
                child: Row(
                  children: [
                    Expanded(
                      child: RfStopDetail(
                        icon:      Icons.directions_walk,
                        iconColor: const Color(0xFF34A853),
                        label:     journey.segments.length > 1
                            ? 'Board ${i + 1} (${seg.route.routeId})'
                            : 'Board here',
                        detail:    '${_fmt(seg.walkToBoardingMeters)} walk',
                        coords:    seg.boardingPoint,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward,
                          color: seg.route.color, size: 16),
                    ),
                    Expanded(
                      child: RfStopDetail(
                        icon:      Icons.place,
                        iconColor: const Color(0xFFEA4335),
                        label:     journey.segments.length > 1
                            ? 'Alight ${i + 1}'
                            : 'Alight here',
                        detail:    i < journey.segments.length - 1
                            ? '${_fmt(seg.walkFromDropoffMeters)} to transfer'
                            : '${_fmt(seg.walkFromDropoffMeters)} to dest',
                        coords:    seg.dropoffPoint,
                      ),
                    ),
                  ],
                ),
              );
            }),

            const SizedBox(height: 10),

            // ── Summary chips ────────────────────────────────────────────────
            Wrap(
              spacing: 6, runSpacing: 4,
              children: [
                RfRouteChip(Icons.access_time,
                    _fmtMin(journey.estimatedJourneyMinutes), color),
                RfRouteChip(Icons.directions_walk,
                    '${_fmt(journey.totalWalkingMeters)} total walk',
                    Colors.grey[600]!),
              ],
            ),

            const SizedBox(height: 10),

            // ── Fare breakdown ───────────────────────────────────────────────
            RfFareCard(journey: journey),
          ],
        ),
      ),
    );
  }
}

// ── Fare breakdown card ──────────────────────────────────────────────────────

class RfFareCard extends StatefulWidget {
  final RouteJourney journey;
  const RfFareCard({required this.journey});

  @override
  State<RfFareCard> createState() => RfFareCardState();
}

class RfFareCardState extends State<RfFareCard> {
  bool _studentMode = false;

  // Build the toggle button used in the header
  Widget _buildToggle() => Material(
    color:        Colors.transparent,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _studentMode = !_studentMode),
      child: AnimatedContainer(
        duration:   const Duration(milliseconds: 200),
        padding:    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _studentMode ? const Color(0xFF1A73E8) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF1A73E8), width: 1.5),
          boxShadow: _studentMode ? [
            BoxShadow(
              color:      const Color(0xFF1A73E8).withOpacity(0.3),
              blurRadius: 6, offset: const Offset(0, 2)),
          ] : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.school_rounded, size: 13,
                color: _studentMode ? Colors.white : const Color(0xFF1A73E8)),
            const SizedBox(width: 5),
            Text('Student 20%',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold,
                    color: _studentMode ? Colors.white : const Color(0xFF1A73E8))),
            const SizedBox(width: 4),
            Icon(
              _studentMode ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 12,
              color: _studentMode ? Colors.white : const Color(0xFF1A73E8),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final segs      = widget.journey.segments;
    final isMulti   = segs.length > 1;

    // Per-segment fares (both types) — used for multi-route breakdown
    final segTrad   = segs.map((s) =>
        FareCalculator.regular(s.rideDistanceMeters, isModern: false)).toList();
    final segModern = segs.map((s) =>
        FareCalculator.regular(s.rideDistanceMeters, isModern: true)).toList();

    final totalTrad   = segTrad.fold(0.0,   (a, b) => a + b);
    final totalModern = segModern.fold(0.0, (a, b) => a + b);

    return Container(
      padding:    const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: const Color(0xFFFFE082)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Header + toggle ───────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.payments_outlined,
                  size: 14, color: Color(0xFFF9A825)),
              const SizedBox(width: 6),
              const Text('Fare Estimate',
                  style: TextStyle(
                      fontSize:   12,
                      fontWeight: FontWeight.bold,
                      color:      Color(0xFFF9A825))),
              const Spacer(),
              _buildToggle(),
            ],
          ),

          const SizedBox(height: 10),

          // ── Multi-route: per-segment breakdown ────────────────────────────
          if (isMulti) ...[
            for (int i = 0; i < segs.length; i++) ...[
              // Segment label
              Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                        color: segs[i].route.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text('Jeepney ${i + 1} — ${segs[i].route.routeId}',
                      style: const TextStyle(
                          fontSize:   11,
                          fontWeight: FontWeight.w600,
                          color:      Colors.black87)),
                ],
              ),
              const SizedBox(height: 5),
              // Traditional + Modern for this segment
              Row(
                children: [
                  const SizedBox(width: 14),
                  Expanded(
                    child: RfFareRow(
                      label:       'Traditional',
                      fare:         _studentMode
                          ? FareCalculator.student(segTrad[i])
                          : segTrad[i],
                      regularFare:  segTrad[i],
                      isStudent:    _studentMode,
                      accentColor:  const Color(0xFF6D4C41),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 14),
                  Expanded(
                    child: RfFareRow(
                      label:       'Modern',
                      fare:         _studentMode
                          ? FareCalculator.student(segModern[i])
                          : segModern[i],
                      regularFare:  segModern[i],
                      isStudent:    _studentMode,
                      accentColor:  const Color(0xFF1A73E8),
                    ),
                  ),
                ],
              ),
              if (i < segs.length - 1)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Divider(height: 1, thickness: 0.5),
                )
              else
                const SizedBox(height: 8),
            ],

            // Total row
            Container(
              padding:    const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color:        Colors.amber[50],
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: Colors.amber.shade200),
              ),
              child: Column(
                children: [
                  RfFareRow(
                    label:       'Total — Traditional',
                    fare:         _studentMode
                        ? FareCalculator.student(totalTrad)
                        : totalTrad,
                    regularFare:  totalTrad,
                    isStudent:    _studentMode,
                    accentColor:  const Color(0xFF6D4C41),
                  ),
                  const SizedBox(height: 4),
                  RfFareRow(
                    label:       'Total — Modern',
                    fare:         _studentMode
                        ? FareCalculator.student(totalModern)
                        : totalModern,
                    regularFare:  totalModern,
                    isStudent:    _studentMode,
                    accentColor:  const Color(0xFF1A73E8),
                  ),
                ],
              ),
            ),

          ] else ...[

            // ── Single-route: just Traditional + Modern ───────────────────
            RfFareRow(
              label:       'Traditional',
              fare:         _studentMode
                  ? FareCalculator.student(totalTrad)
                  : totalTrad,
              regularFare:  totalTrad,
              isStudent:    _studentMode,
              accentColor:  const Color(0xFF6D4C41),
            ),
            const SizedBox(height: 6),
            RfFareRow(
              label:       'Modern',
              fare:         _studentMode
                  ? FareCalculator.student(totalModern)
                  : totalModern,
              regularFare:  totalModern,
              isStudent:    _studentMode,
              accentColor:  const Color(0xFF1A73E8),
            ),
          ],
        ],
      ),
    );
  }
}

class RfFareRow extends StatelessWidget {
  final String label;
  final double fare;
  final double regularFare;
  final bool   isStudent;
  final Color  accentColor;

  const RfFareRow({
    required this.label,
    required this.fare,
    required this.regularFare,
    required this.isStudent,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      // Type label badge
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color:        accentColor.withOpacity(0.10),
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(color: accentColor.withOpacity(0.35)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize:   11,
                fontWeight: FontWeight.w600,
                color:      accentColor)),
      ),
      const Spacer(),
      // Fare amount — with crossed-out regular when in student mode
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(FareCalculator.format(fare),
              style: TextStyle(
                  fontSize:   13,
                  fontWeight: FontWeight.bold,
                  color:      isStudent
                      ? const Color(0xFF1A73E8)
                      : Colors.black87)),
          if (isStudent)
            Text(FareCalculator.format(regularFare),
                style: TextStyle(
                    fontSize:   10,
                    color:      Colors.grey[500],
                    decoration: TextDecoration.lineThrough)),
        ],
      ),
    ],
  );
}

// ── Small route circle avatar used in the card header ─────────────────────────

class RfRouteCircle extends StatelessWidget {
  final JeepneyRoute route;
  final double       size;
  const RfRouteCircle({required this.route, required this.size});

  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
            color:  route.color,
            shape:  BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color:      route.color.withOpacity(0.4),
                  blurRadius: 6,
                  offset:     const Offset(0, 2))
            ]),
        alignment: Alignment.center,
        child: Text(route.routeId,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color:      Colors.white,
                fontSize:   7,
                fontWeight: FontWeight.bold)),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// SHARED SMALL WIDGETS  (unchanged)
// ══════════════════════════════════════════════════════════════════════════════

class RfStopDetail extends StatelessWidget {
  final IconData icon;
  final Color    iconColor;
  final String   label;
  final String   detail;
  final LatLng   coords;
  const RfStopDetail({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.detail,
    required this.coords,
  });
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color:        iconColor.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(color: iconColor.withOpacity(0.20))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor, size: 15),
            const SizedBox(width: 5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 11)),
                  Text(detail,
                      style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                  Text(
                    '${coords.latitude.toStringAsFixed(4)}, '
                    '${coords.longitude.toStringAsFixed(4)}',
                    style: TextStyle(fontSize: 9, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class RfRouteChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const RfRouteChip(this.icon, this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
            color:        Colors.grey[100],
            borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize:   11,
                    color:      Colors.grey[700],
                    fontWeight: FontWeight.w500)),
          ],
        ),
      );
}

class RfHintCard extends StatelessWidget {
  final String text;
  const RfHintCard({required this.text});
  @override
  Widget build(BuildContext context) => Material(
        elevation:    4,
        borderRadius: BorderRadius.circular(14),
        color:        Colors.white,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text,
                    style: TextStyle(fontSize: 13, color: Colors.grey[600])),
              ),
            ],
          ),
        ),
      );
}

class RfMarkerPin extends StatelessWidget {
  final Color  color;
  final String label;
  const RfMarkerPin({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color:  color,
              shape:  BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                    color:      color.withOpacity(0.5),
                    blurRadius: 6,
                    offset:     const Offset(0, 3)),
              ],
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: const TextStyle(
                    color:      Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize:   12)),
          ),
          Transform.rotate(
            angle: 0.7854,
            child: Container(width: 9, height: 9, color: color),
          ),
        ],
      );
}

class RfStopMarker extends StatelessWidget {
  final String label;
  final Color  color;
  const RfStopMarker({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color:        color,
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                    color:      color.withOpacity(0.5),
                    blurRadius: 4,
                    offset:     const Offset(0, 2)),
              ],
            ),
            child: Text(label,
                style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   9,
                    fontWeight: FontWeight.bold)),
          ),
          Transform.rotate(
            angle: 0.7854,
            child: Container(width: 8, height: 8, color: color),
          ),
        ],
      );
}

// ── User location marker — pulsing blue dot ───────────────────────────────────

class RfUserLocationMarker extends StatefulWidget {
  const RfUserLocationMarker();

  @override
  State<RfUserLocationMarker> createState() => RfUserLocationMarkerState();
}

class RfUserLocationMarkerState extends State<RfUserLocationMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double>    _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _pulse = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static const _blue = Color(0xFF4285F4);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) => Stack(
          alignment: Alignment.center,
          children: [
            // Expanding pulse ring
            Container(
              width:  44 * _pulse.value,
              height: 44 * _pulse.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _blue.withOpacity(0.18 * (1 - _pulse.value)),
              ),
            ),
            // Static accuracy halo
            Container(
              width:  22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _blue.withOpacity(0.15),
                border: Border.all(color: _blue.withOpacity(0.3), width: 1),
              ),
            ),
            // Blue dot
            Container(
              width:  12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _blue,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color:      _blue.withOpacity(0.45),
                    blurRadius: 6,
                    offset:     const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
// ══════════════════════════════════════════════════════════════════════════════
// NEARBY ROUTES PANEL
// ══════════════════════════════════════════════════════════════════════════════

class RfNearbyRoutesPanel extends StatelessWidget {
  final List<RfNearbyRouteResult> results;
  final bool                     forOrigin;
  final String?                  selectedRouteId;
  final void Function(String)    onToggleRoute;

  const RfNearbyRoutesPanel({
    required this.results,
    required this.forOrigin,
    required this.selectedRouteId,
    required this.onToggleRoute,
  });

  String _fmtDist(double m) => m < 1000
      ? '${m.round()} m'
      : '${(m / 1000).toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext context) {
    final withinRadius = results.every((r) => r.nearestMeters <= 500);
    final pointLabel   = forOrigin ? 'origin' : 'destination';

    return Material(
      elevation:    4,
      borderRadius: BorderRadius.circular(14),
      color:        Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.directions_bus,
                    size: 15, color: Color(0xFF1A73E8)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    withinRadius
                        ? '${results.length} route${results.length == 1 ? '' : 's'} '
                          'near your $pointLabel'
                        : 'Closest route to your $pointLabel',
                    style: const TextStyle(
                        fontSize:   13,
                        fontWeight: FontWeight.bold,
                        color:      Colors.black87),
                  ),
                ),
                if (selectedRouteId != null)
                  GestureDetector(
                    onTap: () => onToggleRoute(selectedRouteId!),
                    child: Text('Show all',
                        style: TextStyle(
                            fontSize:   11,
                            color:      Colors.grey[500],
                            decoration: TextDecoration.underline)),
                  ),
              ],
            ),

            if (!withinRadius)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  'No routes within 500 m — showing nearest',
                  style: TextStyle(fontSize: 11, color: Colors.orange[700]),
                ),
              ),

            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),

            // Route rows
            ...results.map((r) {
              final isSelected   = selectedRouteId == r.route.routeId;
              final isDimmed     = selectedRouteId != null && !isSelected;
              final routeColor   = r.route.color;

              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  color:        isSelected
                      ? routeColor.withOpacity(0.07)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap:        () => onToggleRoute(r.route.routeId),
                    child: AnimatedContainer(
                      duration:   const Duration(milliseconds: 180),
                      padding:    const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 7),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: isSelected
                            ? Border.all(
                                color: routeColor.withOpacity(0.5), width: 1.5)
                            : null,
                      ),
                      child: Row(
                        children: [
                          // Route circle
                          AnimatedOpacity(
                            opacity:  isDimmed ? 0.3 : 1.0,
                            duration: const Duration(milliseconds: 180),
                            child: Container(
                              width: 34, height: 34,
                              decoration: BoxDecoration(
                                  color: routeColor, shape: BoxShape.circle),
                              alignment: Alignment.center,
                              child: Text(r.route.routeId,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color:      Colors.white,
                                      fontSize:   7,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Route info
                          Expanded(
                            child: AnimatedOpacity(
                              opacity:  isDimmed ? 0.35 : 1.0,
                              duration: const Duration(milliseconds: 180),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.route.routeId,
                                      style: TextStyle(
                                          fontSize:   12,
                                          fontWeight: FontWeight.bold,
                                          color:      isSelected
                                              ? routeColor
                                              : Colors.black87)),
                                  Text(r.route.routeName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color:    Colors.grey[600])),
                                ],
                              ),
                            ),
                          ),
                          // Distance badge
                          AnimatedOpacity(
                            opacity:  isDimmed ? 0.35 : 1.0,
                            duration: const Duration(milliseconds: 180),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color:        r.nearestMeters <= 500
                                    ? routeColor.withOpacity(0.10)
                                    : Colors.orange[50],
                                borderRadius: BorderRadius.circular(8),
                                border:       Border.all(
                                  color: r.nearestMeters <= 500
                                      ? routeColor.withOpacity(0.35)
                                      : Colors.orange.shade200,
                                ),
                              ),
                              child: Text(
                                _fmtDist(r.nearestMeters),
                                style: TextStyle(
                                    fontSize:   10,
                                    fontWeight: FontWeight.w600,
                                    color:      r.nearestMeters <= 500
                                        ? routeColor
                                        : Colors.orange[700]),
                              ),
                            ),
                          ),
                          // Selection indicator
                          const SizedBox(width: 6),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: isSelected
                                ? Icon(Icons.check_circle,
                                    key:   const ValueKey('checked'),
                                    size:  16,
                                    color: routeColor)
                                : Icon(Icons.radio_button_unchecked,
                                    key:   const ValueKey('unchecked'),
                                    size:  16,
                                    color: Colors.grey[300]),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MAP PIN WIDGET  (centred crosshair shown in pin mode)
// ══════════════════════════════════════════════════════════════════════════════

class RfMapPinWidget extends StatelessWidget {
  final bool forOrigin;
  const RfMapPinWidget({required this.forOrigin});

  @override
  Widget build(BuildContext context) {
    final color = forOrigin
        ? const Color(0xFF34A853)
        : const Color(0xFFEA4335);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pin head
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color:  color,
            shape:  BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color:      color.withOpacity(0.5),
                blurRadius: 10,
                offset:     const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            forOrigin ? Icons.trip_origin : Icons.place,
            color: Colors.white,
            size:  18,
          ),
        ),
        // Pin tail
        Transform.rotate(
          angle: 0.7854,
          child: Container(
            width: 12, height: 12,
            color: color,
          ),
        ),
        // Shadow dot on the "ground"
        Container(
          width: 10, height: 4,
          decoration: BoxDecoration(
            color:        Colors.black.withOpacity(0.18),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ],
    );
  }
}