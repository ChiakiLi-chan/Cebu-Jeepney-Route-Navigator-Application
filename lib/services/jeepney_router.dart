// lib/services/jeepney_router.dart
//
// Pure-Dart routing engine. Zero Flutter/widget imports.
//
// ── Single-route algorithm ────────────────────────────────────────────────────
//   1. Find nearest path point to Origin  → boardingIndex b, distance db
//   2. Find nearest path point to Dest    → dropoffIndex  d, distance dd
//   3. Reject if db > radiusMeters        → RejectionGate.originTooFar
//   4. Reject if dd > radiusMeters        → RejectionGate.destTooFar
//   5. Reject if b >= d AND non-circular  → RejectionGate.wrongDirection
//      For circular routes: allow wrap-around (b > d means ride past the end)
//   6. Reject if ride stop count < 2     → RejectionGate.rideTooShort
//   7. Score = db + dd + gapPenalty      (lower = better)
//
// ── Multi-transfer algorithm ──────────────────────────────────────────────────
//   1. Build graph: every route-path point is a node.
//   2. Connect stops within transferRadiusMeters with transfer edges.
//   3. Add virtual origin/destination nodes.
//   4. Run Dijkstra; backtrack to reconstruct RouteSegments.
//   5. Convert to RouteJourney, score, rank, return top N.

import 'package:latlong2/latlong.dart';
import 'package:thesis_app/data/jeepney_routes.dart';
import 'package:thesis_app/models/routing_models.dart';
import 'package:thesis_app/services/walk_router.dart';

// ══════════════════════════════════════════════════════════════════════════════
// GRAPH INTERNALS  (file-private)
// ══════════════════════════════════════════════════════════════════════════════

class _Node {
  final int    id;
  final LatLng point;
  final JeepneyRoute? route;
  final int? pathIndex;
  const _Node({required this.id, required this.point, this.route, this.pathIndex});
}

enum _EdgeKind { onRoute, transfer, walkToRoute }

class _Edge {
  final int      to;
  final double   cost;
  final _EdgeKind kind;
  const _Edge({required this.to, required this.cost, required this.kind});
}

class _Graph {
  final List<_Node>          nodes;
  final List<List<_Edge>>    adj;
  final int                  originId;
  final int                  destId;
  final Map<String, List<int>> routeNodeIds;
  final Map<String, int> routeIndex;
  const _Graph({
    required this.nodes, required this.adj, required this.originId,
    required this.destId, required this.routeNodeIds, required this.routeIndex,
  });
}

class _DState implements Comparable<_DState> {
  final int    nodeId;
  final double cost;
  final int    transfers;
  final int    routeMask;
  const _DState(this.nodeId, this.cost, this.transfers, [this.routeMask = 0]);
  @override
  int compareTo(_DState other) {
    final c = cost.compareTo(other.cost);
    return c != 0 ? c : transfers.compareTo(other.transfers);
  }
}

class _DResult {
  final List<double>   dist;
  final List<int>      prevKey;
  final int            stride;
  final int            maskRange;
  _DResult({required this.dist, required this.prevKey, required this.stride, required this.maskRange});
  int encode(int nodeId, int transfers, int routeMask) =>
      nodeId * stride + transfers * maskRange + routeMask;
}

// ══════════════════════════════════════════════════════════════════════════════
// PRECOMPUTED STATIC GRAPH
// ══════════════════════════════════════════════════════════════════════════════

class PrecomputedRouteGraph {
  final List<double>  nodeLats;
  final List<double>  nodeLngs;
  final List<String?> nodeRouteIds;
  final List<int?>    nodePathIndices;
  final List<List<int>>    adjTo;
  final List<List<double>> adjCost;
  final List<List<int>>    adjKind;
  final Map<String, List<int>> routeNodeIds;
  final Map<String, int> routeIndex;
  final int nodeCount;
  const PrecomputedRouteGraph({
    required this.nodeLats, required this.nodeLngs, required this.nodeRouteIds,
    required this.nodePathIndices, required this.adjTo, required this.adjCost,
    required this.adjKind, required this.routeNodeIds, required this.routeIndex,
    required this.nodeCount,
  });
}

/// User-selectable routing priority that adjusts scoring weights.
enum RoutePriority {
  balanced,  // default: walk×1.0 + ride×0.25
  time,      // shorter total trip: walk×1.0 + ride×0.5
  lessWalk,  // minimise walking: walk×2.0 + ride×0.1
}

class StaticGraphMessage {
  final List<JeepneyRoute> allRoutes;
  final double             transferRadiusMeters;
  final double             transferPenaltyMeters;
  const StaticGraphMessage({
    required this.allRoutes, required this.transferRadiusMeters,
    required this.transferPenaltyMeters,
  });
}

PrecomputedRouteGraph runStaticGraphIsolate(StaticGraphMessage msg) {
  final router = JeepneyRouter(
    transferRadiusMeters:  msg.transferRadiusMeters,
    transferPenaltyMeters: msg.transferPenaltyMeters,
  );
  return router.buildStaticGraph(msg.allRoutes);
}

// ══════════════════════════════════════════════════════════════════════════════
// ROUTER
// ══════════════════════════════════════════════════════════════════════════════

class JeepneyRouter {
  final double radiusMeters;
  final int    maxResults;
  final double transferRadiusMeters;
  final double transferPenaltyMeters;
  final int    maxTransfersAllowed;
  static const _dist = Distance();

