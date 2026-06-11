// lib/screens/route_finder_page.dart



import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:thesis_app/data/jeepney_routes.dart';
import 'package:thesis_app/services/jeepney_router.dart';
import 'package:thesis_app/models/routing_models.dart';
import 'package:thesis_app/services/location_search_service.dart';
import 'package:thesis_app/screens/trip_tracker.dart';
import 'package:thesis_app/models/log_entry.dart';
import 'package:thesis_app/services/fare_calculator.dart';
import 'package:thesis_app/widgets/route_finder_widgets.dart';


// ══════════════════════════════════════════════════════════════════════════════

// ══════════════════════════════════════════════════════════════════════════════

// ══════════════════════════════════════════════════════════════════════════════
// RouteFinderPage
// ══════════════════════════════════════════════════════════════════════════════

class RouteFinderPage extends StatefulWidget {
  final List<JeepneyRoute>    allRoutes;
  final bool                  routesReady;
  final void Function(LogEntry)?     onLog;
  final void Function(TripRecord)?   onTripComplete;

  const RouteFinderPage({
    super.key,
    required this.allRoutes,
    required this.routesReady,
    this.onLog,
    this.onTripComplete,
  });

  @override
  State<RouteFinderPage> createState() => _RouteFinderPageState();
}

class _RouteFinderPageState extends State<RouteFinderPage> {
  final MapController         _mapController = MapController();
  final TextEditingController _originCtrl    = TextEditingController();
  final TextEditingController _destCtrl      = TextEditingController();
  final JeepneyRouter         _router        = const JeepneyRouter(
    radiusMeters:          1000,
    transferRadiusMeters:  180,
    transferPenaltyMeters: 400,
    maxTransfersAllowed:   1,
  );
  final NominatimService _nominatim = NominatimService();

  LatLng? _origin;
  LatLng? _destination;
  LatLng? _userLocation;

  final FocusNode _originFocusNode    = FocusNode();
  bool            _originFieldFocused = false;
  final FocusNode _destFocusNode      = FocusNode();
  bool            _destFieldFocused   = false;
  DateTime?       _routingStartTime;

  // ── Trip recording ───────────────────────────────────────────────────────────
  bool                          _isRecording         = false;
  final List<LatLng>            _recordedPath        = [];
  DateTime?                     _recordingStartTime;
  DateTime?                     _lastGpsUpdate;
  DateTime?                     _lastDeviationPrompt;
  bool                          _gpsWasOnRoute       = true;
  StreamSubscription<Position>? _locationStream;
  StreamSubscription<Position>? _userLocationStream;
  Timer?                        _heartbeatTimer;

  // ── Pin mode ──────────────────────────────────────────────────────────────
  bool  _pinMode          = false;
  bool  _pinModeForOrigin = true;
  bool  _reverseGeocoding = false;

  List<RfNearbyRouteResult> _nearbyRoutes          = [];
  String?                  _selectedNearbyRouteId;

  void _log(LogEntry entry) => widget.onLog?.call(entry);

  List<SearchResult> _searchResults    = [];
  bool               _showResults      = false;
  bool?              _pendingForOrigin;
  bool               _searchingOrigin  = false;
  bool               _searchingDest    = false;

  RoutingResult?        _routingResult;
  int                   _selectedRec      = 0;
  bool                  _routingBusy      = false;
  bool                  _sheetMinimized   = false;
  PrecomputedRouteGraph? _precomputedGraph;
  bool                  _roadsOnly        = false;
  RoutePriority         _priority         = RoutePriority.balanced;

  @override
  void initState() {
    super.initState();
    _fetchUserLocation();
    _originFocusNode.addListener(() {
      if (mounted) setState(() => _originFieldFocused = _originFocusNode.hasFocus);
    });
    _destFocusNode.addListener(() {
      if (mounted) setState(() => _destFieldFocused = _destFocusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _originCtrl.dispose();
    _destCtrl.dispose();
    _locationStream?.cancel();
    _userLocationStream?.cancel();
    _heartbeatTimer?.cancel();
    _originFocusNode.dispose();
    _destFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(RouteFinderPage old) {
    super.didUpdateWidget(old);
    if (!old.routesReady && widget.routesReady) {
      _precomputeGraph();
      _maybeRunRouting();
    }
  }

  // ── Precompute static graph once routes are loaded ───────────────────────────

  void _precomputeGraph() {
    if (widget.allRoutes.isEmpty) return;
    compute(
      runStaticGraphIsolate,
      StaticGraphMessage(
        allRoutes:            widget.allRoutes,
        transferRadiusMeters: _router.transferRadiusMeters,
        transferPenaltyMeters:_router.transferPenaltyMeters,
      ),
    ).then((graph) {
      if (mounted) setState(() => _precomputedGraph = graph);
    });
  }

  // ── GPS ──────────────────────────────────────────────────────────────────────

  Future<void> _fetchUserLocation() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
      if (mounted) {
        setState(() => _userLocation = LatLng(pos.latitude, pos.longitude));
      }
    } catch (_) {}
    // Keep the blue dot live as the user moves
    _userLocationStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.medium,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      if (mounted) {
        setState(() => _userLocation = LatLng(pos.latitude, pos.longitude));
      }
    });
  }

