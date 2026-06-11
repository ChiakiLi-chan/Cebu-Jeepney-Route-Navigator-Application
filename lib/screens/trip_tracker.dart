// lib/screens/trip_tracker.dart

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:thesis_app/services/pdf_exporter.dart';

// ══════════════════════════════════════════════════════════════════════════════
// TRIP RECORD MODEL
// ══════════════════════════════════════════════════════════════════════════════

class TripRecord {
  final String       routeCode;
  final String       routeName;
  final Color        routeColor;
  final DateTime     startTime;
  final DateTime     endTime;
  final List<LatLng> gpsPath;
  final List<LatLng> expectedPath;
  final double       accuracyPercent;

  const TripRecord({
    required this.routeCode,
    required this.routeName,
    required this.routeColor,
    required this.startTime,
    required this.endTime,
    required this.gpsPath,
    required this.expectedPath,
    required this.accuracyPercent,
  });

  Duration get duration => endTime.difference(startTime);

  String get formattedDuration {
    final d = duration;
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }

  String get formattedDateTime {
    final t = startTime;
    final hour   = t.hour.toString().padLeft(2, '0');
    final minute = t.minute.toString().padLeft(2, '0');
    final month  = _monthAbbr(t.month);
    return '$month ${t.day}, ${t.year}  $hour:$minute';
  }

  static String _monthAbbr(int m) => const [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ][m];
}

// ══════════════════════════════════════════════════════════════════════════════
// TRIP TRACKER PAGE  — list of completed trips
// ══════════════════════════════════════════════════════════════════════════════

class TripTrackerPage extends StatelessWidget {
  final List<TripRecord> trips;

  const TripTrackerPage({super.key, required this.trips});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              color:   Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
              child: Row(
                children: [
                  const Icon(Icons.route, color: Color(0xFF1A73E8), size: 20),
                  const SizedBox(width: 10),
                  const Text('Trip Tracker',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize:   17,
                          color:      Colors.black87)),
                  const Spacer(),
                  if (trips.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => PdfExporter.exportTrips(trips),
                      icon:  const Icon(Icons.picture_as_pdf, size: 16),
                      label: const Text('Export',
                          style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF1A73E8)),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Trip list
            Expanded(
              child: trips.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.directions_bus_outlined,
                              size: 52, color: Colors.grey),
                          SizedBox(height: 14),
                          Text('No trips recorded yet',
                              style: TextStyle(
                                  color:    Colors.grey,
                                  fontSize: 15)),
                          SizedBox(height: 6),
                          Text(
                            'Tap "Record Route" in the Route Finder\nto start tracking a journey.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color:    Colors.grey,
                                fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding:          const EdgeInsets.all(16),
                      itemCount:        trips.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, i) {
                        final trip = trips[trips.length - 1 - i]; // newest first
                        return _TripSummaryCard(
                          trip:    trip,
                          onTap:   () => Navigator.push(ctx,
                            MaterialPageRoute(
                              builder: (_) => TripDetailPage(trip: trip),
                            )),
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

// ── Summary card ──────────────────────────────────────────────────────────────

class _TripSummaryCard extends StatelessWidget {
  final TripRecord  trip;
  final VoidCallback onTap;

  const _TripSummaryCard({required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final acc       = trip.accuracyPercent;
    final accColor  = acc >= 80 ? const Color(0xFF0F9D58)
                    : acc >= 50 ? const Color(0xFFF9A825)
                    :             const Color(0xFFEA4335);

    return Material(
      color:        Colors.white,
      borderRadius: BorderRadius.circular(14),
      elevation:    2,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap:        onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Route circle
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                    color: trip.routeColor, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(trip.routeCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color:      Colors.white,
                        fontSize:   8,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),

              // Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(trip.routeCode,
                        style: const TextStyle(
                            fontSize:   14,
                            fontWeight: FontWeight.bold,
                            color:      Colors.black87)),
                    const SizedBox(height: 2),
                    Text(trip.formattedDateTime,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[600])),
                  ],
                ),
              ),

              // Stats
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Accuracy
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color:        accColor.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(8),
                        border:       Border.all(
                            color: accColor.withOpacity(0.35))),
                    child: Text('${acc.toStringAsFixed(1)}%',
                        style: TextStyle(
                            fontSize:   11,
                            fontWeight: FontWeight.bold,
                            color:      accColor)),
                  ),
                  const SizedBox(height: 4),
                  // Duration
                  Text(trip.formattedDuration,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey[500])),
                ],
              ),

              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TRIP DETAIL PAGE
