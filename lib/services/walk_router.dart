// lib/services/walk_router.dart
//
// Dijkstra on the pedestrian road graph (WalkGraph).
//
// Two result types:
//   WalkDistanceMap  — full result, holds WalkGraph reference, main thread only.
//                      Used for polyline reconstruction after routing.
//   SerialWalkMap    — lightweight serialisable form, safe to pass into isolates.
//                      Contains only the dist array + snap metadata needed for
//                      scoring inside the routing isolate.

import 'package:latlong2/latlong.dart';
import 'package:thesis_app/data/jeepney_routes.dart';
import 'walk_graph.dart';

// ══════════════════════════════════════════════════════════════════════════════
// RESULT TYPES
// ══════════════════════════════════════════════════════════════════════════════

class WalkResult {
  final double       distanceMeters;
  final List<LatLng> polyline;
  final bool         isRoadPath;
  const WalkResult({
    required this.distanceMeters,
    required this.polyline,
    required this.isRoadPath,
  });
}

/// Full walk distance map — lives on the main thread.
/// Holds a reference to WalkGraph for nearest-node lookups and polyline build.
class WalkDistanceMap {
  final WalkGraph    _graph;
  final LatLng       _source;
  final int          _sourceNode;
  final List<double> _dist;
  final List<int>    _prev;

  const WalkDistanceMap._(
      this._graph, this._source, this._sourceNode, this._dist, this._prev);

  /// Road distance from source to [point]. Returns infinity if unreachable.
  double distanceTo(LatLng point) {
    final nodeId  = _graph.nearestNode(point);
    final snapSrc = _haversine(_source, _graph.nodePoint(_sourceNode));
    final snapDst = _haversine(point,   _graph.nodePoint(nodeId));
    final road    = _dist[nodeId];
    if (road.isInfinite) return double.infinity;
    return snapSrc + road + snapDst;
  }

  /// Road polyline from source to [point]. Falls back to straight line.
  WalkResult pathTo(LatLng point) {
    final toId = _graph.nearestNode(point);
    final road = _dist[toId];

    if (road.isInfinite) {
      return WalkResult(
        distanceMeters: _haversine(_source, point),
        polyline:       [_source, point],
        isRoadPath:     false,
      );
    }

    final path = <int>[];
    int cur = toId;
    while (cur != -1 && cur != _sourceNode) {
      path.add(cur);
      cur = _prev[cur];
    }
    path.add(_sourceNode);

    final polyline = <LatLng>[_source];
    for (final id in path.reversed) polyline.add(_graph.nodePoint(id));
    polyline.add(point);

    final snapSrc = _haversine(_source, _graph.nodePoint(_sourceNode));
    final snapDst = _haversine(point,   _graph.nodePoint(toId));

    return WalkResult(
      distanceMeters: snapSrc + road + snapDst,
      polyline:       polyline,
      isRoadPath:     true,
    );
  }

  /// Convert to a serialisable form for passing into compute() isolates.
  /// Pre-snaps all route path points to their nearest walk graph nodes using
  /// the grid index — O(1) per point. The isolate then does pure array lookups.
  SerialWalkMap toSerial(List<JeepneyRoute> allRoutes) {
    final cache = <String, int>{};
    for (final route in allRoutes) {
      for (int i = 0; i < route.path.length; i++) {
        final nodeId = _graph.nearestNode(route.path[i]);
        cache['${route.routeId}:$i'] = nodeId;
      }
    }
    return SerialWalkMap(
      snapDist:  _haversine(_source, _graph.nodePoint(_sourceNode)),
      dist:      _dist,
      nodeCache: cache,
    );
  }

  static double _haversine(LatLng a, LatLng b) =>
      const Distance().as(LengthUnit.Meter, a, b);
}

/// Serialisable walk distance map — safe to pass through compute() boundaries.
/// 
/// The main thread pre-snaps all jeepney route path points to their nearest
/// walk graph nodes (using the grid-indexed WalkGraph) before building this.
/// Inside the isolate, distanceTo() is a pure O(1) array lookup — no scanning.
class SerialWalkMap {
  final double       snapDist;    // snap from source point to sourceNode
  final List<double> dist;        // road distance from sourceNode to every node

  // Pre-snapped node IDs for every route path point.
  // Key: "routeId:pathIndex", Value: nearest walk graph node id.
  final Map<String, int> nodeCache;

  const SerialWalkMap({
    required this.snapDist,
    required this.dist,
    required this.nodeCache,
  });

