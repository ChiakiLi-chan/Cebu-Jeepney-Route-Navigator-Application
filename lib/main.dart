import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import 'package:thesis_app/data/jeepney_routes.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8)),
        useMaterial3: true,
      ),
      home: const MapPage(),
    );
  }
}

// ─── Selection State ───────────────────────────────────────────────────────────
// Tracks which point the user is currently setting.
enum SelectionMode { origin, destination }

// ─── Search Result Model ───────────────────────────────────────────────────────
// Pairs a Nominatim result with its pre-computed distance from the user.
class _SearchResult {
  final String displayName;
  final LatLng point;
  final double distanceMeters; // double.infinity when user location unknown

  const _SearchResult({
    required this.displayName,
    required this.point,
    required this.distanceMeters,
  });
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  // ── Map controller ────────────────────────────────────────────────────────
  final MapController _mapController = MapController();

  // ── Search controllers (one per field) ────────────────────────────────────
  final TextEditingController _originController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  // ── Core state: two nullable points ───────────────────────────────────────
  LatLng? origin;
  LatLng? destination;

  // ── Which point gets set next when the user taps the map ──────────────────
  SelectionMode _selectionMode = SelectionMode.origin;

  // ── Loading flags ─────────────────────────────────────────────────────────
  bool _searchingOrigin = false;
  bool _searchingDestination = false;

  // ── GPS: cached once on startup, reused for all distance calculations ─────
  LatLng? _userLocation;

  // ── Search results panel state ────────────────────────────────────────────
  List<_SearchResult> _searchResults = [];   // current results list
  bool _showResults = false;                 // whether panel is visible
  bool? _pendingForOrigin;                   // which field triggered the search

  @override
  void initState() {
    super.initState();
    _fetchUserLocation(); // non-blocking background warm-up
  }