// ══════════════════════════════════════════════════════════════════════════════

class TripDetailPage extends StatelessWidget {
  final TripRecord trip;

  const TripDetailPage({super.key, required this.trip});

  static const _onRouteThreshold = 20.0; // metres

  // Segment each GPS point as on/off route
  List<_GpsSegment> _buildSegments() {
    const d  = Distance();
    final segs = <_GpsSegment>[];
    _GpsSegment? current;

    for (final pt in trip.gpsPath) {
      double minD = double.infinity;
      for (final rpt in trip.expectedPath) {
        final dist = d.as(LengthUnit.Meter, pt, rpt);
        if (dist < minD) minD = dist;
      }
      final onRoute = minD <= _onRouteThreshold;

      if (current == null || current.onRoute != onRoute) {
        current = _GpsSegment(onRoute: onRoute, points: [pt]);
        segs.add(current);
      } else {
        current.points.add(pt);
      }
    }
    return segs;
  }

  LatLng _center() {
    if (trip.gpsPath.isNotEmpty) {
      double minLat = trip.gpsPath.first.latitude,
             maxLat = trip.gpsPath.first.latitude,
             minLon = trip.gpsPath.first.longitude,
             maxLon = trip.gpsPath.first.longitude;
      for (final p in trip.gpsPath) {
        if (p.latitude  < minLat) minLat = p.latitude;
        if (p.latitude  > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
      return LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
    }
    return const LatLng(10.3157, 123.8854);
  }

  @override
  Widget build(BuildContext context) {
    final acc      = trip.accuracyPercent;
    final accColor = acc >= 80 ? const Color(0xFF0F9D58)
                   : acc >= 50 ? const Color(0xFFF9A825)
                   :             const Color(0xFFEA4335);
    final segments = _buildSegments();
    final offRouteCount = segments.where((s) => !s.onRoute).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(trip.routeCode,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: trip.routeColor,
        foregroundColor: Colors.white,
        elevation:       0,
      ),
      body: Column(
        children: [
          // Map
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.42,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: _center(),
                initialZoom:   14,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://cartodb-basemaps-a.global.ssl.fastly.net/'
                      'light_all/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.mapapp',
                ),

                // Expected route (faded)
                if (trip.expectedPath.isNotEmpty)
                  PolylineLayer(polylines: [
                    Polyline(
                      points:      trip.expectedPath,
                      color:       trip.routeColor.withOpacity(0.30),
                      strokeWidth: 5,
                      strokeCap:   StrokeCap.round,
                    ),
                  ]),

                // GPS path — on-route = blue, off-route = orange
                PolylineLayer(
                  polylines: segments.map((s) => Polyline(
                    points:      s.points,
                    color:       s.onRoute
                        ? const Color(0xFF1A73E8)
                        : Colors.orange,
                    strokeWidth: 3.5,
                    strokeCap:   StrokeCap.round,
                    strokeJoin:  StrokeJoin.round,
                  )).toList(),
                ),

                // Start / end markers
                MarkerLayer(markers: [
                  if (trip.gpsPath.isNotEmpty)
                    Marker(
                      point:  trip.gpsPath.first,
                      width:  32, height: 32,
                      child: Container(
                        decoration: BoxDecoration(
                            color:  const Color(0xFF34A853),
                            shape:  BoxShape.circle,
                            border: Border.all(
                                color: Colors.white, width: 2)),
                        child: const Icon(Icons.trip_origin,
                            color: Colors.white, size: 14),
                      ),
                    ),
                  if (trip.gpsPath.length > 1)
                    Marker(
                      point:  trip.gpsPath.last,
                      width:  32, height: 32,
                      child: Container(
                        decoration: BoxDecoration(
                            color:  const Color(0xFFEA4335),
                            shape:  BoxShape.circle,
                            border: Border.all(
                                color: Colors.white, width: 2)),
                        child: const Icon(Icons.place,
                            color: Colors.white, size: 14),
                      ),
                    ),
                ]),
              ],
            ),
          ),

          // Map legend
          Container(
            color:   Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                _LegendItem(color: trip.routeColor.withOpacity(0.30),
                    label: 'Expected route'),
                const SizedBox(width: 16),
                _LegendItem(color: const Color(0xFF1A73E8),
                    label: 'On route'),
                const SizedBox(width: 16),
                _LegendItem(color: Colors.orange,
                    label: 'Off route'),
              ],
            ),
          ),
          const Divider(height: 1),

          // Stats + discrepancies
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // Stat chips row
                  Row(
                    children: [
                      Expanded(child: _StatCard(
                          icon:  Icons.check_circle_outline,
                          label: 'Accuracy',
                          value: '${acc.toStringAsFixed(1)}%',
                          color: accColor)),
                      const SizedBox(width: 10),
                      Expanded(child: _StatCard(
                          icon:  Icons.access_time,
                          label: 'Duration',
                          value: trip.formattedDuration,
                          color: const Color(0xFF1A73E8))),
                      const SizedBox(width: 10),
                      Expanded(child: _StatCard(
                          icon:  Icons.location_on_outlined,
                          label: 'GPS Points',
                          value: '${trip.gpsPath.length}',
                          color: Colors.grey[600]!)),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Route info
                  Container(
                    padding:    const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                              color:      Colors.black.withOpacity(0.05),
                              blurRadius: 4,
                              offset:     const Offset(0, 2))
                        ]),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Route',
                            style: TextStyle(
                                fontSize:   12,
                                fontWeight: FontWeight.bold,
                                color:      Colors.black54)),
                        const SizedBox(height: 4),
                        Text(trip.routeName,
                            style: const TextStyle(
                                fontSize: 14, color: Colors.black87)),
                        const SizedBox(height: 8),
                        const Text('Started',
                            style: TextStyle(
                                fontSize:   12,
                                fontWeight: FontWeight.bold,
                                color:      Colors.black54)),
                        const SizedBox(height: 4),
                        Text(trip.formattedDateTime,
                            style: const TextStyle(
                                fontSize: 13, color: Colors.black87)),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Discrepancies
                  const Text('Discrepancies',
                      style: TextStyle(
                          fontSize:   14,
                          fontWeight: FontWeight.bold,
                          color:      Colors.black87)),
                  const SizedBox(height: 8),

                  if (offRouteCount == 0)
                    Container(
                      padding:    const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color:        const Color(0xFF0F9D58).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border:       Border.all(
                              color: const Color(0xFF0F9D58).withOpacity(0.3))),
                      child: const Row(
                        children: [
                          Icon(Icons.check_circle,
                              color: Color(0xFF0F9D58), size: 18),
                          SizedBox(width: 8),
                          Text('No discrepancies detected',
                              style: TextStyle(
                                  color:    Color(0xFF0F9D58),
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    )
                  else
                    ...segments
                        .where((s) => !s.onRoute && s.points.length >= 2)
                        .toList()
                        .asMap()
                        .entries
                        .map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Container(
                            padding:    const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color:        Colors.orange.withOpacity(0.07),
                                borderRadius: BorderRadius.circular(10),
                                border:       Border.all(
                                    color: Colors.orange.withOpacity(0.3))),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.warning_amber_rounded,
                                    color: Colors.orange, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Deviation ${e.key + 1} — '
                                        '${e.value.points.length} GPS points off route',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize:   12,
                                            color:      Colors.orange)),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Route ${trip.routeCode} deviated from '
                                        'expected path at this segment.',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color:    Colors.grey[700])),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────

class _GpsSegment {
  final bool        onRoute;
  final List<LatLng> points;
  _GpsSegment({required this.onRoute, required this.points});
}

class _LegendItem extends StatelessWidget {
  final Color  color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 20, height: 4,
        decoration: BoxDecoration(
            color:        color,
            borderRadius: BorderRadius.circular(2)),
      ),
      const SizedBox(width: 5),
      Text(label,
          style: TextStyle(fontSize: 10, color: Colors.grey[600])),
    ],
  );
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final Color    color;
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding:    const EdgeInsets.all(12),
    decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color:      Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset:     const Offset(0, 2))
        ]),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(
                fontSize:   16,
                fontWeight: FontWeight.bold,
                color:      color)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 10, color: Colors.grey[500])),
      ],
    ),
  );
}