  /// Road distance from source to a jeepney route path point.
  /// [routeId] and [pathIndex] identify the stop; [fallback] is Haversine.
  double distanceTo(String routeId, int pathIndex, double fallback) {
    final nodeId  = nodeCache['$routeId:$pathIndex'];
    if (nodeId == null) return fallback;
    final road = dist[nodeId];
    if (road.isInfinite) return fallback;
    // snapDist: source→sourceNode already baked in during singleSource.
    // snapDst: nodePoint→stop — approximated as 0 since stop IS on the road.
    return snapDist + road;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ROUTER
// ══════════════════════════════════════════════════════════════════════════════

class WalkRouter {
  final WalkGraph graph;
  const WalkRouter(this.graph);

  /// Radius-bounded single-source Dijkstra from [source].
  /// Only explores nodes within [radiusMeters] — fast local search.
  static WalkDistanceMap? singleSource({
    required LatLng source,
    WalkGraph?      graph,
    double          radiusMeters = 500.0,
  }) {
    if (graph == null) return null;
    return WalkRouter(graph)._singleSourceDijkstra(source, radiusMeters);
  }

  WalkDistanceMap _singleSourceDijkstra(LatLng source, double radiusMeters) {
    final g        = graph;
    final sourceId = g.nearestNode(source);
    final n        = g.nodeCount;
    final dist     = List<double>.filled(n, double.infinity);
    final prev     = List<int>.filled(n, -1);
    dist[sourceId] = 0;

    final heap = _MinHeap();
    heap.push(0.0, sourceId);

    while (heap.isNotEmpty) {
      final top    = heap.pop();
      final cost   = top.cost;
      final nodeId = top.node;
      if (cost > dist[nodeId] + 0.5) continue;
      if (cost > radiusMeters) break;

      final start = g.adjOffset[nodeId];
      final end   = g.adjOffset[nodeId + 1];
      for (int ei = start; ei < end; ei++) {
        final nb      = g.adjTo[ei];
        final newCost = dist[nodeId] + g.adjDist[ei];
        if (newCost < dist[nb]) {
          dist[nb] = newCost;
          prev[nb] = nodeId;
          heap.push(newCost, nb);
        }
      }
    }

    return WalkDistanceMap._(g, source, sourceId, dist, prev);
  }

  /// Point-to-point Dijkstra — used for transfer walk legs where no
  /// pre-computed map covers the intermediate points.
  static WalkResult route({
    required LatLng from,
    required LatLng to,
    WalkGraph?      graph,
  }) {
    if (graph == null) return _fallback(from, to);
    return WalkRouter(graph)._dijkstra(from, to);
  }

  WalkResult _dijkstra(LatLng from, LatLng to) {
    final g      = graph;
    final fromId = g.nearestNode(from);
    final toId   = g.nearestNode(to);

    if (fromId == toId) {
      return WalkResult(
        distanceMeters: _haversine(from, to),
        polyline:       [from, to],
        isRoadPath:     false,
      );
    }

    final n      = g.nodeCount;
    final dist   = List<double>.filled(n, double.infinity);
    final prev   = List<int>.filled(n, -1);
    dist[fromId] = 0;

    final heap = _MinHeap();
    heap.push(0.0, fromId);

    while (heap.isNotEmpty) {
      final top    = heap.pop();
      final cost   = top.cost;
      final nodeId = top.node;
      if (cost > dist[nodeId] + 0.5) continue;
      if (nodeId == toId) break;

      final start = g.adjOffset[nodeId];
      final end   = g.adjOffset[nodeId + 1];
      for (int ei = start; ei < end; ei++) {
        final nb      = g.adjTo[ei];
        final newCost = dist[nodeId] + g.adjDist[ei];
        if (newCost < dist[nb]) {
          dist[nb] = newCost;
          prev[nb] = nodeId;
          heap.push(newCost, nb);
        }
      }
    }

    if (dist[toId].isInfinite) return _fallback(from, to);

    final path = <int>[];
    int cur = toId;
    while (cur != -1) { path.add(cur); cur = prev[cur]; }

    final polyline = <LatLng>[from];
    for (final id in path.reversed) polyline.add(g.nodePoint(id));
    polyline.add(to);

    final snapFrom = _haversine(from, g.nodePoint(fromId));
    final snapTo   = _haversine(to,   g.nodePoint(toId));

    return WalkResult(
      distanceMeters: snapFrom + dist[toId] + snapTo,
      polyline:       polyline,
      isRoadPath:     true,
    );
  }

  static WalkResult _fallback(LatLng from, LatLng to) => WalkResult(
    distanceMeters: const Distance().as(LengthUnit.Meter, from, to),
    polyline:       [from, to],
    isRoadPath:     false,
  );

  static double _haversine(LatLng a, LatLng b) =>
      const Distance().as(LengthUnit.Meter, a, b);
}

// ── Typed heap entry ──────────────────────────────────────────────────────────

class _Entry {
  final double cost;
  final int    node;
  const _Entry(this.cost, this.node);
}

class _MinHeap {
  final _data = <_Entry>[];
  bool get isNotEmpty => _data.isNotEmpty;

  void push(double cost, int node) {
    _data.add(_Entry(cost, node));
    _bubbleUp(_data.length - 1);
  }

  _Entry pop() {
    final top  = _data[0];
    final last = _data.removeLast();
    if (_data.isNotEmpty) { _data[0] = last; _sinkDown(0); }
    return top;
  }

  void _bubbleUp(int i) {
    while (i > 0) {
      final p = (i - 1) ~/ 2;
      if (_data[i].cost < _data[p].cost) {
        final tmp = _data[i]; _data[i] = _data[p]; _data[p] = tmp;
        i = p;
      } else break;
    }
  }

  void _sinkDown(int i) {
    final n = _data.length;
    while (true) {
      int s = i;
      final l = 2*i+1, r = 2*i+2;
      if (l < n && _data[l].cost < _data[s].cost) s = l;
      if (r < n && _data[r].cost < _data[s].cost) s = r;
      if (s == i) break;
      final tmp = _data[i]; _data[i] = _data[s]; _data[s] = tmp;
      i = s;
    }
  }
}