  // ── Use current location ─────────────────────────────────────────────────────

  void _useCurrentLocation() {
    if (_userLocation == null) return;
    setState(() => _origin = _userLocation);
    _originCtrl.text = 'Current Location';
    _originFocusNode.unfocus();
    _log(LogEntry(
      type:    LogEventType.originSet,
      message: 'Origin set to Current Location',
      detail:  '${_userLocation!.latitude.toStringAsFixed(5)}, '
               '${_userLocation!.longitude.toStringAsFixed(5)}',
    ));
    _computeNearbyRoutes();
    _maybeRunRouting();
  }

  // ── Pin mode ──────────────────────────────────────────────────────────────────

  void _enterPinMode({required bool forOrigin}) {
    _originFocusNode.unfocus();
    _destFocusNode.unfocus();
    final existing = forOrigin ? _origin : _destination;
    setState(() {
      _pinMode          = true;
      _pinModeForOrigin = forOrigin;
    });
    if (existing != null) {
      // Fly to the existing pin position so the user can fine-tune it
      Future.microtask(() => _mapController.move(existing, 16));
    }
  }

  void _cancelPinMode() => setState(() {
        _pinMode          = false;
        _reverseGeocoding = false;
      });

  Future<void> _confirmPin() async {
    final center = _mapController.camera.center;
    setState(() => _reverseGeocoding = true);
    final name = await _reverseGeocode(center);
    if (!mounted) return;
    setState(() {
      if (_pinModeForOrigin) {
        _origin = center;
        _originCtrl.text = name;
      } else {
        _destination = center;
        _destCtrl.text = name;
      }
      _pinMode          = false;
      _reverseGeocoding = false;
    });
    _computeNearbyRoutes();
    _maybeRunRouting();
    if (_pinModeForOrigin) {
      _log(LogEntry(
        type:    LogEventType.originSet,
        message: 'Origin pinned on map',
        detail:  '${center.latitude.toStringAsFixed(5)}, '
                 '${center.longitude.toStringAsFixed(5)}',
      ));
    } else {
      _log(LogEntry(
        type:    LogEventType.destinationSet,
        message: 'Destination pinned on map',
        detail:  '${center.latitude.toStringAsFixed(5)}, '
                 '${center.longitude.toStringAsFixed(5)}',
      ));
    }
  }

