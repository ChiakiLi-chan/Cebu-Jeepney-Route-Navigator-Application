// lib/widgets/map_location_picker.dart
//
// MapLocationPicker — a full-screen map selection experience.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  UX FLOW                                                                 │
// │                                                                          │
// │  Push this route with Navigator.push (or showModalBottomSheet won't     │
// │  work — the map needs full height).                                      │
// │                                                                          │
// │  1. Map loads centered on [initialCenter].                              │
// │  2. A crosshair pin is FIXED at the visual center of the screen.        │
// │     The map moves UNDERNEATH it when the user drags — exactly like      │
// │     Google Maps "move the map, not the pin" behaviour.                  │
// │  3. onPositionChanged fires every time the map center moves, keeping    │
// │     _pickedLatLng in sync with wherever the pin is pointing.            │
// │  4. A search bar at the top lets the user type a place name:            │
// │       → results from LocationService.search()                           │
// │       → tapping a result moves the map to that point                    │
// │       → user can still fine-tune by dragging after searching            │
// │  5. A bottom confirmation card shows the current coords + a             │
// │     "Confirm" button. Pressing it pops the route with the LatLng.       │
// │  6. A cancel button in the top-left returns null.                       │
// │                                                                          │
// │  PIN ANIMATION                                                           │
// │  An AnimationController lifts the pin shadow and raises the pin body    │
// │  while the user is dragging (MapEventMove), then settles it back when   │
// │  the map stops (MapEventMoveEnd). This gives the tactile "picked up"    │
// │  feel of Google Maps.                                                   │
// └─────────────────────────────────────────────────────────────────────────┘

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:ui' as ui;
import 'package:thesis_app/services/location_service.dart';

class MapLocationPicker extends StatefulWidget {
  /// Label shown in the confirm button and app bar. E.g. "Origin" or "Destination".
  final String        label;

  /// Accent colour matching the A/B colour convention.
  final Color         color;

  /// Where the map opens. Falls back to Cebu city center if null.
  final LatLng?       initialCenter;

  /// Already-known user GPS location for search result proximity sorting.
  final LatLng?       userLocation;

  const MapLocationPicker({
    super.key,
    required this.label,
    required this.color,
    this.initialCenter,
    this.userLocation,
  });

  /// Convenience push helper. Returns the picked [LatLng] or null if cancelled.
  static Future<LatLng?> show(
    BuildContext context, {
    required String  label,
    required Color   color,
    LatLng?          initialCenter,
    LatLng?          userLocation,
  }) {
    return Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => MapLocationPicker(
          label:         label,
          color:         color,
          initialCenter: initialCenter,
          userLocation:  userLocation,
        ),
      ),
    );
  }

  @override
  State<MapLocationPicker> createState() => _MapLocationPickerState();
}