  // ── GPS: request permission and cache current position ───────────────────
  Future<void> _fetchUserLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      debugPrint('[GPS] Permission denied — distance ranking skipped');
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
      setState(() {
        _userLocation = LatLng(pos.latitude, pos.longitude);
      });
      debugPrint('[GPS] User location: ${pos.latitude}, ${pos.longitude}');
    } catch (e) {
      debugPrint('[GPS] Error: $e');
    }
  }

  // ── Cebu bounding box ─────────────────────────────────────────────────────
  // Covers the entire Cebu island + nearby metros (Mandaue, Lapu-Lapu, Talisay)
  // viewbox = left (min lon), top (max lat), right (max lon), bottom (min lat)
  static const double _cebuMinLon = 123.65;
  static const double _cebuMaxLon = 124.10;
  static const double _cebuMinLat = 9.90;
  static const double _cebuMaxLat = 10.75;

  // OSM types that are real named places (not address-matched POIs)
  static const _allowedTypes = {
    'mall', 'commercial', 'retail', 'supermarket',
    'hospital', 'clinic', 'school', 'university', 'college',
    'hotel', 'restaurant', 'cafe', 'bar', 'fast_food',
    'park', 'beach', 'island', 'bay',
    'bus_station', 'ferry_terminal', 'airport',
    'place_of_worship', 'church',
    'government', 'public_building', 'townhall',
    'neighbourhood', 'suburb', 'village', 'town', 'city',
    'road', 'street',
  };

  // ── Relevance scorer ──────────────────────────────────────────────────────
  // Compares the search query against the first segment of a Nominatim
  // display_name (the actual place name, before the first comma).
  //
  //  Score 5 — name equals query exactly           "Ayala" → "Ayala"
  //  Score 4 — name starts with query              "Ayala" → "Ayala Center Cebu"
  //  Score 3 — name contains query as a whole word "Ayala" → "Ayala IT Park"
  //            (query appears at a word boundary, not buried mid-word)
  //  Score 2 — name contains query anywhere        "Ayala" → "BPI Ayala Center"
  //  Score 1 — fallback / address-matched noise    "Ayala" → "SB Finance, Ayala Ave"
  int _relevanceScore(String displayName, String query) {
    final name = displayName.split(',').first.trim().toLowerCase();
    final q    = query.trim().toLowerCase();

    if (name == q)          return 5;
    if (name.startsWith(q)) return 4;

    // Score 3: query appears at a word boundary inside the name.
    // "ayala it park" contains "ayala" at index 0 → word boundary ✓
    // "bpi ayala center" contains "ayala" after a space → word boundary ✓
    // This lets "Ayala IT Park" outscore "BPI Ayala Center" when both
    // contain the query, by checking if the match starts at a word boundary.
    if (name.contains(q)) {
      final idx = name.indexOf(q);
      final atWordBoundary = idx == 0 || name[idx - 1] == ' ';
      if (atWordBoundary) return 3;
      return 2;
    }

    return 1;
  }

  // ── Fetch up to 10 Nominatim results bounded to Cebu, ranked by distance ──
  Future<List<_SearchResult>> _searchMultiple(String query) async {
    if (query.trim().isEmpty) return [];

    final encoded = Uri.encodeComponent(query);

    // bounded=1  → ONLY return results inside the viewbox (hard filter)
    // viewbox    → Cebu island bounding box
    // addressdetails=1 → include address breakdown so we can read the type
    // limit=10   → fetch more candidates before filtering
    final url = 'https://nominatim.openstreetmap.org/search'
        '?q=$encoded'
        '&format=json'
        '&limit=10'
        '&bounded=1'
        '&viewbox=$_cebuMinLon,$_cebuMaxLat,$_cebuMaxLon,$_cebuMinLat'
        '&addressdetails=1';

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'FlutterMapNavApp/1.0'},
      );
      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body) as List;
      if (data.isEmpty) return [];

      const distanceCalc = Distance();

      final results = data
          .where((item) {
            // ── Type filter: skip results whose OSM type is too generic ──
            // `type` is the OSM tag value (e.g. "mall", "bank", "address")
            final type = (item['type'] as String? ?? '').toLowerCase();
            final cls  = (item['class'] as String? ?? '').toLowerCase();

            // Always block pure address matches — these are the "BPI on
            // Ayala Ave" false positives. Their class is "place" and type
            // is "house" or "building", OR class is "highway" subtype.
            if (type == 'house' || type == 'building') return false;

            // Keep anything in our allowed set, OR any amenity/shop/tourism
            if (_allowedTypes.contains(type)) return true;
            if (cls == 'amenity' || cls == 'shop' || cls == 'tourism') {
              return true;
            }
            if (cls == 'place' || cls == 'boundary') return true;
            if (cls == 'highway' && _allowedTypes.contains(type)) return true;

            // Let everything else through — better to show extra than miss
            return true;
          })
          .map((item) {
            final point = LatLng(
              double.parse(item['lat'] as String),
              double.parse(item['lon'] as String),
            );
            final distMeters = _userLocation != null
                ? distanceCalc.as(LengthUnit.Meter, _userLocation!, point)
                : double.infinity;

            return _SearchResult(
              displayName: item['display_name'] as String,
              point: point,
              distanceMeters: distMeters,
            );
          })
          .toList();

      // ── Relevance-first, distance-second sort ───────────────────────────
      // PRIMARY:   relevance score descending (4 → 1)
      // SECONDARY: distance ascending (closer is better)
      results.sort((a, b) {
        final scoreA = _relevanceScore(a.displayName, query);
        final scoreB = _relevanceScore(b.displayName, query);

        if (scoreB != scoreA) return scoreB.compareTo(scoreA); // higher = better

        // Tie-break by distance (infinity sorts last)
        return a.distanceMeters.compareTo(b.distanceMeters);
      });

      // Debug: log all results with score + distance
      debugPrint('[SEARCH] Ranked results for "$query":');
      for (int i = 0; i < results.length; i++) {
        final r    = results[i];
        final score = _relevanceScore(r.displayName, query);
        final dist  = r.distanceMeters == double.infinity
            ? 'no GPS'
            : '${(r.distanceMeters / 1000).toStringAsFixed(2)} km';
        debugPrint('  [${i + 1}] score=$score  $dist  ${r.displayName.split(',').first}');
      }

      return results;
    } catch (e) {
      debugPrint('[SEARCH] Error: $e');
      return [];
    }
  }

  // ── Execute smart search → populate results panel (no auto-select) ────────
  Future<void> _onSmartSearch({required bool forOrigin}) async {
    if (_userLocation == null) await _fetchUserLocation();

    final query =
        forOrigin ? _originController.text : _destinationController.text;

    setState(() {
      if (forOrigin) _searchingOrigin = true;
      else _searchingDestination = true;
      _showResults = false;   // hide stale results while loading
      _searchResults = [];
    });

    final results = await _searchMultiple(query);

    setState(() {
      if (forOrigin) _searchingOrigin = false;
      else _searchingDestination = false;
      _searchResults = results;
      _pendingForOrigin = forOrigin;
      _showResults = true;    // show panel — user picks from here
    });

    if (results.isEmpty) {
      _showSnack('No results found for "$query"');
    }
  }

  // ── Called when user taps a result in the panel ───────────────────────────
  void _onResultSelected(_SearchResult result) {
    final forOrigin = _pendingForOrigin ?? true;

    setState(() {
      if (forOrigin) {
        origin = result.point;
      } else {
        destination = result.point;
      }
      _showResults = false;   // close panel
      _searchResults = [];
      _pendingForOrigin = null;
    });

    _mapController.move(result.point, 15);

    // Update the text field to show what was chosen
    final shortName = result.displayName.split(',').first;
    if (forOrigin) {
      _originController.text = shortName;
    } else {
      _destinationController.text = shortName;
    }
  }

  // ── Dismiss the results panel without selecting ───────────────────────────
  void _dismissResults() {
    setState(() {
      _showResults = false;
      _searchResults = [];
      _pendingForOrigin = null;
    });
  }

  // ── Search callbacks wired to the top panel ───────────────────────────────
  Future<void> _onSearchOrigin() => _onSmartSearch(forOrigin: true);
  Future<void> _onSearchDestination() => _onSmartSearch(forOrigin: false);

  // ── Handle map tap ────────────────────────────────────────────────────────
  // Tap cycle: no points → set origin → set destination → reset all
  void _onMapTap(TapPosition tapPosition, LatLng point) {
    setState(() {
      if (origin == null) {
        // First tap: set origin
        origin = point;
        _selectionMode = SelectionMode.destination;
      } else if (destination == null) {
        // Second tap: set destination
        destination = point;
        _selectionMode = SelectionMode.origin; // ready for next reset cycle
      } else {
        // Third tap: reset everything
        _resetAll();
      }
    });
  }

  // ── Reset all state ───────────────────────────────────────────────────────
  void _resetAll() {
    setState(() {
      origin = null;
      destination = null;
      _selectionMode = SelectionMode.origin;
      _originController.clear();
      _destinationController.clear();
      _showResults = false;
      _searchResults = [];
      _pendingForOrigin = null;
    });
  }

  // ── Build marker list from current state ──────────────────────────────────
  // Instead of maintaining a separate List<Marker>, we derive it directly
  // from `origin` and `destination`. This is the "single source of truth"
  // pattern: UI reflects state, not the other way around.
  List<Marker> get _markers {
    final list = <Marker>[];

    if (origin != null) {
      list.add(Marker(
        point: origin!,
        width: 44,
        height: 44,
        child: _MarkerPin(
          color: const Color(0xFF34A853), // Google Maps-style green
          label: 'A',
        ),
      ));
    }

    if (destination != null) {
      list.add(Marker(
        point: destination!,
        width: 44,
        height: 44,
        child: _MarkerPin(
          color: const Color(0xFFEA4335), // Google Maps-style red
          label: 'B',
        ),
      ));
    }

    return list;
  }

  // ── Snackbar helper ───────────────────────────────────────────────────────
  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Format LatLng for display ─────────────────────────────────────────────
  String _formatLatLng(LatLng? point) {
    if (point == null) return '—';
    return '${point.latitude.toStringAsFixed(5)}, '
        '${point.longitude.toStringAsFixed(5)}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _originController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── Map ──────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(10.3157, 123.8854), // Cebu
              initialZoom: 13,
              onTap: _onMapTap, // wire up tap handler
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://cartodb-basemaps-a.global.ssl.fastly.net/light_all/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mapapp',
              ),

              // ── Jeepney route polylines ───────────────────────────────────
              PolylineLayer(
                polylines: cebuJeepneyRoutes
                    .map((route) => Polyline(
                          points: route.path,
                          color: route.color,
                          strokeWidth: 4.0,
                          strokeCap: StrokeCap.round,
                          strokeJoin: StrokeJoin.round,
                        ))
                    .toList(),
              ),

              // ── Route terminus markers (start of each route) ─────────────
              MarkerLayer(
                markers: cebuJeepneyRoutes
                    .map((route) => Marker(
                          point: route.path.first,
                          width: 56,
                          height: 24,
                          child: _RouteLabel(route: route),
                        ))
                    .toList(),
              ),

              MarkerLayer(markers: _markers), // A/B selection markers on top
            ],
          ),

          // ── Route legend ──────────────────────────────────────────────────
          const Positioned(
            bottom: 120,
            right: 16,
            child: _RouteLegend(),
          ),

          // ── Top panel ────────────────────────────────────────────────────
          Positioned(
            top: 48,
            left: 16,
            right: 16,
            child: _TopPanel(
              originController: _originController,
              destinationController: _destinationController,
              searchingOrigin: _searchingOrigin,
              searchingDestination: _searchingDestination,
              onSearchOrigin: _onSearchOrigin,
              onSearchDestination: _onSearchDestination,
              onReset: _resetAll,
            ),
          ),

          // ── Bottom info card ──────────────────────────────────────────────
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: _InfoCard(
              originCoords: _formatLatLng(origin),
              destinationCoords: _formatLatLng(destination),
              tapHint: origin == null
                  ? 'Tap map to set Origin (A)'
                  : destination == null
                      ? 'Tap map to set Destination (B)'
                      : 'Tap map again to reset',
            ),
          ),

          // ── Search results panel ──────────────────────────────────────────
          // Slides up from the bottom when _showResults is true.
          // Sits above the info card but leaves the top panel visible.
          if (_showResults)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ResultsPanel(
                results: _searchResults,
                forOrigin: _pendingForOrigin ?? true,
                onSelect: _onResultSelected,
                onDismiss: _dismissResults,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Top Panel Widget ──────────────────────────────────────────────────────────
class _TopPanel extends StatelessWidget {
  final TextEditingController originController;
  final TextEditingController destinationController;
  final bool searchingOrigin;
  final bool searchingDestination;
  final VoidCallback onSearchOrigin;
  final VoidCallback onSearchDestination;
  final VoidCallback onReset;

  const _TopPanel({
    required this.originController,
    required this.destinationController,
    required this.searchingOrigin,
    required this.searchingDestination,
    required this.onSearchOrigin,
    required this.onSearchDestination,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          children: [
            // Origin row
            _SearchRow(
              controller: originController,
              hint: 'Origin — e.g. SM City Cebu',
              dotColor: const Color(0xFF34A853),
              label: 'A',
              isLoading: searchingOrigin,
              onSubmit: onSearchOrigin,
            ),
            const Divider(height: 10, thickness: 0.5),
            // Destination row
            _SearchRow(
              controller: destinationController,
              hint: 'Destination — e.g. Ayala Center',
              dotColor: const Color(0xFFEA4335),
              label: 'B',
              isLoading: searchingDestination,
              onSubmit: onSearchDestination,
            ),
            const SizedBox(height: 8),
            // Reset button
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reset'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey[700],
                  padding: const EdgeInsets.symmetric(vertical: 4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Single Search Row ─────────────────────────────────────────────────────────
class _SearchRow extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final Color dotColor;
  final String label;
  final bool isLoading;
  final VoidCallback onSubmit;

  const _SearchRow({
    required this.controller,
    required this.hint,
    required this.dotColor,
    required this.label,
    required this.isLoading,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Colored dot label
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Text field
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: hint,
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
        // Search / loading icon
        isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                icon: const Icon(Icons.search, size: 20),
                onPressed: onSubmit,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
      ],
    );
  }
}

// ─── Info Card ─────────────────────────────────────────────────────────────────
class _InfoCard extends StatelessWidget {
  final String originCoords;
  final String destinationCoords;
  final String tapHint;

  const _InfoCard({
    required this.originCoords,
    required this.destinationCoords,
    required this.tapHint,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CoordRow(
              color: const Color(0xFF34A853),
              label: 'A  Origin',
              coords: originCoords,
            ),
            const SizedBox(height: 6),
            _CoordRow(
              color: const Color(0xFFEA4335),
              label: 'B  Destination',
              coords: destinationCoords,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.touch_app, size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                Text(
                  tapHint,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CoordRow extends StatelessWidget {
  final Color color;
  final String label;
  final String coords;

  const _CoordRow({
    required this.color,
    required this.label,
    required this.coords,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.circle, color: color, size: 10),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const Spacer(),
        Text(
          coords,
          style: TextStyle(fontSize: 12, color: Colors.grey[700]),
        ),
      ],
    );
  }
}

// ─── Search Results Panel ──────────────────────────────────────────────────────
// Slides up from the bottom of the screen after a search.
// Shows all ranked results; tapping one applies it to origin or destination.
class _ResultsPanel extends StatelessWidget {
  final List<_SearchResult> results;
  final bool forOrigin;
  final void Function(_SearchResult) onSelect;
  final VoidCallback onDismiss;

  const _ResultsPanel({
    required this.results,
    required this.forOrigin,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final headerColor =
        forOrigin ? const Color(0xFF34A853) : const Color(0xFFEA4335);
    final headerLabel = forOrigin ? 'Set Origin (A)' : 'Set Destination (B)';

    return Material(
      elevation: 12,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ─────────────────────────────────────────────────
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),

          // ── Header row ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: headerColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    headerLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${results.length} result${results.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(width: 8),
                // Dismiss (×) button
                GestureDetector(
                  onTap: onDismiss,
                  child: const Icon(Icons.close, size: 20, color: Colors.grey),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),
          const Divider(height: 1),

          // ── Results list (max height = 45% of screen) ────────────────────
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.45,
            ),
            child: results.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No results found.\nTry a different search term.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: results.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 56),
                    itemBuilder: (context, index) {
                      final r = results[index];

                      // Split "Name, Street, City, Country" into parts
                      final parts = r.displayName.split(', ');
                      final name = parts.first;
                      final subtitle = parts.length > 1
                          ? parts.skip(1).take(2).join(', ')
                          : null;

                      // Distance badge text
                      final distText = r.distanceMeters == double.infinity
                          ? null
                          : r.distanceMeters < 1000
                              ? '${r.distanceMeters.round()} m'
                              : '${(r.distanceMeters / 1000).toStringAsFixed(1)} km';

                      return ListTile(
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: headerColor.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.location_on,
                              color: headerColor, size: 18),
                        ),
                        title: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: subtitle != null
                            ? Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[600]),
                              )
                            : null,
                        trailing: distText != null
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.grey[100],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  distText,
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey[700]),
                                ),
                              )
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
// Uses only widgets — no CustomPainter / dart:ui Path needed.
// The "tail" is a small square rotated 45° so its bottom corner points down.

// ─── Route Label Widget ────────────────────────────────────────────────────────
// Small colored pill shown at the start point of each jeepney route.
class _RouteLabel extends StatelessWidget {
  final JeepneyRoute route;
  const _RouteLabel({required this.route});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: route.color,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: route.color.withOpacity(0.5),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        route.routeId,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ─── Route Legend Widget ───────────────────────────────────────────────────────
// Collapsible card in the bottom-right corner listing all routes.
class _RouteLegend extends StatefulWidget {
  const _RouteLegend();

  @override
  State<_RouteLegend> createState() => _RouteLegendState();
}

class _RouteLegendState extends State<_RouteLegend> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white.withOpacity(0.95),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ──────────────────────────────────────────────────
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.directions_bus, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  const Text(
                    'Routes',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 14,
                    color: Colors.grey,
                  ),
                ],
              ),
              // ── Route list (only when expanded) ─────────────────────────
              if (_expanded) ...[
                const SizedBox(height: 6),
                const Divider(height: 1),
                const SizedBox(height: 6),
                ...cebuJeepneyRoutes.map((route) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 20,
                            height: 4,
                            decoration: BoxDecoration(
                              color: route.color,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${route.routeId}  ${route.routeName}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    )),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Custom Marker Pin ─────────────────────────────────────────────────────────
class _MarkerPin extends StatelessWidget {
  final Color color;
  final String label;

  const _MarkerPin({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Circle head ──────────────────────────────────────────────────
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.5),
                blurRadius: 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),

        // ── Pin tail — rotated square, no Canvas/Path needed ─────────────
        // Rotating a square 45° gives a diamond; only the bottom half is
        // visible because the top half is hidden under the circle above.
        Transform.rotate(
          angle: 0.7854, // π/4 = 45 degrees
          child: Container(
            width: 9,
            height: 9,
            color: color,
          ),
        ),
      ],
    );
  }
}