  Future<String> _reverseGeocode(LatLng point) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat':    point.latitude.toStringAsFixed(6),
        'lon':    point.longitude.toStringAsFixed(6),
        'format': 'json',
      });
      final response = await http.get(uri, headers: {
        'User-Agent':      'thesis_app_cebu/1.0',
        'Accept-Language': 'en',
      });
      if (response.statusCode == 200) {
        final data    = jsonDecode(response.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          return (address['amenity']      ??
                  address['building']     ??
                  address['road']         ??
                  address['neighbourhood']??
                  address['suburb']       ??
                  (data['display_name'] as String?)?.split(',').first ??
                  'Pinned Location') as String;
        }
        return (data['display_name'] as String?)?.split(',').first
            ?? 'Pinned Location';
      }
    } catch (_) {}
    return 'Pinned Location';
  }

  // ── Search ───────────────────────────────────────────────────────────────────

  Future<void> _onSearch({required bool forOrigin}) async {
    if (_userLocation == null) await _fetchUserLocation();
    final query = forOrigin ? _originCtrl.text : _destCtrl.text;
    setState(() {
      if (forOrigin) _searchingOrigin = true;
      else           _searchingDest   = true;
      _showResults   = false;
      _searchResults = [];
    });
    final results = await _nominatim.search(query, userLocation: _userLocation);
    if (!mounted) return;
    setState(() {
      if (forOrigin) _searchingOrigin = false;
      else           _searchingDest   = false;
      _searchResults    = results;
      _pendingForOrigin = forOrigin;
      _showResults      = results.isNotEmpty;
    });
    if (results.isEmpty) _snack('No results found for "$query"');
  }

  void _onResultPicked(SearchResult r) {
    final forOrigin = _pendingForOrigin ?? true;
    setState(() {
      if (forOrigin) _origin      = r.point;
      else           _destination = r.point;
      _showResults      = false;
      _searchResults    = [];
      _pendingForOrigin = null;
    });
    _mapController.move(r.point, 15);
    if (forOrigin) {
      _originCtrl.text = r.shortName;
      _log(LogEntry(
        type:    LogEventType.originSet,
        message: 'Origin set to "${r.shortName}"',
        detail:  '${r.point.latitude.toStringAsFixed(5)}, '
                 '${r.point.longitude.toStringAsFixed(5)}',
      ));
    } else {
      _destCtrl.text = r.shortName;
      _log(LogEntry(
        type:    LogEventType.destinationSet,
        message: 'Destination set to "${r.shortName}"',
        detail:  '${r.point.latitude.toStringAsFixed(5)}, '
                 '${r.point.longitude.toStringAsFixed(5)}',
      ));
    }
    if (_isRecording) _endRecording();
    _computeNearbyRoutes();
    _maybeRunRouting();
  }

  void _dismissResults() => setState(() {
        _showResults      = false;
        _searchResults    = [];
        _pendingForOrigin = null;
      });

  // ── Routing ──────────────────────────────────────────────────────────────────

  // ── Trip recording ───────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (_userLocation == null) {
      await _fetchUserLocation();
      if (_userLocation == null) return;
    }
    final result = _routingResult;
    if (result is! RoutingSuccess || result.recommendations.isEmpty) return;
    final journey = result.recommendations[_selectedRec];

    // Check if user is near the boarding point
    final boardPt   = journey.segments.first.boardingPoint;
    final distBoard = const Distance().as(LengthUnit.Meter, _userLocation!, boardPt);

    if (distBoard > 100) {
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Not near boarding stop'),
          content: Text(
            'You are ${distBoard.round()} m from the boarding stop for '
            '${journey.segments.first.route.routeId}. '
            'Are you heading there to board?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Start Recording'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }

    setState(() {
      _isRecording          = true;
      _recordedPath.clear();
      _recordingStartTime   = DateTime.now();
      _lastDeviationPrompt  = null;
      _gpsWasOnRoute        = true;
      _lastGpsUpdate        = null;
    });

    _locationStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 20,
      ),
    ).listen(_onLocationUpdate);

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) async {
        if (!_isRecording) return;
        if (_lastGpsUpdate == null ||
            DateTime.now().difference(_lastGpsUpdate!).inSeconds >= 15) {
          try {
            final pos = await Geolocator.getCurrentPosition(
                desiredAccuracy: LocationAccuracy.high);
            if (mounted && _isRecording) _onLocationUpdate(pos);
          } catch (_) {}
        }
      },
    );
  }

  void _onLocationUpdate(Position pos) {
    if (!mounted || !_isRecording) return;
    final point = LatLng(pos.latitude, pos.longitude);
    _lastGpsUpdate = DateTime.now();
    setState(() => _recordedPath.add(point));
    _checkDeviation(point);
  }

  void _checkDeviation(LatLng point) {
    final result = _routingResult;
    if (result is! RoutingSuccess || result.recommendations.isEmpty) return;
    final journey = result.recommendations[_selectedRec];

    // Find nearest point on any ride segment
    double minDist = double.infinity;
    for (final seg in journey.segments) {
      for (final p in seg.ridePolyline) {
        final d = const Distance().as(LengthUnit.Meter, point, p);
        if (d < minDist) minDist = d;
      }
    }

    if (minDist <= 30) {
      _gpsWasOnRoute = true;
      return;
    }

    // Off route — decide whether to prompt
    final now            = DateTime.now();
    final lastPrompt     = _lastDeviationPrompt;
    final sinceLastPrompt = lastPrompt != null
        ? now.difference(lastPrompt)
        : const Duration(days: 1);

    final shouldPrompt = lastPrompt == null ||
        sinceLastPrompt >= const Duration(minutes: 1) ||
        _gpsWasOnRoute; // returned to route and went off again

    if (!shouldPrompt) return;

    setState(() {
      _lastDeviationPrompt = now;
      _gpsWasOnRoute       = false;
    });

    final routeCode = journey.segments.map((s) => s.route.routeId).join(' + ');
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Off Route'),
        content: Text(
            'You appear to have deviated from Jeepney $routeCode. '
            'Are you still riding this jeepney?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, still on it'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(context, false);
              _endRecording();
            },
            child: const Text('No, got off'),
          ),
        ],
      ),
    );
  }

  void _endRecording({bool save = true}) {
    _locationStream?.cancel();
    _locationStream = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (save && _isRecording && _recordedPath.length >= 2) {
      final result = _routingResult;
      if (result is RoutingSuccess && result.recommendations.isNotEmpty) {
        final journey      = result.recommendations[_selectedRec];
        final expectedPath = journey.segments
            .expand((s) => s.ridePolyline)
            .toList();
        final accuracy     = _calcAccuracy(_recordedPath, expectedPath);
        final trip = TripRecord(
          routeCode:       journey.segments.map((s) => s.route.routeId).join(' + '),
          routeName:       journey.segments.map((s) => s.route.routeName).join(' → '),
          routeColor:      journey.segments.first.route.color,
          startTime:       _recordingStartTime!,
          endTime:         DateTime.now(),
          gpsPath:         List<LatLng>.from(_recordedPath),
          expectedPath:    expectedPath,
          accuracyPercent: accuracy,
        );
        widget.onTripComplete?.call(trip);
      }
    }

    if (mounted) {
      setState(() {
        _isRecording          = false;
        _recordingStartTime   = null;
        _lastDeviationPrompt  = null;
        _gpsWasOnRoute        = true;
        _lastGpsUpdate        = null;
        _recordedPath.clear();
      });
    }
  }

  double _calcAccuracy(List<LatLng> gpsPath, List<LatLng> routePath) {
    if (gpsPath.isEmpty || routePath.isEmpty) return 0;
    const d    = Distance();
    int onRoute = 0;
    for (final gpt in gpsPath) {
      double minD = double.infinity;
      for (final rpt in routePath) {
        final dist = d.as(LengthUnit.Meter, gpt, rpt);
        if (dist < minD) minD = dist;
      }
      if (minD <= 20) onRoute++;
    }
    return (onRoute / gpsPath.length) * 100;
  }

  // ── Nearby routes (single-point discovery) ───────────────────────────────────
  // Called when exactly one of origin/destination is set. Finds all routes
  // within 500 m of the point; falls back to the single closest route if none
  // are within that radius.

  void _computeNearbyRoutes() {
    final onlyOrigin = _origin != null && _destination == null;
    final onlyDest   = _destination != null && _origin == null;

    if (!onlyOrigin && !onlyDest) {
      if (_nearbyRoutes.isNotEmpty) setState(() => _nearbyRoutes = []);
      return;
    }

    if (!widget.routesReady || widget.allRoutes.isEmpty) return;

    final point    = (_origin ?? _destination)!;
    const radius   = 500.0;
    const distance = Distance();

    final results = widget.allRoutes.map((route) {
      double minDist = double.infinity;
      for (final p in route.path) {
        final d = distance.as(LengthUnit.Meter, point, p);
        if (d < minDist) minDist = d;
      }
      return RfNearbyRouteResult(route: route, nearestMeters: minDist);
    }).toList()
      ..sort((a, b) => a.nearestMeters.compareTo(b.nearestMeters));

    final within = results.where((r) => r.nearestMeters <= radius).toList();

    setState(() {
      _nearbyRoutes          = within.isNotEmpty ? within : results.take(1).toList();
      _selectedNearbyRouteId = null;
    });
  }

  void _maybeRunRouting() {
    if (_origin == null || _destination == null) return;
    setState(() {
      _routingBusy  = true;
      _nearbyRoutes = [];
    });
    _routingStartTime = DateTime.now();
    _log(LogEntry(
      type:    LogEventType.routingStarted,
      message: 'Routing started',
      detail:  'From "${_originCtrl.text}" → "${_destCtrl.text}"',
    ));

    // Run the routing algorithm in a background isolate so the UI thread is
    // never blocked.  compute() requires a top-level function and a single
    // serialisable argument — both are defined in jeepney_router.dart.
    compute(
      runRoutingIsolate,
      RoutingMessage(
        origin:               _origin!,
        destination:          _destination!,
        allRoutes:            widget.allRoutes,
        radiusMeters:         _router.radiusMeters,
        transferRadiusMeters: _router.transferRadiusMeters,
        transferPenaltyMeters:_router.transferPenaltyMeters,
        maxTransfersAllowed:  _router.maxTransfersAllowed,
        maxResults:           _router.maxResults,
        priority:             _priority,
        precomputedGraph:     _precomputedGraph,
      ),
    ).then((result) {
      if (!mounted) return;
      final elapsed = _routingStartTime == null ? 0.0
          : DateTime.now().difference(_routingStartTime!).inMilliseconds / 1000.0;
      if (result is RoutingSuccess) {
        _log(LogEntry(
          type:    LogEventType.routingCompleted,
          message: '${result.recommendations.length} route'
                   '${result.recommendations.length == 1 ? '' : 's'} found',
          detail:  'Completed in ${elapsed.toStringAsFixed(2)} s'
                   '${result.hasTransfers ? ' · includes transfers' : ''}',
        ));
      } else if (result is RoutingFailure) {
        _log(LogEntry(
          type:    LogEventType.routingCompleted,
          message: 'No routes found',
          detail:  '${(result as RoutingFailure).reason} '
                   '(${elapsed.toStringAsFixed(2)} s)',
        ));
      }
      setState(() {
        _routingResult  = result;
        _selectedRec    = 0;
        _routingBusy    = false;
        _sheetMinimized = false;
      });
      _fitToJourney();
    });
  }

  // ── Fit map to the selected journey ─────────────────────────────────────────

  void _fitToJourney() {
    final res = _routingResult;
    if (res is! RoutingSuccess || res.recommendations.isEmpty) return;
    final journey = res.recommendations[_selectedRec];

    // Collect every meaningful point: origin, all boarding/dropoff/transfer
    // points, and destination — then compute a bounding box.
    final pts = <LatLng>[
      _origin!,
      for (final seg in journey.segments) ...[
        seg.boardingPoint,
        ...seg.ridePolyline,
        seg.dropoffPoint,
      ],
      ...journey.transferPoints,
      _destination!,
    ];

    double minLat = pts.first.latitude,  maxLat = pts.first.latitude;
    double minLon = pts.first.longitude, maxLon = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }

    final span = [maxLat - minLat, maxLon - minLon]
        .reduce((a, b) => a > b ? a : b);
    final zoom = span < 0.01 ? 15.5
               : span < 0.05 ? 14.0
               : span < 0.15 ? 13.0
               : span < 0.40 ? 12.0 : 11.0;
    _mapController.move(
        LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2), zoom);
  }

  // ── Reset ────────────────────────────────────────────────────────────────────

  void _resetAll() {
    setState(() {
      _origin           = null;
      _destination      = null;
      _routingResult         = null;
      _nearbyRoutes          = [];
      _selectedNearbyRouteId = null;
      _selectedRec           = 0;
      _showResults      = false;
      _searchResults    = [];
      _pendingForOrigin = null;
      _routingBusy      = false;
      _sheetMinimized   = false;
    });
    _originCtrl.clear();
    _destCtrl.clear();
  }

  // ── Individual field clears ───────────────────────────────────────────────────

  void _clearOrigin() {
    if (_isRecording) _endRecording();
    setState(() {
      _origin        = null;
      _routingResult         = null;
      _nearbyRoutes          = [];
      _selectedNearbyRouteId = null;
      _selectedRec           = 0;
      _sheetMinimized = false;
    });
    _originCtrl.clear();
    _computeNearbyRoutes();
  }

  void _clearDest() {
    if (_isRecording) _endRecording();
    setState(() {
      _destination   = null;
      _routingResult         = null;
      _nearbyRoutes          = [];
      _selectedNearbyRouteId = null;
      _selectedRec           = 0;
      _sheetMinimized = false;
    });
    _destCtrl.clear();
    _computeNearbyRoutes();
  }

  // ── Map layers ────────────────────────────────────────────────────────────────

  List<Marker> get _abMarkers => [
        if (_origin != null)
          Marker(
            point: _origin!, width: 44, height: 44,
            child: RfMarkerPin(color: const Color(0xFF34A853), label: 'A'),
          ),
        if (_destination != null)
          Marker(
            point: _destination!, width: 44, height: 44,
            child: RfMarkerPin(color: const Color(0xFFEA4335), label: 'B'),
          ),
      ];

  /// Board/Alight markers for every segment of the selected journey.
  /// Multi-transfer journeys show one Board + one Alight per segment.
  List<Marker> get _stopMarkers {
    final res = _routingResult;
    if (res is! RoutingSuccess || res.recommendations.isEmpty) return [];
    final journey = res.recommendations[_selectedRec];
    final markers = <Marker>[];
    for (int i = 0; i < journey.segments.length; i++) {
      final seg = journey.segments[i];
      markers.add(Marker(
        point: seg.boardingPoint, width: 60, height: 32,
        child: RfStopMarker(
          label: journey.segments.length > 1 ? 'Board ${i + 1}' : 'Board',
          color: seg.route.color,
        ),
      ));
      markers.add(Marker(
        point: seg.dropoffPoint, width: 60, height: 32,
        child: RfStopMarker(
          label: journey.segments.length > 1 ? 'Alight ${i + 1}' : 'Alight',
          color: const Color(0xFFFF6D00),
        ),
      ));
    }
    return markers;
  }

  /// Transfer point markers shown between segments.
  List<Marker> get _transferMarkers {
    final res = _routingResult;
    if (res is! RoutingSuccess || res.recommendations.isEmpty) return [];
    final journey = res.recommendations[_selectedRec];
    return [
      for (int i = 0; i < journey.transferPoints.length; i++)
        Marker(
          point: journey.transferPoints[i], width: 56, height: 32,
          child: RfStopMarker(
            label: 'Transfer',
            color: Colors.purple,
          ),
        ),
    ];
  }

  /// Polylines for the selected journey:
  ///  - faded full-route ghost for each segment's route
  ///  - solid coloured ride polyline per segment
  ///  - dashed green walk from origin → first board
  ///  - dashed purple walk between transfer segments
  ///  - dashed red walk from last alight → destination
  List<Polyline> get _journeyPolylines {
    final res = _routingResult;
    if (res is! RoutingSuccess || res.recommendations.isEmpty) return [];
    final journey = res.recommendations[_selectedRec];
    final lines   = <Polyline>[];

    for (int i = 0; i < journey.segments.length; i++) {
      final seg   = journey.segments[i];
      final color = seg.route.color;

      // Ghost: entire route path faded
      lines.add(Polyline(
        points:      seg.route.path,
        color:       color.withOpacity(0.15),
        strokeWidth: 4,
        strokeCap:   StrokeCap.round,
      ));

      // Active ride segment
      lines.add(Polyline(
        points:      seg.ridePolyline,
        color:       color,
        strokeWidth: 6,
        strokeCap:   StrokeCap.round,
        strokeJoin:  StrokeJoin.round,
      ));

      // Walk to first boarding from origin
      if (i == 0) {
        lines.add(Polyline(
          points:      [_origin!, seg.boardingPoint],
          color:       const Color(0xFF34A853),
          strokeWidth: 2.5,
          pattern:     StrokePattern.dashed(segments: [8, 6]),
        ));
      }

      // Walk between segments (transfer legs)
      if (i < journey.segments.length - 1) {
        final nextSeg = journey.segments[i + 1];
        lines.add(Polyline(
          points:      [seg.dropoffPoint, nextSeg.boardingPoint],
          color:       Colors.purple,
          strokeWidth: 2.5,
          pattern:     StrokePattern.dashed(segments: [8, 6]),
        ));
      }

      // Walk from last dropoff to destination
      if (i == journey.segments.length - 1) {
        lines.add(Polyline(
          points:      [seg.dropoffPoint, _destination!],
          color:       const Color(0xFFEA4335),
          strokeWidth: 2.5,
          pattern:     StrokePattern.dashed(segments: [8, 6]),
        ));
      }
    }

    return lines;
  }

  // ── Nearby route polylines (single-point mode) ──────────────────────────────
  // When a route is selected only it renders at full opacity; the others fade.
  List<Polyline> get _nearbyPolylines {
    final sel = _selectedNearbyRouteId;
    return _nearbyRoutes.map((r) {
      final isSelected = sel == null || r.route.routeId == sel;
      return Polyline(
        points:      r.route.path,
        color:       r.route.color.withOpacity(isSelected ? 0.75 : 0.12),
        strokeWidth: isSelected ? 5.0 : 3.0,
        strokeCap:   StrokeCap.round,
        strokeJoin:  StrokeJoin.round,
      );
    }).toList();
  }

  // ── Priority filter sheet ─────────────────────────────────────────────────

  void _showPrioritySheet() {
    showModalBottomSheet(
      context:       context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Widget option({
            required RoutePriority value,
            required IconData      icon,
            required String        label,
            required String        description,
            required Color         color,
          }) {
            final isSelected = _priority == value;
            return GestureDetector(
              onTap: () {
                setSheetState(() {});
                setState(() => _priority = value);
                Navigator.pop(ctx);
                if (_origin != null && _destination != null) _maybeRunRouting();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin:   const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                padding:  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color:        isSelected ? color.withOpacity(0.08) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected ? color : Colors.grey.shade200,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color:  color.withOpacity(0.12),
                        shape:  BoxShape.circle,
                      ),
                      child: Icon(icon, color: color, size: 20),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label,
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize:   14,
                                  color: isSelected ? color : Colors.black87)),
                          const SizedBox(height: 2),
                          Text(description,
                              style: TextStyle(
                                  fontSize: 12,
                                  color:    Colors.grey[600])),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Icon(Icons.check_circle, color: color, size: 20),
                  ],
                ),
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(height: 16),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(Icons.tune, size: 18, color: Colors.black54),
                      SizedBox(width: 8),
                      Text('Route Priority',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize:   16,
                              color:      Colors.black87)),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('How should routes be ranked?',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                ),
                const SizedBox(height: 12),
                option(
                  value:       RoutePriority.balanced,
                  icon:        Icons.balance,
                  label:       'Balanced',
                  description: 'Default mix of walk and ride time',
                  color:       const Color(0xFF1A73E8),
                ),
                option(
                  value:       RoutePriority.time,
                  icon:        Icons.access_time,
                  label:       'Fastest',
                  description: 'Prioritise shorter total trip time',
                  color:       const Color(0xFF34A853),
                ),
                option(
                  value:       RoutePriority.lessWalk,
                  icon:        Icons.directions_walk,
                  label:       'Less Walking',
                  description: 'Minimise total walking distance',
                  color:       const Color(0xFFEA4335),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final hasResult = _routingResult != null;

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
                urlTemplate: _roadsOnly
                    ? 'https://cartodb-basemaps-a.global.ssl.fastly.net/'
                      'rastertiles/voyager_nolabels/{z}/{x}/{y}.png'
                    : 'https://cartodb-basemaps-a.global.ssl.fastly.net/'
                      'light_all/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mapapp',
              ),
              if (_nearbyPolylines.isNotEmpty)
                PolylineLayer(polylines: _nearbyPolylines),
              if (_isRecording && _recordedPath.length >= 2)
                PolylineLayer(polylines: [
                  Polyline(
                    points:      _recordedPath,
                    color:       const Color(0xFF1A73E8),
                    strokeWidth: 4,
                    strokeCap:   StrokeCap.round,
                    strokeJoin:  StrokeJoin.round,
                  ),
                ]),
              if (_journeyPolylines.isNotEmpty)
                PolylineLayer(polylines: _journeyPolylines),
              MarkerLayer(markers: [
                if (_userLocation != null)
                  Marker(
                    point:  _userLocation!,
                    width:  44,
                    height: 44,
                    child:  const RfUserLocationMarker(),
                  ),
                ..._abMarkers,
                ..._stopMarkers,
                ..._transferMarkers,
              ]),
            ],
          ),

          if (!widget.routesReady)
            Positioned.fill(
              child: Container(
                color: Colors.white.withOpacity(0.82),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Loading jeepney routes…',
                        style: TextStyle(
                            fontSize:   14,
                            color:      Colors.black54,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),

          if (!_showResults && !_pinMode)
            Positioned(
              top: 48, left: 16, right: 16,
              child: RfSearchPanel(
                originCtrl:      _originCtrl,
                destCtrl:        _destCtrl,
                searchingOrigin: _searchingOrigin,
                searchingDest:   _searchingDest,
                onSearchOrigin:  () => _onSearch(forOrigin: true),
                onSearchDest:    () => _onSearch(forOrigin: false),
                onClearOrigin:   _clearOrigin,
                onClearDest:     _clearDest,
                onReset:         _resetAll,
                originFocusNode: _originFocusNode,
                destFocusNode:   _destFocusNode,
              ),
            ),

          // ── Floating prompts (Use current location + Drag pin) ───────────────
          // Shown below the search panel when a field is active.
          if (!_showResults && !_pinMode && (_originFieldFocused || _destFieldFocused))
            Positioned(
              top: 172, left: 16, right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // "Use current location" — only for origin, GPS available, no origin set
                  if (_originFieldFocused && _userLocation != null && _origin == null) ...[
                    GestureDetector(
                      onTap: _useCurrentLocation,
                      child: Material(
                        elevation:    3,
                        borderRadius: BorderRadius.circular(12),
                        color:        Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 11),
                          child: Row(
                            children: [
                              Container(
                                width: 30, height: 30,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF34A853).withOpacity(0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.my_location,
                                    color: Color(0xFF34A853), size: 17),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Use current location',
                                        style: TextStyle(
                                            fontSize:   14,
                                            fontWeight: FontWeight.w600,
                                            color:      Colors.black87)),
                                    Text('Set your GPS position as origin',
                                        style: TextStyle(
                                            fontSize: 11, color: Colors.grey)),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right,
                                  color: Colors.grey, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // "Drag pin on map" — shown for both origin and destination
                  GestureDetector(
                    onTap: () => _enterPinMode(
                        forOrigin: _originFieldFocused || !_destFieldFocused),
                    child: Material(
                      elevation:    3,
                      borderRadius: BorderRadius.circular(12),
                      color:        Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                        child: Row(
                          children: [
                            Container(
                              width: 30, height: 30,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A73E8).withOpacity(0.10),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.location_pin,
                                  color: Color(0xFF1A73E8), size: 17),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Drag pin on map',
                                      style: TextStyle(
                                          fontSize:   14,
                                          fontWeight: FontWeight.w600,
                                          color:      Colors.black87)),
                                  Text(
                                    _originFieldFocused || !_destFieldFocused
                                        ? 'Manually position origin on map'
                                        : 'Manually position destination on map',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.grey)),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right,
                                color: Colors.grey, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Record / End Route button ─────────────────────────────────────────
          if (hasResult &&
              !_originFieldFocused &&
              !_destFieldFocused &&
              !_showResults &&
              !_pinMode)
            Positioned(
              bottom: 80, left: 16,
              child: GestureDetector(
                onTap: _isRecording ? _endRecording : _startRecording,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:  const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color:        _isRecording
                        ? const Color(0xFFEA4335)
                        : const Color(0xFF1A73E8),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color:      (_isRecording
                            ? const Color(0xFFEA4335)
                            : const Color(0xFF1A73E8)).withOpacity(0.4),
                        blurRadius: 8,
                        offset:     const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isRecording
                            ? Icons.stop_circle_outlined
                            : Icons.fiber_manual_record,
                        color: Colors.white,
                        size:  16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isRecording ? 'End Route' : 'Record Route',
                        style: const TextStyle(
                            color:      Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize:   13),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Roads-only map toggle ─────────────────────────────────────────────
          if (!_showResults && !_pinMode)
            Positioned(
              bottom: hasResult ? 230 : 90,
              right: 16,
              child: FloatingActionButton.small(
                heroTag:         'roadsToggle',
                backgroundColor: _roadsOnly
                    ? const Color(0xFF1A73E8)
                    : Colors.white,
                foregroundColor: _roadsOnly
                    ? Colors.white
                    : Colors.black54,
                elevation:       3,
                onPressed: () => setState(() => _roadsOnly = !_roadsOnly),
                tooltip: _roadsOnly ? 'Show full map' : 'Roads only',
                child: Icon(
                  _roadsOnly ? Icons.map : Icons.add_road,
                  size: 20,
                ),
              ),
            ),

          // ── Priority filter button ────────────────────────────────────────────
          if (!_showResults && !_pinMode)
            Positioned(
              bottom: hasResult ? 282 : 142,
              right: 16,
              child: FloatingActionButton.small(
                heroTag:         'priorityFilter',
                backgroundColor: _priority != RoutePriority.balanced
                    ? const Color(0xFF1A73E8)
                    : Colors.white,
                foregroundColor: _priority != RoutePriority.balanced
                    ? Colors.white
                    : Colors.black54,
                elevation:       3,
                onPressed:       _showPrioritySheet,
                tooltip:         'Route priority',
                child: const Icon(Icons.tune, size: 20),
              ),
            ),

          // Nearby routes panel — shown when exactly one point is set
          if (_nearbyRoutes.isNotEmpty && !hasResult && !_routingBusy && !_showResults)
            Positioned(
              bottom: 16, left: 16, right: 16,
              child: RfNearbyRoutesPanel(
                results:          _nearbyRoutes,
                forOrigin:        _origin != null,
                selectedRouteId:  _selectedNearbyRouteId,
                onToggleRoute:    (id) => setState(() =>
                    _selectedNearbyRouteId =
                        _selectedNearbyRouteId == id ? null : id),
              ),
            ),

          if (!hasResult && !_showResults &&
              _origin == null && _destination == null)
            Positioned(
              bottom: 16, left: 16, right: 16,
              child: RfHintCard(
                text: _origin == null
                    ? 'Search above to set your Origin (A)'
                    : 'Search above to set your Destination (B)',
              ),
            ),

          if (_routingBusy)
            Positioned(
              bottom: 100, left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                      color:        Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                            color:      Colors.black12,
                            blurRadius: 8,
                            offset:     Offset(0, 3))
                      ]),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Finding routes…',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ),

          if (hasResult && !_showResults)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: RfRecommendationsSheet(
                result:            _routingResult!,
                selectedIndex:     _selectedRec,
                isMinimized:       _sheetMinimized,
                onToggleMinimized: () =>
                    setState(() => _sheetMinimized = !_sheetMinimized),
                onSelectIndex: (i) {
                  if (_isRecording && i != _selectedRec) _endRecording();
                  setState(() => _selectedRec = i);
                  _fitToJourney();
                  if (_routingResult is RoutingSuccess) {
                    final rec = (_routingResult as RoutingSuccess).recommendations[i];
                    _log(LogEntry(
                      type:    LogEventType.routeSelected,
                      message: 'Route ${i + 1} selected',
                      detail:  rec.segments.map((s) => s.route.routeId).join(' + '),
                    ));
                  }
                },
              ),
            ),

          // ── Pin mode overlay ──────────────────────────────────────────────────
          if (_pinMode) ...[
            // Top banner
            Positioned(
              top: 0, left: 0, right: 0,
              child: Material(
                elevation: 4,
                color:     Colors.white,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 10),
                    child: Row(
                      children: [
                        IconButton(
                          icon:      const Icon(Icons.close),
                          onPressed: _cancelPinMode,
                          tooltip:   'Cancel',
                        ),
                        Expanded(
                          child: Text(
                            _pinModeForOrigin
                                ? 'Move pin to set Origin'
                                : 'Move pin to set Destination',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize:   15,
                                fontWeight: FontWeight.w600,
                                color:      Colors.black87),
                          ),
                        ),
                        const SizedBox(width: 48), // balance the close button
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Centred crosshair pin — IgnorePointer so map gestures still work
            IgnorePointer(
              child: Center(
                child: RfMapPinWidget(
                    forOrigin: _pinModeForOrigin),
              ),
            ),

            // Bottom confirm bar
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Material(
                elevation: 8,
                color:     Colors.white,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: _reverseGeocoding
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 18, height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  SizedBox(width: 12),
                                  Text('Getting location name…',
                                      style: TextStyle(fontSize: 14)),
                                ],
                              ),
                            ),
                          )
                        : SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: _confirmPin,
                              icon:  const Icon(Icons.check_circle_outline),
                              label: Text(
                                  'Confirm ${_pinModeForOrigin ? 'Origin' : 'Destination'}'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _pinModeForOrigin
                                    ? const Color(0xFF34A853)
                                    : const Color(0xFFEA4335),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],

          if (_showResults)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: RfResultsPanel(
                results:   _searchResults,
                forOrigin: _pendingForOrigin ?? true,
                onSelect:  _onResultPicked,
                onDismiss: _dismissResults,
              ),
            ),

        ],
      ),
    );
  }
}