class _MapLocationPickerState extends State<MapLocationPicker>
    with SingleTickerProviderStateMixin {
  static const _kCebuCenter = LatLng(10.3157, 123.8854);

  final MapController         _mapController  = MapController();
  final TextEditingController _searchCtrl     = TextEditingController();
  final LocationService       _locationSvc    = LocationService();

  // Current pin position — kept in sync with map center via onPositionChanged
  late LatLng _pickedLatLng;

  // Search state
  List<LocationResult> _searchResults   = [];
  bool                 _isSearching     = false;
  bool                 _showResults     = false;

  // Pin drag animation
  late final AnimationController _pinAnim;
  late final Animation<double>   _pinLift;   // 0 = resting, 1 = lifted
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _pickedLatLng = widget.initialCenter ?? _kCebuCenter;

    _pinAnim = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 180),
    );
    _pinLift = CurvedAnimation(parent: _pinAnim, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _pinAnim.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Map events ────────────────────────────────────────────────────────────

  void _onMapEvent(MapEvent event) {
    if (event is MapEventMoveStart) {
      if (!_isDragging) {
        _isDragging = true;
        _pinAnim.forward();
      }
    } else if (event is MapEventMoveEnd || event is MapEventFlingAnimationEnd) {
      if (_isDragging) {
        _isDragging = false;
        _pinAnim.reverse();
      }
    }

    // Keep _pickedLatLng in sync with the map center every frame
    if (event is MapEventMove || event is MapEventMoveStart ||
        event is MapEventMoveEnd || event is MapEventScrollWheelZoom) {
      final center = _mapController.camera.center;
      if (center != _pickedLatLng) {
        setState(() => _pickedLatLng = center);
      }
    }
  }

  // ── Search ────────────────────────────────────────────────────────────────

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() { _showResults = false; _searchResults = []; });
      return;
    }
    setState(() { _isSearching = true; _showResults = false; });
    final results = await _locationSvc.search(
        query, userLocation: widget.userLocation);
    if (!mounted) return;
    setState(() {
      _isSearching   = false;
      _searchResults = results;
      _showResults   = results.isNotEmpty;
    });
  }

  void _pickSearchResult(LocationResult result) {
    _searchCtrl.text = result.shortName;
    setState(() { _showResults = false; _searchResults = []; });
    _mapController.move(result.point, 16);
    // _pickedLatLng will update via _onMapEvent after the move
    FocusScope.of(context).unfocus();
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() { _showResults = false; _searchResults = []; });
    FocusScope.of(context).unfocus();
  }

  // ── Confirm / cancel ──────────────────────────────────────────────────────

  void _confirm() => Navigator.of(context).pop(_pickedLatLng);
  void _cancel()  => Navigator.of(context).pop(null);

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtCoord(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

  String _fmtDist(double m) =>
      m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    return Scaffold(
      // No AppBar — we build our own overlaid controls for full-bleed map
      body: Stack(
        children: [

          // ── Map ─────────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.initialCenter ?? _kCebuCenter,
              initialZoom:   15,
              onMapEvent:    _onMapEvent,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://cartodb-basemaps-a.global.ssl.fastly.net/'
                    'light_all/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mapapp',
              ),
            ],
          ),

          // ── Crosshair / floating pin ─────────────────────────────────────────
          // Rendered OUTSIDE FlutterMap so it's immune to map rebuilds.
          // It's always visually centered regardless of map state.
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: AnimatedBuilder(
                  animation: _pinLift,
                  builder: (_, __) => _FloatingPin(
                    color:    widget.color,
                    liftFrac: _pinLift.value,
                  ),
                ),
              ),
            ),
          ),

          // ── Top bar: back button + search field ───────────────────────────────
          Positioned(
            top: mq.padding.top + 8,
            left: 12, right: 12,
            child: Row(
              children: [
                // Cancel / back
                Material(
                  elevation:    4,
                  shape:        const CircleBorder(),
                  color:        Colors.white,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap:        _cancel,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child:   Icon(Icons.arrow_back, size: 22),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Search field
                Expanded(
                  child: Material(
                    elevation:    4,
                    borderRadius: BorderRadius.circular(12),
                    color:        Colors.white,
                    child: TextField(
                      controller:  _searchCtrl,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _runSearch,
                      onChanged: (v) {
                        if (v.isEmpty) _clearSearch();
                      },
                      decoration: InputDecoration(
                        hintText:       'Search a place…',
                        border:         InputBorder.none,
                        isDense:        true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        prefixIcon: _isSearching
                            ? const Padding(
                                padding: EdgeInsets.all(10),
                                child:   SizedBox(
                                  width: 18, height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              )
                            : const Icon(Icons.search,
                                size: 20, color: Colors.grey),
                        suffixIcon: _searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon:        const Icon(Icons.close,
                                    size: 18, color: Colors.grey),
                                onPressed:   _clearSearch,
                                padding:     EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Search results dropdown ──────────────────────────────────────────
          if (_showResults)
            Positioned(
              top:   mq.padding.top + 68,
              left:  12, right: 12,
              child: Material(
                elevation:    6,
                borderRadius: BorderRadius.circular(12),
                color:        Colors.white,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: mq.size.height * 0.35),
                  child: ListView.separated(
                    shrinkWrap:  true,
                    padding:     const EdgeInsets.symmetric(vertical: 6),
                    itemCount:   _searchResults.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 48),
                    itemBuilder: (_, i) {
                      final r    = _searchResults[i];
                      final dist = r.distanceMeters == double.infinity
                          ? null
                          : _fmtDist(r.distanceMeters);
                      return ListTile(
                        dense:   true,
                        leading: Icon(Icons.location_on,
                            color: widget.color, size: 18),
                        title: Text(r.shortName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          r.displayName
                              .split(', ')
                              .skip(1)
                              .take(2)
                              .join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey[500]),
                        ),
                        trailing: dist != null
                            ? Text(dist,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500]))
                            : null,
                        onTap: () => _pickSearchResult(r),
                      );
                    },
                  ),
                ),
              ),
            ),

          // ── Bottom confirmation card ─────────────────────────────────────────
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: _ConfirmCard(
              label:    widget.label,
              color:    widget.color,
              coords:   _fmtCoord(_pickedLatLng),
              onConfirm: _confirm,
            ),
          ),

        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// FLOATING PIN WIDGET
// ══════════════════════════════════════════════════════════════════════════════
//
// Renders a pin icon with an animated shadow below it.
// liftFrac: 0 = resting on map, 1 = fully lifted while dragging.

class _FloatingPin extends StatelessWidget {
  final Color  color;
  final double liftFrac; // 0..1

  const _FloatingPin({required this.color, required this.liftFrac});

  @override
  Widget build(BuildContext context) {
    // Vertical offset: pin rises 10px at peak lift
    final lift   = liftFrac * 10.0;
    // Shadow spreads and fades as pin lifts
    final spread = 4.0 + liftFrac * 10.0;
    final opacity = 0.25 - liftFrac * 0.15;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pin body — rises upward when dragging
        Transform.translate(
          offset: Offset(0, -lift),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Circle head
              Container(
                width:  36, height: 36,
                decoration: BoxDecoration(
                  color:  color,
                  shape:  BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color:      color.withOpacity(0.4),
                      blurRadius: 8 + liftFrac * 6,
                      offset:     const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(Icons.location_pin,
                    color: Colors.white, size: 18),
              ),
              // Needle point
              CustomPaint(
                size:    const Size(12, 8),
                painter: _NeedlePainter(color: color),
              ),
            ],
          ),
        ),

        // Shadow ellipse on the ground — stays at original position
        Transform.translate(
          offset: const Offset(0, 0),
          child: Container(
            width:  spread * 2,
            height: spread * 0.6,
            decoration: BoxDecoration(
              color:        Colors.black.withOpacity(opacity),
              borderRadius: BorderRadius.circular(spread),
            ),
          ),
        ),
      ],
    );
  }
}

