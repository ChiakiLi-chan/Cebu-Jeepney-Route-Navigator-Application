// lib/main.dart
//
// Only contains:
//   • MyApp         — app root, loads all routes at startup
//   • _AppShell     — bottom nav scaffold
//   • _DirectoryPage + _RoutePanel + _RouteLabel — info-only directory viewer
//
// Route Finder logic lives entirely in lib/screens/route_finder_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:thesis_app/models/log_entry.dart';
import 'package:thesis_app/data/jeepney_routes.dart';
import 'package:thesis_app/screens/route_finder.dart';
import 'package:thesis_app/screens/trip_tracker.dart';
import 'package:thesis_app/services/pdf_exporter.dart';
import 'package:thesis_app/services/jeepney_router.dart';
import 'package:thesis_app/services/walk_graph.dart';

void main() {
  runApp(const MyApp());
}

// ══════════════════════════════════════════════════════════════════════════════
// APP ROOT
// ══════════════════════════════════════════════════════════════════════════════

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final List<JeepneyRoute> _allRoutes = [];
  PrecomputedRouteGraph?   _precomputedGraph;
  WalkGraph?               _walkGraph;
  bool                     _ready = false;
  String                   _loadingStep = 'Loading routes…';

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    // ── Step 1: Load jeepney route GeoJSON files ─────────────────────────────
    _setStep('Loading jeepney routes…');
    final futures = routeRegistry.map(loadSingleRoute);
    final results = await Future.wait(futures);
    final loaded  = results.whereType<JeepneyRoute>().toList();
    _allRoutes.addAll(loaded);

    // ── Step 2: Precompute static jeepney route graph ─────────────────────────
    _setStep('Building route graph…');
    final precomputed = await compute(
      runStaticGraphIsolate,
      StaticGraphMessage(
        allRoutes:             loaded,
        transferRadiusMeters:  180,
        transferPenaltyMeters: 400,
      ),
    );

    // ── Step 3: Load and index pedestrian road graph ──────────────────────────
    _setStep('Loading road graph…');
    WalkGraph? walkGraph;
    try {
      walkGraph = await WalkGraph.loadAsset();
    } catch (_) {
      // Asset not bundled — walk routing falls back to Haversine silently.
    }

    if (mounted) {
      setState(() {
        _precomputedGraph = precomputed;
        _walkGraph        = walkGraph;
        _ready            = true;
      });
    }
  }

  void _setStep(String step) {
    if (mounted) setState(() => _loadingStep = step);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8)),
        useMaterial3: true,
      ),
      home: _ready
          ? _AppShell(
              allRoutes:        _allRoutes,
              precomputedGraph: _precomputedGraph,
              walkGraph:        _walkGraph,
            )
          : _LoadingScreen(step: _loadingStep),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// LOADING SCREEN
// ══════════════════════════════════════════════════════════════════════════════

