import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

// ─── Jeepney Route Model ──────────────────────────────────────────────────────
class JeepneyRoute {
  final String      routeId;
  final String      routeName;
  final Color       color;
  final List<LatLng> path;

  /// True for modern/electric jeepneys (higher fare schedule).
  /// False (default) for traditional jeepneys.
  final bool isModern;

  const JeepneyRoute({
    required this.routeId,
    required this.routeName,
    required this.color,
    required this.path,
    this.isModern = false,
  });
}

// ─── Route Registry ───────────────────────────────────────────────────────────
// One entry per GeoJSON file. To add a new route:
//   1. Drop your .geojson file into assets/routes/
//   2. Register the asset in pubspec.yaml
//   3. Add one RouteEntry(...) line below — that's it.
class RouteEntry {
  final String assetPath;
  final String routeId;
  final String routeName;
  final Color  color;

  /// Set to true for modern/electric jeepneys.
  final bool isModern;

  const RouteEntry({
    required this.assetPath,
    required this.routeId,
    required this.routeName,
    required this.color,
    this.isModern = false,
  });
}

const List<RouteEntry> routeRegistry = [
  // ── Add / remove / reorder entries here freely ───────────────────────────
  
  RouteEntry(
    assetPath: 'assets/routes/test.geojson',
    routeId:   '01-K',
    routeName: 'Urgello – Colon - SM - North Terminal',
    color:     Color.fromARGB(255, 118, 6, 4), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_03A_Complete.geojson',
    routeId:   '03-A',
    routeName: 'Mabolo - Carbon via Panagda-it Manalili',
    color:     Color.fromARGB(255, 74, 58, 0) // red
  ),RouteEntry(
    assetPath: 'assets/routes/route_04L_Complete.geojson',
    routeId:   '04-L',
    routeName: 'Lahug - JY - SM - Ayala',
    color:     Color.fromARGB(255, 255, 149, 0), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_13B_Complete.geojson',
    routeId:   '13-B',
    routeName: 'Talamban – Carbon',
    color:     Color(0xFFE53935), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_13C_Complete.geojson',
    routeId:   '13-C',
    routeName: 'Talamban - Colon - Echavez',
    color:     Color.fromARGB(255, 5, 255, 222), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_17B_Complete.geojson',
    routeId:   '17-B/D',
    routeName: 'Apas - Lahug - Jones - Carbon',
    color:     Color.fromARGB(255, 255, 176, 80), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_17C_Complete.geojson',
    routeId:   '17-C',
    routeName: 'Apas - Lahug - Ramos - Carbon',
    color:     Color.fromARGB(255, 255, 115, 0), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_20A_Complete.geojson',
    routeId:   '20-A/B',
    routeName: 'Ibabao-Mandaue - Ayala',
    color:     Color.fromARGB(255, 184, 255, 18), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_22I_Complete.geojson',
    routeId:   '22-I',
    routeName: 'Country Mall - Mandaue',
    color:     Color.fromARGB(255, 112, 191, 255), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_62B_Complete.geojson',
    routeId:   '62-B',
    routeName: 'Pit-os - Talamban - Carbon',
    color:     Color.fromARGB(255, 0, 46, 252), // red
  ),
  RouteEntry(
    assetPath: 'assets/routes/route_62C_Complete.geojson',
    routeId:   '62-C',
    routeName: 'Pit-os - Talamban - Carbon',
    color:     Color.fromARGB(255, 255, 7, 251), // red
  ),
  // ↑ paste more RouteEntry(...) blocks here for routes 6–25
];

// ─── GeoJSON coordinate extractor ────────────────────────────────────────────
// Handles both LineString and MultiLineString geometries.
// GeoJSON stores coordinates as [longitude, latitude] — LatLng is reversed.
List<LatLng> _extractPath(Map<String, dynamic> geometry) {
  final type   = geometry['type'] as String? ?? '';
  final coords = geometry['coordinates'];

  if (type == 'LineString') {
    return (coords as List)
        .map((c) => LatLng(
              (c[1] as num).toDouble(), // lat
              (c[0] as num).toDouble(), // lon
            ))
        .toList();
  }

  if (type == 'MultiLineString') {
    // Flatten all segments into one continuous path
    final path = <LatLng>[];
    for (final segment in coords as List) {
      for (final c in segment as List) {
        path.add(LatLng(
          (c[1] as num).toDouble(),
          (c[0] as num).toDouble(),
        ));
      }
    }
    return path;
  }

  debugPrint('[GeoJSON] Unsupported geometry type: $type');
  return [];
}

// ─── Public loader: all routes ────────────────────────────────────────────────
// Used by the drawer to build the route list (metadata only, no path needed).
// Loads all GeoJSON files in parallel — call once in initState.
Future<List<JeepneyRoute>> loadJeepneyRoutes() async {
  final futures = routeRegistry.map((entry) => loadSingleRoute(entry));
  final results = await Future.wait(futures);
  final routes  = results.whereType<JeepneyRoute>().toList();
  debugPrint('[GeoJSON] Loaded ${routes.length} / ${routeRegistry.length} routes');
  return routes;
}

// ─── Public loader: one route on demand ──────────────────────────────────────
// Called when the user taps a route in the drawer.
// Returns null if the file is missing or malformed.
Future<JeepneyRoute?> loadSingleRoute(RouteEntry entry) async {
  try {
    final rawJson = await rootBundle.loadString(entry.assetPath);
    final geojson = jsonDecode(rawJson) as Map<String, dynamic>;

    Map<String, dynamic> geometry;
    final type = geojson['type'] as String? ?? '';

    if (type == 'FeatureCollection') {
      final features = geojson['features'] as List;
      if (features.isEmpty) {
        debugPrint('[GeoJSON] ${entry.assetPath} — FeatureCollection is empty');
        return null;
      }
      geometry = (features.first as Map<String, dynamic>)['geometry']
          as Map<String, dynamic>;
    } else if (type == 'Feature') {
      geometry = geojson['geometry'] as Map<String, dynamic>;
    } else {
      geometry = geojson;
    }

    final path = _extractPath(geometry);
    if (path.isEmpty) {
      debugPrint('[GeoJSON] ${entry.assetPath} — path is empty, skipping');
      return null;
    }

    debugPrint('[GeoJSON] ✓ ${entry.routeId} "${entry.routeName}" '
        '— ${path.length} points');

    return JeepneyRoute(
      routeId:   entry.routeId,
      routeName: entry.routeName,
      color:     entry.color,
      path:      path,
      isModern:  entry.isModern,
    );
  } catch (e) {
    debugPrint('[GeoJSON] ✗ Failed to load ${entry.assetPath}: $e');
    return null;
  }
}

// ─── pubspec.yaml asset registration ─────────────────────────────────────────
// Add this block under the flutter: section in pubspec.yaml:
//
//   flutter:
//     assets:
//       - assets/routes/route_01c.geojson
//       - assets/routes/route_04a.geojson
//       - assets/routes/route_06b.geojson
//       - assets/routes/route_10c.geojson
//       - assets/routes/route_62c.geojson
//
// Or use a folder wildcard (Flutter ≥ 3.19):
//   flutter:
//     assets:
//       - assets/routes/