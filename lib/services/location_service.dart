// lib/services/location_service.dart
//
// LocationService — pure-Dart helper for GPS and Nominatim.
// Zero widget imports. Used by both the picker flow and RouteFinderPage.

import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

// ─── Search result ────────────────────────────────────────────────────────────

class LocationResult {
  final String displayName;
  final String shortName;   // first segment before the first comma
  final LatLng point;
  final double distanceMeters;

  const LocationResult({
    required this.displayName,
    required this.shortName,
    required this.point,
    required this.distanceMeters,
  });
}

// ─── GPS result ───────────────────────────────────────────────────────────────

sealed class GpsResult {}
class GpsSuccess extends GpsResult { final LatLng point; GpsSuccess(this.point); }
class GpsDenied  extends GpsResult { GpsDenied(); }
class GpsError   extends GpsResult { final String message; GpsError(this.message); }

// ─── Service ──────────────────────────────────────────────────────────────────

class LocationService {
  // Cebu bounding box for Nominatim viewbox
  static const double _minLon = 123.65;
  static const double _maxLon = 124.10;
  static const double _minLat = 9.90;
  static const double _maxLat = 10.75;

  // ── GPS ───────────────────────────────────────────────────────────────────

  /// Request GPS permission if needed, then return current position.
  Future<GpsResult> getCurrentLocation() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return GpsDenied();
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
      return GpsSuccess(LatLng(pos.latitude, pos.longitude));
    } catch (e) {
      return GpsError(e.toString());
    }
  }

  // ── Nominatim ─────────────────────────────────────────────────────────────

  /// Search Nominatim for [query], bounded to Cebu.
  /// Results are sorted by relevance then proximity to [userLocation].
  Future<List<LocationResult>> search(
    String query, {
    LatLng? userLocation,
  }) async {
    if (query.trim().isEmpty) return [];
    final url = 'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}'
        '&format=json&limit=10&bounded=1'
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

      const dc = Distance();
      final results = data
          .where((item) {
            final t = (item['type'] as String? ?? '').toLowerCase();
            return t != 'house' && t != 'building';
          })
          .map((item) {
            final pt = LatLng(
              double.parse(item['lat'] as String),
              double.parse(item['lon'] as String),
            );
            final display = item['display_name'] as String;
            return LocationResult(
              displayName:    display,
              shortName:      display.split(',').first.trim(),
              point:          pt,
              distanceMeters: userLocation != null
                  ? dc.as(LengthUnit.Meter, userLocation, pt)
                  : double.infinity,
            );
          })
          .toList();

      results.sort((a, b) {
        final sa = _relevance(a.displayName, query);
        final sb = _relevance(b.displayName, query);
        return sb != sa
            ? sb.compareTo(sa)
            : a.distanceMeters.compareTo(b.distanceMeters);
      });
      return results;
    } catch (_) {
      return [];
    }
  }

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