class _LoadingScreen extends StatelessWidget {
  final String step;
  const _LoadingScreen({required this.step});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Bus icon
              Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A73E8).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.directions_bus,
                  size: 44,
                  color: Color(0xFF1A73E8),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Jeepney Route Finder',
                style: TextStyle(
                  fontSize:   22,
                  fontWeight: FontWeight.bold,
                  color:      Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Cebu City',
                style: TextStyle(
                  fontSize: 14,
                  color:    Colors.grey[500],
                ),
              ),
              const SizedBox(height: 40),
              const SizedBox(
                width: 32, height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Color(0xFF1A73E8),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                step,
                style: TextStyle(
                  fontSize: 13,
                  color:    Colors.grey[500],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// APP SHELL
// ══════════════════════════════════════════════════════════════════════════════

class _AppShell extends StatefulWidget {
  final List<JeepneyRoute>    allRoutes;
  final PrecomputedRouteGraph? precomputedGraph;
  final WalkGraph?             walkGraph;

  const _AppShell({
    required this.allRoutes,
    this.precomputedGraph,
    this.walkGraph,
  });

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  int                  _currentIndex = 0;
  final List<LogEntry>   _log          = [];
  final List<TripRecord> _trips        = [];

  void _addLog(LogEntry entry)       => setState(() => _log.add(entry));
  void _addTrip(TripRecord trip)     => setState(() => _trips.add(trip));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          // Page 0 — Route Finder
          RouteFinderPage(
            allRoutes:        widget.allRoutes,
            precomputedGraph: widget.precomputedGraph,
            walkGraph:        widget.walkGraph,
            onLog:            _addLog,
            onTripComplete:   _addTrip,
          ),
          // Page 1 — Directory
          _DirectoryPage(allRoutes: widget.allRoutes),
          // Page 2 — System Log
          _LogPage(
            entries:  _log,
            onClear:  () => setState(() => _log.clear()),
          ),
          // Page 3 — Trip Tracker
          TripTrackerPage(trips: _trips),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon:  Icon(Icons.search),
            label: 'Route Finder',
          ),
          NavigationDestination(
            icon:  Icon(Icons.directions_bus),
            label: 'Directory',
          ),
          NavigationDestination(
            icon:  Icon(Icons.terminal),
            label: 'Log',
          ),
          NavigationDestination(
            icon:  Icon(Icons.route),
            label: 'Trip Tracker',
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// DIRECTORY PAGE — read-only map viewer
// ══════════════════════════════════════════════════════════════════════════════
//
// Checkboxes only control which polylines are VISIBLE on this map.
// This selection is never read by JeepneyRouter — routing always uses all routes.

class _DirectoryPage extends StatefulWidget {
  final List<JeepneyRoute> allRoutes;
  const _DirectoryPage({required this.allRoutes});

  @override
  State<_DirectoryPage> createState() => _DirectoryPageState();
}

class _DirectoryPageState extends State<_DirectoryPage> {
  final MapController _mapController = MapController();
  bool        _panelOpen  = true;
  Set<String> _visibleIds = {};

  void _toggleVisible(String id) =>
      setState(() => _visibleIds.contains(id)
          ? _visibleIds.remove(id)
          : _visibleIds.add(id));

  void _clearAll() => setState(() => _visibleIds.clear());

  void _fitToVisible() {
    final routes = widget.allRoutes
        .where((r) => _visibleIds.contains(r.routeId))
        .toList();
    if (routes.isEmpty) return;
    final points = routes.expand((r) => r.path).toList();
    double minLat = points.first.latitude,  maxLat = points.first.latitude;
    double minLon = points.first.longitude, maxLon = points.first.longitude;
    for (final p in points) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    final span = (maxLat - minLat) > (maxLon - minLon)
        ? maxLat - minLat
        : maxLon - minLon;
    final zoom = span < 0.01 ? 15.0
               : span < 0.05 ? 13.0
               : span < 0.15 ? 12.0
               : span < 0.40 ? 11.0 : 10.0;
    _mapController.move(
        LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2), zoom);
  }

  List<Polyline> get _visiblePolylines => widget.allRoutes
      .where((r) => _visibleIds.contains(r.routeId))
      .map((r) => Polyline(
            points:      r.path,
            color:       r.color,
            strokeWidth: 5,
            strokeCap:   StrokeCap.round,
            strokeJoin:  StrokeJoin.round,
          ))
      .toList();

  List<Marker> get _terminusMarkers {
    final markers = <Marker>[];
    for (final r in widget.allRoutes) {
      if (!_visibleIds.contains(r.routeId)) continue;
      for (final pt in [r.path.first, r.path.last]) {
        markers.add(Marker(
          point: pt, width: 56, height: 24,
          child: _RouteLabel(route: r),
        ));
      }
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: LatLng(10.3157, 123.8854),
              initialZoom:   13,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://cartodb-basemaps-a.global.ssl.fastly.net/'
                    'light_all/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mapapp',
              ),
              if (_visiblePolylines.isNotEmpty)
                PolylineLayer(polylines: _visiblePolylines),
              if (_terminusMarkers.isNotEmpty)
                MarkerLayer(markers: _terminusMarkers),
            ],
          ),
          if (_visibleIds.isNotEmpty)
            Positioned(
              bottom: 16, right: 16,
              child: FloatingActionButton.small(
                heroTag:   'fit_dir',
                tooltip:   'Fit to visible routes',
                onPressed: _fitToVisible,
                child:     const Icon(Icons.fit_screen),
              ),
            ),
          Positioned(
            top: 48, left: 12, right: 12,
            child: _RoutePanel(
              isOpen:        _panelOpen,
              allRoutes:     widget.allRoutes,
              visibleIds:    _visibleIds,
              onTogglePanel: () => setState(() => _panelOpen = !_panelOpen),
              onToggleRoute: _toggleVisible,
              onClearAll:    _visibleIds.isEmpty ? null : _clearAll,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Route panel ───────────────────────────────────────────────────────────────

class _RoutePanel extends StatelessWidget {
  final bool                  isOpen;
  final List<JeepneyRoute>    allRoutes;
  final Set<String>           visibleIds;
  final VoidCallback          onTogglePanel;
  final void Function(String) onToggleRoute;
  final VoidCallback?         onClearAll;

  const _RoutePanel({
    required this.isOpen,
    required this.allRoutes,
    required this.visibleIds,
    required this.onTogglePanel,
    required this.onToggleRoute,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation:    6,
      borderRadius: BorderRadius.circular(16),
      color:        Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: isOpen
                ? const BorderRadius.vertical(top: Radius.circular(16))
                : BorderRadius.circular(16),
            onTap: onTogglePanel,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.directions_bus,
                      color: Color(0xFF1A73E8), size: 20),
                  const SizedBox(width: 10),
                  const Text('Jeepney Directory',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize:   15,
                          color:      Colors.black87)),
                  const SizedBox(width: 6),
                  if (visibleIds.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                          color:        const Color(0xFF1A73E8),
                          borderRadius: BorderRadius.circular(10)),
                      child: Text('${visibleIds.length}',
                          style: const TextStyle(
                              color:      Colors.white,
                              fontSize:   11,
                              fontWeight: FontWeight.bold)),
                    ),
                  const Spacer(),
                  if (onClearAll != null && isOpen)
                    TextButton(
                      onPressed: onClearAll,
                      style: TextButton.styleFrom(
                          padding:       EdgeInsets.zero,
                          minimumSize:   Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: const Text('Clear all',
                          style: TextStyle(
                              fontSize: 12, color: Colors.redAccent)),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    isOpen
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (isOpen) ...[
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: allRoutes.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('Loading routes…',
                                style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap:  true,
                      padding:     const EdgeInsets.symmetric(vertical: 6),
                      itemCount:   allRoutes.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 60),
                      itemBuilder: (context, i) {
                        final route     = allRoutes[i];
                        final isVisible =
                            visibleIds.contains(route.routeId);
                        return ListTile(
                          dense:   true,
                          leading: Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(
                                color: isVisible
                                    ? route.color
                                    : route.color.withOpacity(0.12),
                                shape: BoxShape.circle),
                            child: Center(
                              child: Text(route.routeId,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize:   8,
                                      fontWeight: FontWeight.bold,
                                      color: isVisible
                                          ? Colors.white
                                          : route.color)),
                            ),
                          ),
                          title: Text(route.routeName,
                              style: TextStyle(
                                  fontSize:   13,
                                  fontWeight: isVisible
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isVisible
                                      ? route.color
                                      : Colors.black87)),
                          subtitle: Text(route.routeId,
                              style: TextStyle(
                                  fontSize: 11,
                                  color:    Colors.grey[500])),
                          trailing: Checkbox(
                            value:       isVisible,
                            activeColor: route.color,
                            onChanged:
                                (_) => onToggleRoute(route.routeId),
                          ),
                          onTap: () => onToggleRoute(route.routeId),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Route terminus label marker ───────────────────────────────────────────────

class _RouteLabel extends StatelessWidget {
  final JeepneyRoute route;
  const _RouteLabel({required this.route});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
            color:        route.color,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                  color:      route.color.withOpacity(0.5),
                  blurRadius: 4,
                  offset:     const Offset(0, 2)),
            ]),
        child: Text(route.routeId,
            style: const TextStyle(
                color:         Colors.white,
                fontSize:      9,
                fontWeight:    FontWeight.bold,
                letterSpacing: 0.3)),
      );
}
// ══════════════════════════════════════════════════════════════════════════════
// LOG PAGE
// ══════════════════════════════════════════════════════════════════════════════

class _LogPage extends StatelessWidget {
  final List<LogEntry> entries;
  final VoidCallback   onClear;

  const _LogPage({required this.entries, required this.onClear});

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final reversed = entries.reversed.toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ───────────────────────────────────────────────────────
            Container(
              color:   Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
              child: Row(
                children: [
                  const Icon(Icons.terminal,
                      color: Color(0xFF1A73E8), size: 20),
                  const SizedBox(width: 10),
                  const Text('System Log',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize:   17,
                          color:      Colors.black87)),
                  const Spacer(),
                  if (entries.isNotEmpty) ...[
                    TextButton.icon(
                      onPressed: () => PdfExporter.exportLogs(entries),
                      icon:  const Icon(Icons.picture_as_pdf, size: 16),
                      label: const Text('Export',
                          style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF1A73E8)),
                    ),
                    TextButton.icon(
                      onPressed: onClear,
                      icon:  const Icon(Icons.clear_all, size: 16),
                      label: const Text('Clear',
                          style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.redAccent),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),

            // ── Entries ───────────────────────────────────────────────────────
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_outlined,
                              size: 48, color: Colors.grey),
                          SizedBox(height: 12),
                          Text('No events yet',
                              style: TextStyle(color: Colors.grey)),
                          SizedBox(height: 4),
                          Text('Search for a route to see activity here.',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding:     const EdgeInsets.all(16),
                      itemCount:   reversed.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final e = reversed[i];
                        return Container(
                          decoration: BoxDecoration(
                            color:        Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                  color:      Colors.black.withOpacity(0.05),
                                  blurRadius: 4,
                                  offset:     const Offset(0, 2)),
                            ],
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 6),
                            leading: Container(
                              width: 38, height: 38,
                              decoration: BoxDecoration(
                                  color: e.color.withOpacity(0.12),
                                  shape: BoxShape.circle),
                              child: Icon(e.icon,
                                  color: e.color, size: 18),
                            ),
                            title: Text(e.message,
                                style: const TextStyle(
                                    fontSize:   13,
                                    fontWeight: FontWeight.w600,
                                    color:      Colors.black87)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (e.detail != null) ...[
                                  const SizedBox(height: 2),
                                  Text(e.detail!,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color:    Colors.grey[600])),
                                ],
                                const SizedBox(height: 3),
                                Text(_formatTime(e.timestamp),
                                    style: TextStyle(
                                        fontSize:      10,
                                        color:         Colors.grey[400],
                                        fontFamily:    'monospace')),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}