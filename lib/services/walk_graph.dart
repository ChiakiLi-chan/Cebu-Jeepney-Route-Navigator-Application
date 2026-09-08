// lib/services/walk_graph.dart
//
// Pedestrian road graph loaded from the bundled OSM-derived asset.
// Includes a uniform grid spatial index for O(1) nearest-node lookup.
// JSON parsing runs in a background isolate via loadAssetInBackground().

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

// ══════════════════════════════════════════════════════════════════════════════
// SPATIAL GRID INDEX
// ══════════════════════════════════════════════════════════════════════════════

class _SpatialGrid {
  final double minLat, minLng;
  final double cellSizeLat, cellSizeLng;
  final int    rows, cols;
  final List<List<int>> cells;

  const _SpatialGrid({
    required this.minLat,      required this.minLng,
    required this.cellSizeLat, required this.cellSizeLng,
    required this.rows,        required this.cols,
    required this.cells,
  });

  factory _SpatialGrid.build(List<double> lats, List<double> lngs) {
    final n = lats.length;
    double minLat = lats[0], maxLat = lats[0];
    double minLng = lngs[0], maxLng = lngs[0];
    for (int i = 1; i < n; i++) {
      if (lats[i] < minLat) minLat = lats[i];
      if (lats[i] > maxLat) maxLat = lats[i];
      if (lngs[i] < minLng) minLng = lngs[i];
      if (lngs[i] > maxLng) maxLng = lngs[i];
    }

    const targetCellMeters = 100.0;
    const metersPerDegLat  = 111000.0;
    final metersPerDegLng  = 111000.0 * math.cos(minLat * math.pi / 180);

    final cellSizeLat = targetCellMeters / metersPerDegLat;
    final cellSizeLng = targetCellMeters / metersPerDegLng;

    final rows  = ((maxLat - minLat) / cellSizeLat).ceil() + 1;
    final cols  = ((maxLng - minLng) / cellSizeLng).ceil() + 1;
    final cells = List.generate(rows * cols, (_) => <int>[]);

    for (int i = 0; i < n; i++) {
      final r = ((lats[i] - minLat) / cellSizeLat).floor().clamp(0, rows - 1);
      final c = ((lngs[i] - minLng) / cellSizeLng).floor().clamp(0, cols - 1);
      cells[r * cols + c].add(i);
    }

    return _SpatialGrid(
      minLat: minLat, minLng: minLng,
      cellSizeLat: cellSizeLat, cellSizeLng: cellSizeLng,
      rows: rows, cols: cols, cells: cells,
    );
  }

  int nearest(List<double> lats, List<double> lngs, double lat, double lng) {
    int    best     = 0;
    double bestDist = double.infinity;
    final r0 = ((lat - minLat) / cellSizeLat).floor().clamp(0, rows - 1);
    final c0 = ((lng - minLng) / cellSizeLng).floor().clamp(0, cols - 1);

    for (int radius = 0; radius <= math.max(rows, cols); radius++) {
      for (int dr = -radius; dr <= radius; dr++) {
        for (int dc = -radius; dc <= radius; dc++) {
          if (dr.abs() != radius && dc.abs() != radius) continue;
          final r = r0 + dr;
          final c = c0 + dc;
          if (r < 0 || r >= rows || c < 0 || c >= cols) continue;
          for (final i in cells[r * cols + c]) {
            final dlat = lats[i] - lat;
            final dlng = lngs[i] - lng;
            final d    = dlat * dlat + dlng * dlng;
            if (d < bestDist) { bestDist = d; best = i; }
          }
        }
      }
      if (bestDist < double.infinity && radius > 0) break;
    }
    return best;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// WALK GRAPH
// ══════════════════════════════════════════════════════════════════════════════

class WalkGraph {
  final int          nodeCount;
  final List<double> lats;
  final List<double> lngs;
  final List<int>    adjTo;
  final List<int>    adjDist;
  final List<int>    adjOffset;
  final _SpatialGrid _grid;

  WalkGraph._({
    required this.nodeCount,
    required this.lats,
    required this.lngs,
    required this.adjTo,
    required this.adjDist,
    required this.adjOffset,
    required _SpatialGrid grid,
  }) : _grid = grid;

  factory WalkGraph.fromJson(Map<String, dynamic> j) {
    final lats      = (j['lats']       as List).cast<double>();
    final lngs      = (j['lngs']       as List).cast<double>();
    final adjTo     = (j['adj_to']     as List).map((e) => (e as num).toInt()).toList();
    final adjDist   = (j['adj_dist']   as List).map((e) => (e as num).toInt()).toList();
    final adjOffset = (j['adj_offset'] as List).map((e) => (e as num).toInt()).toList();
    final grid      = _SpatialGrid.build(lats, lngs);
    return WalkGraph._(
      nodeCount: (j['node_count'] as num).toInt(),
      lats: lats, lngs: lngs,
      adjTo: adjTo, adjDist: adjDist, adjOffset: adjOffset,
      grid: grid,
    );
  }

  /// Load from asset — JSON parsing runs in a background isolate.
  static Future<WalkGraph> loadAsset(
      [String path = 'assets/data/cebu_walk_graph.json']) async {
    final raw = await rootBundle.loadString(path);
    // Parse JSON in a background isolate so the main thread is never blocked.
    final json = await compute(_parseJson, raw);
    return WalkGraph.fromJson(json);
  }

  int nearestNode(LatLng point) =>
      _grid.nearest(lats, lngs, point.latitude, point.longitude);

  LatLng nodePoint(int i) => LatLng(lats[i], lngs[i]);
}

// Top-level function required by compute()
Map<String, dynamic> _parseJson(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;