class _NeedlePainter extends CustomPainter {
  final Color color;
  const _NeedlePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = ui.Paint()..color = color;
    final path  = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_NeedlePainter old) => old.color != color;
}

// ══════════════════════════════════════════════════════════════════════════════
// CONFIRM CARD
// ══════════════════════════════════════════════════════════════════════════════

class _ConfirmCard extends StatelessWidget {
  final String    label;
  final Color     color;
  final String    coords;
  final VoidCallback onConfirm;

  const _ConfirmCard({
    required this.label,
    required this.color,
    required this.coords,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withOpacity(0.12),
            blurRadius: 16,
            offset:     const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 14),

          // Label row
          Row(
            children: [
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                    color: color, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  label == 'Origin' ? 'A' : 'B',
                  style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Set $label',
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize:   16),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Coords hint
          Row(
            children: [
              Icon(Icons.location_on, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  coords,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey[600]),
                ),
              ),
            ],
          ),

          const SizedBox(height: 4),

          Text(
            'Move the map to adjust the pin position',
            style: TextStyle(fontSize: 11, color: Colors.grey[400]),
          ),

          const SizedBox(height: 14),

          // Confirm button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: color,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: onConfirm,
              icon:  const Icon(Icons.check_circle_outline, size: 18),
              label: Text(
                'Confirm $label',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}