  const JeepneyRouter({
    this.radiusMeters          = 350.0,
    this.maxResults            = 5,
    this.transferRadiusMeters  = 200.0,
    this.transferPenaltyMeters = 400.0,
    this.maxTransfersAllowed   = 2,
  });

  // ════════════════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ════════════════════════════════════════════════════════════════════════════

  RoutingResult findRoutes({
    required LatLng             origin,
    required LatLng             destination,
    required List<JeepneyRoute> allRoutes,
    bool                        allowTransfers = true,
    PrecomputedRouteGraph?      precomputed,
    RoutePriority               priority       = RoutePriority.balanced,
    SerialWalkMap?              originWalkMap,
    SerialWalkMap?              destWalkMap,
  }) {
    double walkWeight, rideWeight;
    switch (priority) {
      case RoutePriority.time:
        walkWeight = 1.0; rideWeight = 0.5;  break;
      case RoutePriority.lessWalk:
        walkWeight = 2.0; rideWeight = 0.1;  break;
      case RoutePriority.balanced:
      default:
        walkWeight = 1.0; rideWeight = 0.25; break;
    }

    if (_haversine(origin, destination) < 5) {
      return RoutingFailure('Origin and destination appear to be the same location.');
    }
    if (allRoutes.isEmpty) {
      return RoutingFailure('Route data is still loading. Please wait a moment.');
    }

    final singleResult = _trySingleRoute(origin, destination, allRoutes,
        walkWeight: walkWeight, rideWeight: rideWeight, priority: priority,
        originWalkMap: originWalkMap, destWalkMap: destWalkMap);

    if (!allowTransfers) {
      if (singleResult.candidates.isNotEmpty) {
        final journeys = singleResult.candidates.take(maxResults).map((rec) =>
            RouteJourney.fromSingleRoute(rec)).toList();
        return RoutingSuccess(journeys, hasTransfers: false);
      }
      return RoutingFailure(
        'No direct jeepney route found within ${radiusMeters.toInt()} m of both points.',
        rejections: singleResult.rejections,
      );
    }

    final multiJourneys = _tryMultiRoute(origin, destination, allRoutes,
        precomputed: precomputed, walkWeight: walkWeight, rideWeight: rideWeight,
        priority: priority, originWalkMap: originWalkMap, destWalkMap: destWalkMap);

    final allJourneys = <RouteJourney>[
      ...singleResult.candidates.map(RouteJourney.fromSingleRoute),
      ...multiJourneys,
    ];

    if (allJourneys.isEmpty) {
      return RoutingFailure(
        'No jeepney route found (including with transfers) within '
        '${radiusMeters.toInt()} m of both points.',
        rejections: singleResult.rejections,
      );
    }

    allJourneys.sort((a, b) => a.score.compareTo(b.score));

    const walkToleranceMultiplier = 2.0;
    const walkToleranceFloor      = 200.0;
    const walkAbsoluteCap         = 500.0;
    const walkIndependentCap      = 450.0;

    final bestJourney      = allJourneys.first;
    final bestFirstLegWalk = bestJourney.segments.first.walkToBoardingMeters;
    final bestLastLegWalk  = bestJourney.segments.last.walkFromDropoffMeters;

    final boardCeiling = (bestFirstLegWalk * walkToleranceMultiplier)
        .clamp(walkToleranceFloor, walkAbsoluteCap);
    final destCeiling  = (bestLastLegWalk * walkToleranceMultiplier)
        .clamp(walkToleranceFloor, walkAbsoluteCap);

    final directCandidates = { for (final c in singleResult.candidates) c.route.routeId: c };
    final directRouteIds   = directCandidates.keys.toSet();

    final seen    = <String>{};
    final ranked  = <RouteJourney>[];
    for (final j in allJourneys) {
      if (j.segments.first.walkToBoardingMeters > walkIndependentCap) continue;
      if (j.segments.last.walkFromDropoffMeters  > walkIndependentCap) continue;
      if (j.segments.first.walkToBoardingMeters > boardCeiling) continue;
      if (j.segments.last.walkFromDropoffMeters  > destCeiling)  continue;
      if (j.transferCount > 0 && directRouteIds.isNotEmpty) {
        final firstRouteId = j.segments.first.route.routeId;
        final lastRouteId  = j.segments.last.route.routeId;
        if (directRouteIds.contains(firstRouteId)) continue;
        if (directRouteIds.contains(lastRouteId)) {
          final directWalk = directCandidates[lastRouteId]!.walkToBoardingMeters;
          if (directWalk <= boardCeiling) continue;
        }
      }
      final key = j.segments.map((s) => s.route.routeId).join('+');
      if (seen.add(key)) ranked.add(j);
      if (ranked.length >= maxResults) break;
    }

    if (ranked.isEmpty && allJourneys.isNotEmpty) {
      final fallbackSeen = <String>{};
      for (final j in allJourneys) {
        final key = j.segments.map((s) => s.route.routeId).join('+');
        if (fallbackSeen.add(key)) ranked.add(j);
        if (ranked.length >= 2) break;
      }
      final hasTransfers = ranked.any((j) => j.transferCount > 0);
      return RoutingSuccess(ranked, hasTransfers: hasTransfers, isFallback: true);
    }

    final hasTransfers = ranked.any((j) => j.transferCount > 0);
    return RoutingSuccess(ranked, hasTransfers: hasTransfers);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // SINGLE-ROUTE
  // ════════════════════════════════════════════════════════════════════════════

  _SingleResult _trySingleRoute(
    LatLng origin, LatLng destination, List<JeepneyRoute> allRoutes, {
    double walkWeight = 1.0, double rideWeight = 0.25,
    RoutePriority priority = RoutePriority.balanced,
    SerialWalkMap? originWalkMap,
    SerialWalkMap? destWalkMap,
  }) {
    final candidates = <RouteRecommendation>[];
    final rejections = <RouteRejection>[];
    for (final route in allRoutes) {
      final r = _evaluate(route, origin, destination,
          walkWeight: walkWeight, rideWeight: rideWeight, priority: priority,
          originWalkMap: originWalkMap, destWalkMap: destWalkMap);
      if (r is _Pass) candidates.add(r.recommendation);
      else if (r is _Fail) rejections.add(r.rejection);
    }
    candidates.sort((a, b) => a.score.compareTo(b.score));
    return _SingleResult(candidates: candidates, rejections: rejections);
  }

  _EvalResult _evaluate(JeepneyRoute route, LatLng origin, LatLng dest, {
    double walkWeight = 1.0, double rideWeight = 0.25,
    RoutePriority priority = RoutePriority.balanced,
    SerialWalkMap? originWalkMap,
    SerialWalkMap? destWalkMap,
  }) {
    final path       = route.path;
    final n          = path.length;
    if (n < 2) return _Skip();
    final isCircular = _isCircular(route);

    // ── Haversine distances — used for radius gate only ───────────────────────
    final dToOrigin = List<double>.filled(n, 0);
    final dToDest   = List<double>.filled(n, 0);
    double nearestOriginDist = double.infinity;
    double nearestDestDist   = double.infinity;

    for (int i = 0; i < n; i++) {
      dToOrigin[i] = _haversine(path[i], origin);
      dToDest[i]   = _haversine(path[i], dest);
      if (dToOrigin[i] < nearestOriginDist) nearestOriginDist = dToOrigin[i];
      if (dToDest[i]   < nearestDestDist)   nearestDestDist   = dToDest[i];
    }

    if (nearestOriginDist > radiusMeters) {
      return _Fail(RouteRejection(route: route, gate: RejectionGate.originTooFar, nearestOriginMeters: nearestOriginDist));
    }
    if (nearestDestDist > radiusMeters) {
      return _Fail(RouteRejection(route: route, gate: RejectionGate.destTooFar, nearestOriginMeters: nearestOriginDist, nearestDestMeters: nearestDestDist));
    }

    final prefix = List<double>.filled(n, 0);
    for (int i = 1; i < n; i++) {
      prefix[i] = prefix[i - 1] + _haversine(path[i - 1], path[i]);
    }
    final totalPathLen = prefix[n - 1];

    // ── Candidate stops within Haversine radius ───────────────────────────────
    final boardingCandidates = <_Hit>[];
    final dropoffCandidates  = <_Hit>[];
    for (int i = 0; i < n; i++) {
      if (dToOrigin[i] <= radiusMeters) boardingCandidates.add(_Hit(i, dToOrigin[i]));
      if (dToDest[i]   <= radiusMeters) dropoffCandidates.add(_Hit(i, dToDest[i]));
    }

    if (boardingCandidates.isEmpty) {
      return _Fail(RouteRejection(route: route, gate: RejectionGate.originTooFar, nearestOriginMeters: nearestOriginDist));
    }
    if (dropoffCandidates.isEmpty) {
      return _Fail(RouteRejection(route: route, gate: RejectionGate.destTooFar, nearestOriginMeters: nearestOriginDist, nearestDestMeters: nearestDestDist));
    }

    const minProgressMeters = 50.0;
    RouteRecommendation? best;
    double               bestScore = double.infinity;

    for (final bHit in boardingCandidates) {
      final bi = bHit.idx;
      // Road walk to boarding — O(1) lookup via pre-snapped node cache
      final walkBoard = originWalkMap != null
          ? originWalkMap.distanceTo(route.routeId, bi, bHit.dist)
          : bHit.dist;
      final distBiToDest = dToDest[bi];

      for (final dHit in dropoffCandidates) {
        final di = dHit.idx;
        // Road walk from alighting — O(1) lookup
        final walkDrop = destWalkMap != null
            ? destWalkMap.distanceTo(route.routeId, di, dHit.dist)
            : dHit.dist;

        if (bi == di) continue;
        final isForward = bi < di;
        final isWrap    = !isForward && isCircular;
        if (!isForward && !isWrap) continue;

        if (distBiToDest - dToDest[di] < minProgressMeters) continue;

        final stopCount = isWrap ? (n - 1 - bi) + di : di - bi;
        if (stopCount < 2) continue;

        final rideM = isWrap
            ? (totalPathLen - prefix[bi]) + prefix[di]
            : prefix[di] - prefix[bi];

        final score = _singleScore(
          walkToBoarding: walkBoard, walkFromDropoff: walkDrop,
          rideMeters: rideM, walkWeight: walkWeight, rideWeight: rideWeight,
        );

        if (score < bestScore) {
          bestScore = score;
          best = RouteRecommendation(
            route: route, boardingIndex: bi, dropoffIndex: di,
            walkToBoardingMeters: walkBoard, walkFromDropoffMeters: walkDrop,
            score: score,
          );
        }
      }
    }

    if (best != null) return _Pass(best);
    return _Fail(RouteRejection(route: route, gate: RejectionGate.wrongDirection, nearestOriginMeters: nearestOriginDist, nearestDestMeters: nearestDestDist));
  }

  bool _isCircular(JeepneyRoute route) {
    final path = route.path;
    if (path.length < 3) return false;
    return _haversine(path.first, path.last) < 150.0;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // STATIC GRAPH PRECOMPUTATION
  // ════════════════════════════════════════════════════════════════════════════

  PrecomputedRouteGraph buildStaticGraph(List<JeepneyRoute> allRoutes) {
    final nodes        = <_Node>[];
    final routeNodeIds = <String, List<int>>{};
    final routeIndex   = <String, int>{};
    int   nextId       = 0;

    for (int ri = 0; ri < allRoutes.length; ri++) {
      final route = allRoutes[ri];
      routeIndex[route.routeId] = ri;
      final ids = <int>[];
      for (int i = 0; i < route.path.length; i++) {
        final id = nextId++;
        nodes.add(_Node(id: id, point: route.path[i], route: route, pathIndex: i));
        ids.add(id);
      }
      routeNodeIds[route.routeId] = ids;
    }

    final nodeCount = nextId;
    final adj = List<List<_Edge>>.generate(nodeCount, (_) => []);

    for (final route in allRoutes) {
      final ids = routeNodeIds[route.routeId]!;
      for (int i = 0; i + 1 < ids.length; i++) {
        final cost = _haversine(nodes[ids[i]].point, nodes[ids[i + 1]].point);
        adj[ids[i]].add(_Edge(to: ids[i + 1], cost: cost, kind: _EdgeKind.onRoute));
      }
      if (_isCircular(route) && ids.length >= 3) {
        final cost = _haversine(nodes[ids.last].point, nodes[ids.first].point);
        adj[ids.last].add(_Edge(to: ids.first, cost: cost, kind: _EdgeKind.onRoute));
      }
    }

    const transferWalkMultiplier = 3.0;
    final bbox = <String, _BBox>{};
    for (final route in allRoutes) {
      double minLat = double.infinity, maxLat = -double.infinity;
      double minLng = double.infinity, maxLng = -double.infinity;
      for (final p in route.path) {
        if (p.latitude  < minLat) minLat = p.latitude;
        if (p.latitude  > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      bbox[route.routeId] = _BBox(minLat, maxLat, minLng, maxLng);
    }

    final marginDeg = transferRadiusMeters / 111000.0;
    final routeList = routeNodeIds.entries.toList();
    for (int ri = 0; ri < routeList.length; ri++) {
      for (int rj = ri + 1; rj < routeList.length; rj++) {
        final routeIdA = routeList[ri].key;
        final routeIdB = routeList[rj].key;
        final bboxA    = bbox[routeIdA]!;
        final bboxB    = bbox[routeIdB]!;
        if (bboxA.minLat - marginDeg > bboxB.maxLat || bboxB.minLat - marginDeg > bboxA.maxLat ||
            bboxA.minLng - marginDeg > bboxB.maxLng || bboxB.minLng - marginDeg > bboxA.maxLng) continue;
        final idsA = routeList[ri].value;
        final idsB = routeList[rj].value;
        for (final idA in idsA) {
          for (final idB in idsB) {
            final d = _haversine(nodes[idA].point, nodes[idB].point);
            if (d <= transferRadiusMeters) {
              final cost = d * transferWalkMultiplier + transferPenaltyMeters;
              adj[idA].add(_Edge(to: idB, cost: cost, kind: _EdgeKind.transfer));
              adj[idB].add(_Edge(to: idA, cost: cost, kind: _EdgeKind.transfer));
            }
          }
        }
      }
    }

    final lats         = List<double>.filled(nodeCount, 0);
    final lngs         = List<double>.filled(nodeCount, 0);
    final nodeRouteIds = List<String?>.filled(nodeCount, null);
    final nodePathIdx  = List<int?>.filled(nodeCount, null);
    for (int i = 0; i < nodeCount; i++) {
      lats[i]         = nodes[i].point.latitude;
      lngs[i]         = nodes[i].point.longitude;
      nodeRouteIds[i] = nodes[i].route?.routeId;
      nodePathIdx[i]  = nodes[i].pathIndex;
    }

    return PrecomputedRouteGraph(
      nodeLats: lats, nodeLngs: lngs, nodeRouteIds: nodeRouteIds,
      nodePathIndices: nodePathIdx,
      adjTo:   List.generate(nodeCount, (i) => adj[i].map((e) => e.to).toList()),
      adjCost: List.generate(nodeCount, (i) => adj[i].map((e) => e.cost).toList()),
      adjKind: List.generate(nodeCount, (i) => adj[i].map((e) => e.kind.index).toList()),
      routeNodeIds: routeNodeIds, routeIndex: routeIndex, nodeCount: nodeCount,
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // MULTI-ROUTE
  // ════════════════════════════════════════════════════════════════════════════

  List<RouteJourney> _tryMultiRoute(
    LatLng origin, LatLng destination, List<JeepneyRoute> allRoutes, {
    PrecomputedRouteGraph? precomputed,
    double walkWeight = 1.0, double rideWeight = 0.25,
    RoutePriority priority = RoutePriority.balanced,
    SerialWalkMap? originWalkMap,
    SerialWalkMap? destWalkMap,
  }) {
    final graph  = _buildGraph(origin, destination, allRoutes, precomputed: precomputed);
    final result = _dijkstra(graph);
    return _extractJourneys(graph, result, origin, destination,
        walkWeight: walkWeight, rideWeight: rideWeight,
        priority: priority,
        originWalkMap: originWalkMap, destWalkMap: destWalkMap);
  }

  _Graph _buildGraph(
    LatLng origin, LatLng destination, List<JeepneyRoute> allRoutes, {
    PrecomputedRouteGraph? precomputed,
  }) {
    if (precomputed != null) {
      return _buildGraphFromPrecomputed(origin, destination, allRoutes, precomputed);
    }
    final nodes        = <_Node>[];
    final routeNodeIds = <String, List<int>>{};
    final routeIndex   = <String, int>{};
    int   nextId       = 0;

    for (int ri = 0; ri < allRoutes.length; ri++) {
      final route = allRoutes[ri];
      routeIndex[route.routeId] = ri;
      final ids = <int>[];
      for (int i = 0; i < route.path.length; i++) {
        final id = nextId++;
        nodes.add(_Node(id: id, point: route.path[i], route: route, pathIndex: i));
        ids.add(id);
      }
      routeNodeIds[route.routeId] = ids;
    }

    final originId = nextId++;
    final destId   = nextId++;
    nodes.add(_Node(id: originId, point: origin));
    nodes.add(_Node(id: destId,   point: destination));

    final adj = List<List<_Edge>>.generate(nextId, (_) => []);

    for (final route in allRoutes) {
      final ids = routeNodeIds[route.routeId]!;
      for (int i = 0; i + 1 < ids.length; i++) {
        final cost = _haversine(nodes[ids[i]].point, nodes[ids[i + 1]].point);
        adj[ids[i]].add(_Edge(to: ids[i + 1], cost: cost, kind: _EdgeKind.onRoute));
      }
      if (_isCircular(route) && ids.length >= 3) {
        final cost = _haversine(nodes[ids.last].point, nodes[ids.first].point);
        adj[ids.last].add(_Edge(to: ids.first, cost: cost, kind: _EdgeKind.onRoute));
      }
    }

    const transferWalkMultiplier = 3.0;
    final bbox = <String, _BBox>{};
    for (final route in allRoutes) {
      double minLat = double.infinity, maxLat = -double.infinity;
      double minLng = double.infinity, maxLng = -double.infinity;
      for (final p in route.path) {
        if (p.latitude  < minLat) minLat = p.latitude;
        if (p.latitude  > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      bbox[route.routeId] = _BBox(minLat, maxLat, minLng, maxLng);
    }

    final marginDeg = transferRadiusMeters / 111000.0;
    final routeList = routeNodeIds.entries.toList();
    for (int ri = 0; ri < routeList.length; ri++) {
      for (int rj = ri + 1; rj < routeList.length; rj++) {
        final routeIdA = routeList[ri].key;
        final routeIdB = routeList[rj].key;
        final bboxA = bbox[routeIdA]!;
        final bboxB = bbox[routeIdB]!;
        if (bboxA.minLat - marginDeg > bboxB.maxLat || bboxB.minLat - marginDeg > bboxA.maxLat ||
            bboxA.minLng - marginDeg > bboxB.maxLng || bboxB.minLng - marginDeg > bboxA.maxLng) continue;
        final idsA = routeList[ri].value;
        final idsB = routeList[rj].value;
        for (final idA in idsA) {
          for (final idB in idsB) {
            final d = _haversine(nodes[idA].point, nodes[idB].point);
            if (d <= transferRadiusMeters) {
              final cost = d * transferWalkMultiplier + transferPenaltyMeters;
              adj[idA].add(_Edge(to: idB, cost: cost, kind: _EdgeKind.transfer));
              adj[idB].add(_Edge(to: idA, cost: cost, kind: _EdgeKind.transfer));
            }
          }
        }
      }
    }

    const walkCostMultiplier = 3.0;
    for (int id = 0; id < nodes.length - 2; id++) {
      final walkDist = _haversine(origin, nodes[id].point);
      if (walkDist <= radiusMeters) {
        adj[originId].add(_Edge(to: id, cost: walkDist * walkCostMultiplier, kind: _EdgeKind.walkToRoute));
      }
    }
    for (int id = 0; id < nodes.length - 2; id++) {
      final d = _haversine(nodes[id].point, destination);
      if (d <= radiusMeters) {
        adj[id].add(_Edge(to: destId, cost: d, kind: _EdgeKind.walkToRoute));
      }
    }

    return _Graph(nodes: nodes, adj: adj, originId: originId, destId: destId,
        routeNodeIds: routeNodeIds, routeIndex: routeIndex);
  }

  _Graph _buildGraphFromPrecomputed(
    LatLng origin, LatLng destination, List<JeepneyRoute> allRoutes,
    PrecomputedRouteGraph precomputed,
  ) {
    final routeById = { for (final r in allRoutes) r.routeId: r };
    final n = precomputed.nodeCount;

    final nodes = List<_Node>.generate(n, (i) {
      final rid = precomputed.nodeRouteIds[i];
      return _Node(
        id: i, point: LatLng(precomputed.nodeLats[i], precomputed.nodeLngs[i]),
        route: rid != null ? routeById[rid] : null,
        pathIndex: precomputed.nodePathIndices[i],
      );
    });

    final originId = n;
    final destId   = n + 1;
    nodes.add(_Node(id: originId, point: origin));
    nodes.add(_Node(id: destId,   point: destination));

    final adj = List<List<_Edge>>.generate(n + 2, (i) {
      if (i >= n) return <_Edge>[];
      final tos   = precomputed.adjTo[i];
      final costs = precomputed.adjCost[i];
      final kinds = precomputed.adjKind[i];
      return List<_Edge>.generate(tos.length,
          (j) => _Edge(to: tos[j], cost: costs[j], kind: _EdgeKind.values[kinds[j]]));
    });

    const walkCostMultiplier = 3.0;
    for (int id = 0; id < n; id++) {
      final walkDist = _haversine(origin, nodes[id].point);
      if (walkDist <= radiusMeters) {
        adj[originId].add(_Edge(to: id, cost: walkDist * walkCostMultiplier, kind: _EdgeKind.walkToRoute));
      }
    }
    for (int id = 0; id < n; id++) {
      final d = _haversine(nodes[id].point, destination);
      if (d <= radiusMeters) {
        adj[id].add(_Edge(to: destId, cost: d, kind: _EdgeKind.walkToRoute));
      }
    }

    return _Graph(nodes: nodes, adj: adj, originId: originId, destId: destId,
        routeNodeIds: precomputed.routeNodeIds, routeIndex: precomputed.routeIndex);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // DIJKSTRA
  // ════════════════════════════════════════════════════════════════════════════

  _DResult _dijkstra(_Graph graph) {
    final numRoutes   = graph.routeIndex.length;
    final maskRange   = 1 << numRoutes;
    final tRange      = maxTransfersAllowed + 1;
    final stride      = tRange * maskRange;
    final totalStates = graph.nodes.length * stride;

    final dist    = List<double>.filled(totalStates, double.infinity);
    final prevKey = List<int>.filled(totalStates, -1);
    final result  = _DResult(dist: dist, prevKey: prevKey, stride: stride, maskRange: maskRange);

    int encode(int nodeId, int t, int mask) => nodeId * stride + t * maskRange + mask;

    final pq       = _MinHeap<_DState>();
    final startKey = encode(graph.originId, 0, 0);
    dist[startKey] = 0;
    pq.add(_DState(graph.originId, 0.0, 0, 0));

    while (pq.isNotEmpty) {
      final cur = pq.removeFirst();
      final ck  = encode(cur.nodeId, cur.transfers, cur.routeMask);
      if (cur.cost > dist[ck] + 1e-9) continue;
      if (cur.nodeId == graph.destId) break;

      for (final edge in graph.adj[cur.nodeId]) {
        final nextNode = graph.nodes[edge.to];
        int newTransfers = cur.transfers;
        int newMask      = cur.routeMask;

        if (edge.kind == _EdgeKind.walkToRoute) {
          final rid = nextNode.route?.routeId;
          if (rid != null) {
            final bit = graph.routeIndex[rid];
            if (bit != null) newMask |= (1 << bit);
          }
        } else if (edge.kind == _EdgeKind.transfer) {
          final targetRoute = nextNode.route?.routeId;
          if (targetRoute != null) {
            final bit = graph.routeIndex[targetRoute];
            if (bit != null && (cur.routeMask & (1 << bit)) != 0) continue;
            newTransfers += 1;
            if (newTransfers > maxTransfersAllowed) continue;
            if (bit != null) newMask |= (1 << bit);
          }
        }

        final newCost = cur.cost + edge.cost;
        final nk      = encode(edge.to, newTransfers, newMask);
        if (newCost < dist[nk]) {
          dist[nk]    = newCost;
          prevKey[nk] = ck;
          pq.add(_DState(edge.to, newCost, newTransfers, newMask));
        }
      }
    }
    return result;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // JOURNEY EXTRACTION
  // ════════════════════════════════════════════════════════════════════════════

  List<RouteJourney> _extractJourneys(
    _Graph graph, _DResult result, LatLng origin, LatLng destination, {
    double walkWeight = 1.0, double rideWeight = 0.25,
    RoutePriority priority = RoutePriority.balanced,
    SerialWalkMap? originWalkMap,
    SerialWalkMap? destWalkMap,
  }) {
    final journeys = <RouteJourney>[];
    for (int t = 1; t <= maxTransfersAllowed; t++) {
      int    bestKey  = -1;
      double bestCost = double.infinity;
      for (int mask = 0; mask < result.maskRange; mask++) {
        final k = result.encode(graph.destId, t, mask);
        if (result.dist[k] < bestCost) { bestCost = result.dist[k]; bestKey = k; }
      }
      if (bestKey == -1 || bestCost.isInfinite) continue;
      final journey = _backtrack(graph, result, graph.destId, t, bestKey, origin, destination,
          rideWeight: rideWeight, walkWeight: walkWeight, priority: priority,
          originWalkMap: originWalkMap, destWalkMap: destWalkMap);
      if (journey != null) journeys.add(journey);
    }
    return journeys;
  }

  RouteJourney? _backtrack(
    _Graph graph, _DResult result, int destId, int transfers, int destKey,
    LatLng origin, LatLng destination, {
    double rideWeight = 0.25, double walkWeight = 1.0,
    RoutePriority priority = RoutePriority.balanced,
    SerialWalkMap? originWalkMap,
    SerialWalkMap? destWalkMap,
  }) {
    final rawKeys = <int>[];
    int cur = destKey;
    while (cur != -1) { rawKeys.add(cur); cur = result.prevKey[cur]; }

    final nodeIds = rawKeys.reversed.map((k) => k ~/ result.stride).toList();
    if (nodeIds.isEmpty || nodeIds.first != graph.originId) return null;

    final segments       = <RouteSegment>[];
    final transferPoints = <LatLng>[];

    final routeNodes = nodeIds
        .where((id) => graph.nodes[id].route != null)
        .map((id) => graph.nodes[id])
        .toList();
    if (routeNodes.isEmpty) return null;

    int segStart = 0;
    while (segStart < routeNodes.length) {
      final segRoute = routeNodes[segStart].route!;
      int segEnd = segStart;
      while (segEnd + 1 < routeNodes.length &&
          routeNodes[segEnd + 1].route?.routeId == segRoute.routeId) segEnd++;

      final boardingIdx    = routeNodes[segStart].pathIndex!;
      final prevLocation   = segments.isEmpty ? origin : segments.last.dropoffPoint;
      final nearestToBoardDist = _haversine(prevLocation, segRoute.path[boardingIdx]);

      final bool isLastSegment = (segEnd + 1 >= routeNodes.length);
      int dropoffIdx;
      if (isLastSegment) {
        final pathLen     = segRoute.path.length;
        final isCircRoute = _isCircular(segRoute);
        dropoffIdx        = routeNodes[segEnd].pathIndex!;

        final prefix = List<double>.filled(pathLen, 0);
        for (int i = 1; i < pathLen; i++) {
          prefix[i] = prefix[i - 1] + _haversine(segRoute.path[i - 1], segRoute.path[i]);
        }
        final totalPathLen = prefix[pathLen - 1];
        double bestScore = double.infinity;

        for (int i = boardingIdx + 1; i < pathLen; i++) {
          final walkDistHav = _haversine(segRoute.path[i], destination);
          if (walkDistHav > radiusMeters) continue;
          final walkDist = destWalkMap != null
              ? destWalkMap.distanceTo(segRoute.routeId, i, walkDistHav)
              : walkDistHav;
          final rideDist = prefix[i] - prefix[boardingIdx];
          final score    = walkDist + rideDist * rideWeight;
          if (score < bestScore) { bestScore = score; dropoffIdx = i; }
        }
        if (isCircRoute) {
          for (int i = 0; i < boardingIdx; i++) {
            final walkDistHav = _haversine(segRoute.path[i], destination);
            if (walkDistHav > radiusMeters) continue;
            final walkDist = destWalkMap != null
                ? destWalkMap.distanceTo(segRoute.routeId, i, walkDistHav)
                : walkDistHav;
            final rideDist = (totalPathLen - prefix[boardingIdx]) + prefix[i];
            final score    = walkDist + rideDist * rideWeight;
            if (score < bestScore) { bestScore = score; dropoffIdx = i; }
          }
        }
      } else {
        dropoffIdx = routeNodes[segEnd].pathIndex!;
      }

      final isWrap = boardingIdx > dropoffIdx && _isCircular(segRoute);
      if (boardingIdx >= dropoffIdx && !isWrap) { segStart = segEnd + 1; continue; }

      final stopCount = isWrap
          ? (segRoute.path.length - 1 - boardingIdx) + dropoffIdx
          : dropoffIdx - boardingIdx;
      if (stopCount < 2) { segStart = segEnd + 1; continue; }

      if (_isCircular(segRoute) && stopCount > (segRoute.path.length * 0.65).round()) return null;

      final boardingPt = segRoute.path[boardingIdx];
      final dropoffPt  = segRoute.path[dropoffIdx];

      double walkFromDrop;
      if (segEnd + 1 < routeNodes.length) {
        final nextRoute = routeNodes[segEnd + 1].route!;
        double nearestToDrop = double.infinity;
        for (int i = 0; i < nextRoute.path.length; i++) {
          final d = _haversine(dropoffPt, nextRoute.path[i]);
          if (d < nearestToDrop) nearestToDrop = d;
        }
        walkFromDrop = nearestToDrop;
      } else {
        final hav = _haversine(dropoffPt, destination);
        walkFromDrop = destWalkMap != null
            ? destWalkMap.distanceTo(segRoute.routeId, dropoffIdx, hav)
            : hav;
      }

      // Walk to boarding: road distance if map available
      final walkToBoard = originWalkMap != null && segments.isEmpty
          ? originWalkMap.distanceTo(segRoute.routeId, boardingIdx, nearestToBoardDist)
          : nearestToBoardDist;

      if (segments.isNotEmpty) {
        transferPoints.add(_midpoint(segments.last.dropoffPoint, boardingPt));
      }

      segments.add(RouteSegment(
        route:                segRoute,
        boardingIndex:        boardingIdx,
        dropoffIndex:         dropoffIdx,
        walkToBoardingMeters: walkToBoard,
        walkFromDropoffMeters:walkFromDrop,
        isWrapAround:         isWrap,
      ));

      segStart = segEnd + 1;
    }

    if (segments.isEmpty) return null;

    final totalWalk = segments.fold(0.0, (sum, s) => sum + s.walkToBoardingMeters + s.walkFromDropoffMeters);
    final rideKm    = segments.fold(0.0, (sum, s) => sum + s.rideDistanceMeters) / 1000.0;
    final walkKm    = totalWalk / 1000.0;
    final estimatedMinutes = (walkKm / 5.0 * 60.0) + (rideKm / 20.0 * 60.0) + (transfers * 5.0);
    final score = totalWalk * walkWeight + (rideKm * 1000.0 * rideWeight) + (transfers * transferPenaltyMeters);

    return RouteJourney(
      segments:                segments,
      transferPoints:          transferPoints,
      totalWalkingMeters:      totalWalk,
      transferCount:           transfers,
      estimatedJourneyMinutes: estimatedMinutes,
      score:                   score,
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ════════════════════════════════════════════════════════════════════════════

  _Hit _nearest(List<LatLng> path, LatLng target) {
    int    bestIdx  = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < path.length; i++) {
      final d = _haversine(path[i], target);
      if (d < bestDist) { bestDist = d; bestIdx = i; }
    }
    return _Hit(bestIdx, bestDist);
  }

  double _singleScore({
    required double walkToBoarding, required double walkFromDropoff,
    required double rideMeters,
    double walkWeight = 1.0, double rideWeight = 0.25,
    RoutePriority priority = RoutePriority.balanced,
    bool isModern = false,
  }) {
    return (walkToBoarding + walkFromDropoff) * walkWeight + (rideMeters * rideWeight);
  }

  double _haversine(LatLng a, LatLng b) => _dist.as(LengthUnit.Meter, a, b);

  LatLng _midpoint(LatLng a, LatLng b) => LatLng(
    (a.latitude  + b.latitude)  / 2.0,
    (a.longitude + b.longitude) / 2.0,
  );
}

// ── Polyline distance helper ──────────────────────────────────────────────────
double _polylineDistance(List<LatLng> pts) {
  const d = Distance();
  double total = 0;
  for (int i = 0; i + 1 < pts.length; i++) {
    total += d.as(LengthUnit.Meter, pts[i], pts[i + 1]);
  }
  return total;
}

// ════════════════════════════════════════════════════════════════════════════
// INTERNAL TYPES
// ════════════════════════════════════════════════════════════════════════════

class _SingleResult {
  final List<RouteRecommendation> candidates;
  final List<RouteRejection>      rejections;
  const _SingleResult({required this.candidates, required this.rejections});
}

sealed class _EvalResult {}
class _Pass extends _EvalResult { final RouteRecommendation recommendation; _Pass(this.recommendation); }
class _Fail extends _EvalResult { final RouteRejection rejection;           _Fail(this.rejection); }
class _Skip extends _EvalResult {}

class _Hit {
  final int    idx;
  final double dist;
  const _Hit(this.idx, this.dist);
}

class _BBox {
  final double minLat, maxLat, minLng, maxLng;
  const _BBox(this.minLat, this.maxLat, this.minLng, this.maxLng);
}

class _MinHeap<T extends Comparable<T>> {
  final _data = <T>[];
  bool get isNotEmpty => _data.isNotEmpty;
  void add(T item) { _data.add(item); _bubbleUp(_data.length - 1); }
  T removeFirst() {
    final top  = _data.first;
    final last = _data.removeLast();
    if (_data.isNotEmpty) { _data[0] = last; _sinkDown(0); }
    return top;
  }
  void _bubbleUp(int i) {
    while (i > 0) {
      final p = (i - 1) ~/ 2;
      if (_data[i].compareTo(_data[p]) < 0) {
        final tmp = _data[i]; _data[i] = _data[p]; _data[p] = tmp; i = p;
      } else break;
    }
  }
  void _sinkDown(int i) {
    final n = _data.length;
    while (true) {
      int s = i;
      final l = 2*i+1, r = 2*i+2;
      if (l < n && _data[l].compareTo(_data[s]) < 0) s = l;
      if (r < n && _data[r].compareTo(_data[s]) < 0) s = r;
      if (s == i) break;
      final tmp = _data[i]; _data[i] = _data[s]; _data[s] = tmp; i = s;
    }
  }
}

// ── compute() helpers ─────────────────────────────────────────────────────────

class RoutingMessage {
  final LatLng             origin;
  final LatLng             destination;
  final List<JeepneyRoute> allRoutes;
  final double             radiusMeters;
  final double             transferRadiusMeters;
  final double             transferPenaltyMeters;
  final int                maxTransfersAllowed;
  final int                maxResults;
  final RoutePriority      priority;
  final PrecomputedRouteGraph? precomputedGraph;
  // Walk distance maps pre-computed on main thread — serialisable, no WalkGraph
  final SerialWalkMap?     originWalkMap;
  final SerialWalkMap?     destWalkMap;

  const RoutingMessage({
    required this.origin, required this.destination, required this.allRoutes,
    required this.radiusMeters, required this.transferRadiusMeters,
    required this.transferPenaltyMeters, required this.maxTransfersAllowed,
    required this.maxResults,
    this.priority = RoutePriority.balanced,
    this.precomputedGraph,
    this.originWalkMap,
    this.destWalkMap,
  });
}

RoutingResult runRoutingIsolate(RoutingMessage msg) {
  final router = JeepneyRouter(
    radiusMeters:          msg.radiusMeters,
    transferRadiusMeters:  msg.transferRadiusMeters,
    transferPenaltyMeters: msg.transferPenaltyMeters,
    maxTransfersAllowed:   msg.maxTransfersAllowed,
    maxResults:            msg.maxResults,
  );
  return router.findRoutes(
    origin:          msg.origin,
    destination:     msg.destination,
    allRoutes:       msg.allRoutes,
    precomputed:     msg.precomputedGraph,
    priority:        msg.priority,
    originWalkMap:   msg.originWalkMap,
    destWalkMap:     msg.destWalkMap,
  );
}