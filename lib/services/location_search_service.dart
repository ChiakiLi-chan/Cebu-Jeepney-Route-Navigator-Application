// lib/services/nominatim_service.dart
//
// NominatimService — handles all Nominatim geocoding queries.
// Pure Dart, zero Flutter/widget imports. Fully testable in isolation.
//
// Responsibilities:
//   • Build and execute Nominatim search requests
//   • Filter out irrelevant result types (houses, buildings)
//   • Sort results by relevance score then proximity to user
//   • Return typed SearchResult objects

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

// ─── Result type ──────────────────────────────────────────────────────────────

class SearchResult {
  /// Full Nominatim display name e.g. "SM City Cebu, Cebu City, Central Visayas"
  final String displayName;

  /// First segment only e.g. "SM City Cebu" — used as the field label
  final String shortName;

  final LatLng point;

  /// Straight-line distance from the user's GPS location.
  /// [double.infinity] when GPS is unavailable.
  final double distanceMeters;

  const SearchResult({
    required this.displayName,
    required this.shortName,
    required this.point,
    required this.distanceMeters,
  });
}

// ─── Service ──────────────────────────────────────────────────────────────────

class NominatimService {
  // Cebu bounding box — keeps results local to the app's service area
  static const double _minLon = 123.65;
  static const double _maxLon = 124.10;
  static const double _minLat = 9.90;
  static const double _maxLat = 10.75;

  static const _dist = Distance();

  /// Search Nominatim for [query], bounded to Cebu.
  ///
  /// [userLocation] is optional — when provided, results are secondarily
  /// sorted by proximity so nearer places rank higher on equal relevance.
  ///
  /// Returns an empty list on network error or no results.
  Future<List<SearchResult>> search(
    String query, {
    LatLng? userLocation,
  }) async {
    if (query.trim().isEmpty) return [];

    final url =
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}'
        '&format=json'
        '&limit=10'
        '&bounded=1'
        '&viewbox=$_minLon,$_maxLat,$_maxLon,$_minLat'
        '&addressdetails=1';

    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'FlutterMapNavApp/1.0'},
      );
      if (resp.statusCode != 200) return [];

      final data = jsonDecode(resp.body) as List;
      if (data.isEmpty) return [];

      final results = data
          .where((item) {
            // Filter out street-level noise that clutters the list
            final type = (item['type'] as String? ?? '').toLowerCase();
            return type != 'house' && type != 'building';
          })
          .map((item) {
            final pt = LatLng(
              double.parse(item['lat'] as String),
              double.parse(item['lon'] as String),
            );
            final display = item['display_name'] as String;
            return SearchResult(
              displayName:    display,
              shortName:      display.split(',').first.trim(),
              point:          pt,
              distanceMeters: userLocation != null
                  ? _dist.as(LengthUnit.Meter, userLocation, pt)
                  : double.infinity,
            );
          })
          .toList();

      results.sort((a, b) {
        final sa = _relevance(a.displayName, query);
        final sb = _relevance(b.displayName, query);
        // Primary: relevance descending
        if (sb != sa) return sb.compareTo(sa);
        // Secondary: distance ascending
        return a.distanceMeters.compareTo(b.distanceMeters);
      });

      return results;
    } catch (_) {
      return [];
    }
  }

  // ── Relevance scorer ──────────────────────────────────────────────────────
  //
  // Scores how well the first segment of [displayName] matches [query].
  //
  //   5 — exact match
  //   4 — starts with query
  //   3 — contains query at a word boundary
  //   2 — contains query anywhere
  //   1 — fallback

  int _relevance(String displayName, String query) {
    final name = displayName.split(',').first.trim().toLowerCase();
    final q    = query.trim().toLowerCase();
    if (name == q)          return 5;
    if (name.startsWith(q)) return 4;
    if (name.contains(q)) {
      final i = name.indexOf(q);
      return (i == 0 || name[i - 1] == ' ') ? 3 : 2;
    }
    return 1;
  }
}