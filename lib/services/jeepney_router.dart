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


// ══════════════════════════════════════════════════════════════════════════════
// GRAPH INTERNALS  (file-private)
// ══════════════════════════════════════════════════════════════════════════════

/// A node in the routing graph.  Each physical stop on each jeepney route
/// gets one node.  The virtual origin and destination each get one node too.
class _Node {
  final int    id;
  final LatLng point;

  /// null for the virtual origin / destination nodes.
  final JeepneyRoute? route;

  /// Index of this node within route.path (null for virtual nodes).
  final int? pathIndex;

  const _Node({
    required this.id,
    required this.point,
    this.route,
    this.pathIndex,
  });
}

enum _EdgeKind { onRoute, transfer, walkToRoute }

/// A directed edge in the routing graph.
class _Edge {
  final int      to;
  final double   cost;
  final _EdgeKind kind;

  const _Edge({required this.to, required this.cost, required this.kind});
}

/// Lightweight routing graph built fresh per findRoutes() call.
class _Graph {
  final List<_Node>          nodes;       // indexed by node id
  final List<List<_Edge>>    adj;         // adj[id] = outgoing edges
  final int                  originId;
  final int                  destId;

  /// Nodes that belong to a given route, ordered by pathIndex.
  final Map<String, List<int>> routeNodeIds; // routeId → sorted node ids

  /// Integer index assigned to each route for bitmask encoding.
  /// routeIndex[routeId] = 0..numRoutes-1
  final Map<String, int> routeIndex;

  const _Graph({
    required this.nodes,
    required this.adj,
    required this.originId,
    required this.destId,
    required this.routeNodeIds,
    required this.routeIndex,
  });
}

// ── Dijkstra state ────────────────────────────────────────────────────────────

/// Compact Dijkstra state using integer bitmask for route history.
///
/// routeMask: bit i is set if route with index i has been boarded.
/// This replaces the string-based routesKey — no string allocations,
/// no split/join/contains, just bitwise operations.
class _DState implements Comparable<_DState> {
  final int    nodeId;
  final double cost;
  final int    transfers;
  final int    routeMask;   // bitmask of boarded route indices

  const _DState(this.nodeId, this.cost, this.transfers, [this.routeMask = 0]);

  @override
  int compareTo(_DState other) {
    final c = cost.compareTo(other.cost);
    return c != 0 ? c : transfers.compareTo(other.transfers);
  }
}

/// Per-node best result keyed by compact integer:
///   key = nodeId * (maxTransfers+1) * (1 << numRoutes)
///          + transfers * (1 << numRoutes)
///          + routeMask
/// Stored in a flat List<double> for O(1) access with no hash overhead.
class _DResult {
  final List<double>   dist;
  final List<int>      prevKey;  // encoded predecessor key, -1 = no predecessor
  final int            stride;   // (maxTransfers+1) * maskRange
  final int            maskRange; // 1 << numRoutes

  _DResult({
    required this.dist,
    required this.prevKey,
    required this.stride,
    required this.maskRange,
  });

  int encode(int nodeId, int transfers, int routeMask) =>
      nodeId * stride + transfers * maskRange + routeMask;
}

// ══════════════════════════════════════════════════════════════════════════════
// PRECOMPUTED STATIC GRAPH
// ══════════════════════════════════════════════════════════════════════════════

/// The static (query-independent) parts of the routing graph, serialisable
/// for passing across isolate boundaries via compute().
///
/// Built once when routes load via [runStaticGraphIsolate].
/// Passed into every [RoutingMessage] so [_buildGraph] can skip the expensive
/// O(R² × n²) transfer-edge scan on each routing query.
class PrecomputedRouteGraph {
  /// Parallel arrays — one entry per static node (route path points only;
  /// virtual origin/dest nodes are added per-query and are NOT stored here).
  final List<double>  nodeLats;
  final List<double>  nodeLngs;
  final List<String?> nodeRouteIds;   // null for virtual nodes (unused here)
  final List<int?>    nodePathIndices;

  /// Adjacency list containing only onRoute and transfer edges.
  /// walkToRoute edges are omitted — they depend on origin/destination.
  /// adjTo[i], adjCost[i], adjKind[i] are parallel lists for node i.
  final List<List<int>>    adjTo;
  final List<List<double>> adjCost;
  final List<List<int>>    adjKind;   // _EdgeKind.index values

  /// routeId → ordered list of node ids (same semantics as _Graph.routeNodeIds).
  final Map<String, List<int>> routeNodeIds;

  /// routeId → integer bitmask index (same semantics as _Graph.routeIndex).
  final Map<String, int> routeIndex;

  /// Total number of static nodes (= nodeLats.length).
  final int nodeCount;

  const PrecomputedRouteGraph({
    required this.nodeLats,
    required this.nodeLngs,
    required this.nodeRouteIds,
    required this.nodePathIndices,
    required this.adjTo,
    required this.adjCost,
    required this.adjKind,
    required this.routeNodeIds,
    required this.routeIndex,
    required this.nodeCount,
  });
}

/// User-selectable routing priority that adjusts scoring weights.
enum RoutePriority {
  balanced,  // default: walk×1.0 + ride×0.25
  time,      // shorter total trip: walk×1.0 + ride×0.5
  lessWalk,  // minimise walking: walk×2.0 + ride×0.1
}

/// Message sent to the static-graph precomputation isolate.
class StaticGraphMessage {
  final List<JeepneyRoute> allRoutes;
  final double             transferRadiusMeters;
  final double             transferPenaltyMeters;

  const StaticGraphMessage({
    required this.allRoutes,
    required this.transferRadiusMeters,
    required this.transferPenaltyMeters,
  });
}

/// Top-level entry point for the static graph precomputation isolate.
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
  // ── Existing parameters ──────────────────────────────────────────────────────
  /// Maximum walk distance (metres) from origin/dest to a boarding/alight point.
  final double radiusMeters;

  /// Maximum number of journey results to return.
  final int maxResults;

  // ── New multi-transfer parameters ────────────────────────────────────────────
  /// Maximum walk distance (metres) between two routes to count as a transfer.
  final double transferRadiusMeters;

  /// Flat cost (metres equivalent) added per transfer to discourage unnecessary
  /// changes.  Think of it as "how many metres of walking is one transfer worth".
  final double transferPenaltyMeters;

  /// Maximum number of transfers permitted in a single journey.
  final int maxTransfersAllowed;

  static const _dist = Distance();

  const JeepneyRouter({
    this.radiusMeters          = 350.0,
    this.maxResults            = 5,
    this.transferRadiusMeters  = 200.0,
    this.transferPenaltyMeters = 400.0,   // ≈ 5 min walk penalty per transfer
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
  }) {
    // ── Scoring weights derived from priority ────────────────────────────────
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
    // ── Pre-scan guards ─────────────────────────────────────────────────────
    // Only reject "same location" when the two points are truly identical
    // (< 5 m apart).  A slightly larger gap (5–150 m) could legitimately
    // represent two nearby stops that require a circular wrap-around ride.
    if (_haversine(origin, destination) < 5) {
      return RoutingFailure('Origin and destination appear to be the same location.');
    }
    if (allRoutes.isEmpty) {
      return RoutingFailure('Route data is still loading. Please wait a moment.');
    }

    // ── Step 1: try single-route (fast, no graph needed) ────────────────────
    final singleResult = _trySingleRoute(origin, destination, allRoutes,
        walkWeight: walkWeight, rideWeight: rideWeight, priority: priority);

    // If we have direct routes and transfers are disabled, return immediately.
    if (!allowTransfers) {
      if (singleResult.candidates.isNotEmpty) {
        final journeys = singleResult.candidates
            .take(maxResults)
            .map(RouteJourney.fromSingleRoute)
            .toList();
        return RoutingSuccess(journeys, hasTransfers: false);
      }
      return RoutingFailure(
        'No direct jeepney route found within ${radiusMeters.toInt()} m of both points.',
        rejections: singleResult.rejections,
      );
    }

    // ── Step 2: try multi-transfer via graph search ──────────────────────────
    final multiJourneys = _tryMultiRoute(origin, destination, allRoutes,
        precomputed: precomputed, walkWeight: walkWeight, rideWeight: rideWeight,
        priority: priority);

    // ── Step 3: merge and rank ───────────────────────────────────────────────
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

    // ── Relative walk quality filter ─────────────────────────────────────────
    // Compare every suggestion against the best one (allJourneys.first).
    // Applied to BOTH ends of the journey:
    //   • First-leg walk-to-board  — how far the user walks before boarding
    //   • Last-leg walk-to-dest    — how far the user walks after alighting
    //
    // A suggestion is discarded if either walk exceeds the ceiling derived
    // from the best suggestion's equivalent walk.
    //
    // Two-part ceiling (applied independently to each end):
    //   1. Relative: at most walkToleranceMultiplier × best equivalent walk.
    //      Floored at walkToleranceFloor so short best-walks (e.g. 20 m × 2
    //      = 40 m) don't incorrectly discard a reasonable 50 m walk.
    //   2. Absolute cap: never exceed walkAbsoluteCap regardless of the best
    //      walk, catching cases where the best suggestion itself has a longish
    //      walk that would otherwise inflate the relative ceiling.
    //
    // IMPORTANT — independent hard cap (checked BEFORE the relative filter):
    // When only one journey exists, the relative filter compares the journey
    // against itself and it trivially passes. The independent cap below fires
    // unconditionally, ensuring a single bad result is suppressed rather than
    // shown as the "best" option. Applies equally to single-route and
    // multi-route (transfer) journeys.
    const walkToleranceMultiplier = 2.0;   // at most 2× the best equivalent walk
    const walkToleranceFloor      = 200.0; // always allow up to 200 m regardless
    const walkAbsoluteCap         = 500.0; // hard ceiling on either walk end
    const walkIndependentCap      = 450.0; // unconditional cap — no comparison needed

    final bestJourney      = allJourneys.first;
    final bestFirstLegWalk = bestJourney.segments.first.walkToBoardingMeters;
    final bestLastLegWalk  = bestJourney.segments.last.walkFromDropoffMeters;

    final boardCeiling = (bestFirstLegWalk * walkToleranceMultiplier)
        .clamp(walkToleranceFloor, walkAbsoluteCap);
    final destCeiling  = (bestLastLegWalk * walkToleranceMultiplier)
        .clamp(walkToleranceFloor, walkAbsoluteCap);

    // Build the set of route IDs that already have a direct (no-transfer)
    // solution, mapped to their boarding walk distance for quality checks below.
    //
    //   First route in set → user couldve stayed on that jeepney all the way
    //                         to the destination without transferring.
    //   Last route in set  → user couldve boarded that jeepney directly from
    //                         near the origin WITHOUT needing the first leg —
    //                         BUT only suppress if the direct boarding walk is
    //                         within boardCeiling. If the direct version requires
    //                         much more walking than boardCeiling allows, the
    //                         transfer route is genuinely better (it gets the
    //                         user to the last-route boarding point by jeepney
    //                         rather than on foot) and must be kept.
    //
    // Middle routes are intentionally NOT checked — a transfer journey like
    // "walk → Jeepney Y → Jeepney X → dest" is valid even if Y or X has a
    // direct solution, as long as neither is redundant at the entry/exit.
    final directCandidates = { for (final c in singleResult.candidates) c.route.routeId: c };
    final directRouteIds   = directCandidates.keys.toSet();

    final seen    = <String>{};
    final ranked  = <RouteJourney>[];
    for (final j in allJourneys) {
        // Suppression 1: Unconditional walk cap
      if (j.segments.first.walkToBoardingMeters > walkIndependentCap) continue;
      if (j.segments.last.walkFromDropoffMeters  > walkIndependentCap) continue;
        // Suppression 2: Relative walk quality
      if (j.segments.first.walkToBoardingMeters > boardCeiling) continue;
      if (j.segments.last.walkFromDropoffMeters  > destCeiling)  continue;
        // Suppression 3: Transfer redundancy
      if (j.transferCount > 0 && directRouteIds.isNotEmpty) {
        final firstRouteId = j.segments.first.route.routeId;
        final lastRouteId  = j.segments.last.route.routeId;

        // First leg: user could ride it straight to destination
        if (directRouteIds.contains(firstRouteId)) continue;

        // Last leg: suppress only if direct boarding walk is reachable
        if (directRouteIds.contains(lastRouteId)) {
          final directWalk = directCandidates[lastRouteId]!.walkToBoardingMeters;
          if (directWalk <= boardCeiling) continue;
        }
      }

      final key = j.segments.map((s) => s.route.routeId).join('+');
      if (seen.add(key)) ranked.add(j);
      if (ranked.length >= maxResults) break;
    }

    // ── Suppression fallback show best 1-2 unfiltered if all suppressed ─────────────────────────────────────────────────
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
  // SINGLE-ROUTE (original algorithm, refactored into a helper)
  // ════════════════════════════════════════════════════════════════════════════

  _SingleResult _trySingleRoute(
    LatLng origin,
    LatLng destination,
    List<JeepneyRoute> allRoutes, {
    double        walkWeight = 1.0,
    double        rideWeight = 0.25,
    RoutePriority priority   = RoutePriority.balanced,
  }) {
    final candidates = <RouteRecommendation>[];
    final rejections = <RouteRejection>[];

    for (final route in allRoutes) {
      final r = _evaluate(route, origin, destination,
          walkWeight: walkWeight, rideWeight: rideWeight, priority: priority);
      if (r is _Pass) candidates.add(r.recommendation);
      else if (r is _Fail) rejections.add(r.rejection);
    }

    candidates.sort((a, b) => a.score.compareTo(b.score));
    return _SingleResult(candidates: candidates, rejections: rejections);
  }

  _EvalResult _evaluate(JeepneyRoute route, LatLng origin, LatLng dest, {
    double        walkWeight = 1.0,
    double        rideWeight = 0.25,
    RoutePriority priority   = RoutePriority.balanced,
  }) {
    final path       = route.path;
    final n          = path.length;
    if (n < 2) return _Skip();
    final isCircular = _isCircular(route);

    // ── Pre-compute distances to origin and dest for every path point ─────────
    // Avoids calling _haversine(path[i], origin/dest) multiple times per point.
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

    // Quick-reject before allocating candidate lists.
    if (nearestOriginDist > radiusMeters) {
      return _Fail(RouteRejection(
        route: route, gate: RejectionGate.originTooFar,
        nearestOriginMeters: nearestOriginDist,
      ));
    }
    if (nearestDestDist > radiusMeters) {
      return _Fail(RouteRejection(
        route: route, gate: RejectionGate.destTooFar,
        nearestOriginMeters: nearestOriginDist,
        nearestDestMeters:   nearestDestDist,
      ));
    }

    // ── Prefix-sum of cumulative path distances ───────────────────────────────
    // prefix[i] = total haversine distance from path[0] to path[i].
    // rideDistance(bi → di, forward) = prefix[di] - prefix[bi]  — O(1).
    // Built once here, used O(candidates²) times below.
    final prefix = List<double>.filled(n, 0);
    for (int i = 1; i < n; i++) {
      prefix[i] = prefix[i - 1] + _haversine(path[i - 1], path[i]);
    }
    final totalPathLen = prefix[n - 1]; // full route length for wrap-around

    // ── Collect candidate boarding and dropoff indices ────────────────────────
    final boardingCandidates = <_Hit>[];
    final dropoffCandidates  = <_Hit>[];
    for (int i = 0; i < n; i++) {
      if (dToOrigin[i] <= radiusMeters) boardingCandidates.add(_Hit(i, dToOrigin[i]));
      if (dToDest[i]   <= radiusMeters) dropoffCandidates.add(_Hit(i, dToDest[i]));
    }

    if (boardingCandidates.isEmpty) {
      return _Fail(RouteRejection(
        route: route, gate: RejectionGate.originTooFar,
        nearestOriginMeters: nearestOriginDist,
      ));
    }
    if (dropoffCandidates.isEmpty) {
      return _Fail(RouteRejection(
        route: route, gate: RejectionGate.destTooFar,
        nearestOriginMeters: nearestOriginDist,
        nearestDestMeters:   nearestDestDist,
      ));
    }

    // ── Full bi×di scan ───────────────────────────────────────────────────────
    // Checks per pair:
    //  1. CONNECTIVITY  — di reachable from bi forward, or wrap-around on loop.
    //  2. PROGRESS      — ride brings user ≥ minProgressMeters closer to dest.
    //  3. RIDE LENGTH   — at least 2 stops.
    // Score = walkToBoard + walkFromDrop + rideMeters×0.25  (time-equivalent).
    // rideMeters is now O(1) via prefix sums instead of O(n) per pair.
    const minProgressMeters = 50.0;

    RouteRecommendation? best;
    double               bestScore = double.infinity;

    for (final bHit in boardingCandidates) {
      final bi        = bHit.idx;
      final walkBoard = bHit.dist;
      final distBiToDest = dToDest[bi]; // pre-computed

      for (final dHit in dropoffCandidates) {
        final di       = dHit.idx;
        final walkDrop = dHit.dist;

        // 1. Connectivity
        if (bi == di) continue;
        final isForward = bi < di;
        final isWrap    = !isForward && isCircular;
        if (!isForward && !isWrap) continue;

        // 2. Progress toward destination (pre-computed dToDest[di])
        if (distBiToDest - dToDest[di] < minProgressMeters) continue;

        // 3. Ride length
        final stopCount = isWrap ? (n - 1 - bi) + di : di - bi;
        if (stopCount < 2) continue;

        // Ride distance — O(1) via prefix sums
        final rideM = isWrap
            ? (totalPathLen - prefix[bi]) + prefix[di]
            : prefix[di] - prefix[bi];

        final score = _singleScore(
          walkToBoarding:  walkBoard,
          walkFromDropoff: walkDrop,
          rideMeters:      rideM,
          walkWeight:      walkWeight,
          rideWeight:      rideWeight,
          priority:        priority,
          isModern:        route.isModern,
        );

        if (score < bestScore) {
          bestScore = score;
          best = RouteRecommendation(
            route:                 route,
            boardingIndex:         bi,
            dropoffIndex:          di,
            walkToBoardingMeters:  walkBoard,
            walkFromDropoffMeters: walkDrop,
            score:                 score,
          );
        }
      }
    }

    if (best != null) return _Pass(best);

    return _Fail(RouteRejection(
      route: route, gate: RejectionGate.wrongDirection,
      nearestOriginMeters: nearestOriginDist,
      nearestDestMeters:   nearestDestDist,
    ));
  }

  // ── Circular-route detector ───────────────────────────────────────────────
  //
  // A route is considered circular when its first and last GPS points are
  // within 150 m of each other.  150 m rather than a tighter threshold
  // because real-world GPS traces rarely close a loop perfectly.
  bool _isCircular(JeepneyRoute route) {
    final path = route.path;
    if (path.length < 3) return false;
    return _haversine(path.first, path.last) < 150.0;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PUBLIC: STATIC GRAPH PRECOMPUTATION
  // ════════════════════════════════════════════════════════════════════════════

  /// Build the query-independent parts of the routing graph (route nodes,
  /// onRoute edges, transfer edges) and return them in a serialisable form.
  ///
  /// Call this once after routes load (via [runStaticGraphIsolate]) and cache
  /// the result.  Pass it to [RoutingMessage.precomputedGraph] so each routing
  /// query skips the expensive O(R² × n²) transfer-edge scan.
  PrecomputedRouteGraph buildStaticGraph(List<JeepneyRoute> allRoutes) {
    final nodes        = <_Node>[];
    final routeNodeIds = <String, List<int>>{};
    final routeIndex   = <String, int>{};
    int   nextId       = 0;

    // ── 1. One node per route-path point ────────────────────────────────────
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

    // ── 2. onRoute edges (consecutive stops, directed forward) ───────────────
    for (final route in allRoutes) {
      final ids = routeNodeIds[route.routeId]!;
      for (int i = 0; i + 1 < ids.length; i++) {
        final cost = _haversine(nodes[ids[i]].point, nodes[ids[i + 1]].point);
        adj[ids[i]].add(_Edge(to: ids[i + 1], cost: cost, kind: _EdgeKind.onRoute));
      }
      // Closure edge for circular routes
      if (_isCircular(route) && ids.length >= 3) {
        final cost = _haversine(nodes[ids.last].point, nodes[ids.first].point);
        adj[ids.last].add(_Edge(to: ids.first, cost: cost, kind: _EdgeKind.onRoute));
      }
    }

    // ── 3. Transfer edges (cross-route stops within transferRadiusMeters) ────
    const transferWalkMultiplier = 3.0;

    final bbox = <String, _BBox>{};
    for (final route in allRoutes) {
      double minLat = double.infinity,  maxLat = -double.infinity;
      double minLng = double.infinity,  maxLng = -double.infinity;
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

        if (bboxA.minLat - marginDeg > bboxB.maxLat ||
            bboxB.minLat - marginDeg > bboxA.maxLat ||
            bboxA.minLng - marginDeg > bboxB.maxLng ||
            bboxB.minLng - marginDeg > bboxA.maxLng) continue;

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

    // ── 4. Serialise to flat arrays ──────────────────────────────────────────
    final lats          = List<double>.filled(nodeCount, 0);
    final lngs          = List<double>.filled(nodeCount, 0);
    final nodeRouteIds  = List<String?>.filled(nodeCount, null);
    final nodePathIdx   = List<int?>.filled(nodeCount, null);
    for (int i = 0; i < nodeCount; i++) {
      lats[i]         = nodes[i].point.latitude;
      lngs[i]         = nodes[i].point.longitude;
      nodeRouteIds[i] = nodes[i].route?.routeId;
      nodePathIdx[i]  = nodes[i].pathIndex;
    }

    return PrecomputedRouteGraph(
      nodeLats:        lats,
      nodeLngs:        lngs,
      nodeRouteIds:    nodeRouteIds,
      nodePathIndices: nodePathIdx,
      adjTo:    List.generate(nodeCount, (i) => adj[i].map((e) => e.to).toList()),
      adjCost:  List.generate(nodeCount, (i) => adj[i].map((e) => e.cost).toList()),
      adjKind:  List.generate(nodeCount, (i) => adj[i].map((e) => e.kind.index).toList()),
      routeNodeIds: routeNodeIds,
      routeIndex:   routeIndex,
      nodeCount:    nodeCount,
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // MULTI-ROUTE: GRAPH BUILD
  // ════════════════════════════════════════════════════════════════════════════

  /// Returns all valid multi-transfer journeys (transferCount >= 1).
  /// Returns an empty list if no such journey is found.
  List<RouteJourney> _tryMultiRoute(
    LatLng             origin,
    LatLng             destination,
    List<JeepneyRoute> allRoutes, {
    PrecomputedRouteGraph? precomputed,
    double        walkWeight = 1.0,
    double        rideWeight = 0.25,
    RoutePriority priority   = RoutePriority.balanced,
  }) {
    // Build graph
    final graph = _buildGraph(origin, destination, allRoutes,
        precomputed: precomputed);

    // Dijkstra
    final result = _dijkstra(graph);

    // Extract journeys
    return _extractJourneys(graph, result, origin, destination,
        walkWeight: walkWeight, rideWeight: rideWeight, priority: priority);
  }

  _Graph _buildGraph(
    LatLng             origin,
    LatLng             destination,
    List<JeepneyRoute> allRoutes, {
    PrecomputedRouteGraph? precomputed,
  }) {
    // Fast path: static nodes + edges already built; only inject virtual
    // origin/destination nodes and their per-query walkToRoute edges.
    if (precomputed != null) {
      return _buildGraphFromPrecomputed(origin, destination, allRoutes, precomputed);
    }
    final nodes         = <_Node>[];
    final routeNodeIds  = <String, List<int>>{};
    final routeIndex    = <String, int>{};
    int   nextId        = 0;

    // ── 1. Create one node per route-path point ──────────────────────────────
    for (int ri = 0; ri < allRoutes.length; ri++) {
      final route = allRoutes[ri];
      routeIndex[route.routeId] = ri; // assign bitmask index
      final ids = <int>[];
      for (int i = 0; i < route.path.length; i++) {
        final id = nextId++;
        nodes.add(_Node(id: id, point: route.path[i], route: route, pathIndex: i));
        ids.add(id);
      }
      routeNodeIds[route.routeId] = ids;
    }

    // ── 2. Virtual origin and destination nodes ──────────────────────────────
    final originId = nextId++;
    final destId   = nextId++;
    nodes.add(_Node(id: originId, point: origin));
    nodes.add(_Node(id: destId,   point: destination));

    // ── 3. Build adjacency list ──────────────────────────────────────────────
    final adj = List<List<_Edge>>.generate(nextId, (_) => []);

    // onRoute edges: consecutive stops on the same route (directed forward only)
    for (final route in allRoutes) {
      final ids = routeNodeIds[route.routeId]!;
      for (int i = 0; i + 1 < ids.length; i++) {
        final cost = _haversine(nodes[ids[i]].point, nodes[ids[i + 1]].point);
        adj[ids[i]].add(_Edge(to: ids[i + 1], cost: cost, kind: _EdgeKind.onRoute));
      }
      // Closure edge for circular routes: last node → first node
      if (_isCircular(route) && ids.length >= 3) {
        final lastId  = ids.last;
        final firstId = ids.first;
        final cost    = _haversine(nodes[lastId].point, nodes[firstId].point);
        adj[lastId].add(_Edge(to: firstId, cost: cost, kind: _EdgeKind.onRoute));
      }
    }

    // transfer edges: between stops of DIFFERENT routes within transferRadiusMeters.
    // Walk distance multiplied by 3.0 for cost consistency with origin walk edges.
    //
    // Bounding-box pre-filter: before doing the O(n²) stop-pair scan for two
    // routes, check whether their geographic extents overlap within
    // transferRadiusMeters. Routes whose bounding boxes are far apart can never
    // have stops within transferRadiusMeters — skip them entirely.
    const transferWalkMultiplier = 3.0;

    // Pre-compute bounding box for each route.
    final bbox = <String, _BBox>{};
    for (final route in allRoutes) {
      double minLat = double.infinity,  maxLat = -double.infinity;
      double minLng = double.infinity,  maxLng = -double.infinity;
      for (final p in route.path) {
        if (p.latitude  < minLat) minLat = p.latitude;
        if (p.latitude  > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      bbox[route.routeId] = _BBox(minLat, maxLat, minLng, maxLng);
    }

    // 1 degree latitude ≈ 111 000 m; use this to convert transferRadiusMeters
    // to a degree margin for the bounding box overlap test.
    final marginDeg = transferRadiusMeters / 111000.0;

    final routeList = routeNodeIds.entries.toList();
    for (int ri = 0; ri < routeList.length; ri++) {
      for (int rj = ri + 1; rj < routeList.length; rj++) {
        final routeIdA = routeList[ri].key;
        final routeIdB = routeList[rj].key;
        final bboxA    = bbox[routeIdA]!;
        final bboxB    = bbox[routeIdB]!;

        // Bounding-box overlap test — skip if boxes are too far apart.
        if (bboxA.minLat - marginDeg > bboxB.maxLat ||
            bboxB.minLat - marginDeg > bboxA.maxLat ||
            bboxA.minLng - marginDeg > bboxB.maxLng ||
            bboxB.minLng - marginDeg > bboxA.maxLng) continue;

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

    // walkToRoute edges: origin → every route stop within radiusMeters.
    //
    // These are intentionally unfiltered by direction or detour ratio.
    // Reasons:
    //   1. For single-route journeys, _evaluate() already applies the full
    //      direction + detour check and picks the best boarding point.
    //   2. For multi-transfer journeys, the route may not need to reach the
    //      destination directly — it only needs to reach a transfer point.
    //      Filtering by "must go toward destination" would incorrectly block
    //      valid boarding stops whose route heads toward a transfer point
    //      rather than straight to the destination.
    //
    // Dijkstra's cost model handles the rest: walk distance is multiplied by
    // walkCostMultiplier (3.0) so that walking 1 m costs as much as riding 3 m.
    // This strongly prices in favour of nearby boarding stops — a stop 50 m
    // away beats one 800 m away by 2 250 m of effective cost even if the ride
    // on the closer stop is longer.
    const walkCostMultiplier = 3.0;
    for (int id = 0; id < nodes.length - 2; id++) {
      final walkDist = _haversine(origin, nodes[id].point);
      if (walkDist <= radiusMeters) {
        adj[originId].add(_Edge(
          to:   id,
          cost: walkDist * walkCostMultiplier,
          kind: _EdgeKind.walkToRoute,
        ));
      }
    }

    // walkToRoute edges: every route stop within radiusMeters → destination.
    for (int id = 0; id < nodes.length - 2; id++) {
      final d = _haversine(nodes[id].point, destination);
      if (d <= radiusMeters) {
        adj[id].add(_Edge(to: destId, cost: d, kind: _EdgeKind.walkToRoute));
      }
    }

    return _Graph(
      nodes:        nodes,
      adj:          adj,
      originId:     originId,
      destId:       destId,
      routeNodeIds: routeNodeIds,
      routeIndex:   routeIndex,
    );
  }

  // ── Fast-path graph build using precomputed static data ───────────────────
  //
  // Skips node creation, onRoute edges, and the expensive transfer-edge scan.
  // Only adds the two virtual nodes (origin/dest) and their walkToRoute edges.
  _Graph _buildGraphFromPrecomputed(
    LatLng                origin,
    LatLng                destination,
    List<JeepneyRoute>    allRoutes,
    PrecomputedRouteGraph precomputed,
  ) {
    final routeById = { for (final r in allRoutes) r.routeId: r };
    final n = precomputed.nodeCount;

    // Reconstruct _Node objects from flat arrays + live route references.
    final nodes = List<_Node>.generate(n, (i) {
      final rid = precomputed.nodeRouteIds[i];
      return _Node(
        id:        i,
        point:     LatLng(precomputed.nodeLats[i], precomputed.nodeLngs[i]),
        route:     rid != null ? routeById[rid] : null,
        pathIndex: precomputed.nodePathIndices[i],
      );
    });

    // Virtual origin and destination nodes.
    final originId = n;
    final destId   = n + 1;
    nodes.add(_Node(id: originId, point: origin));
    nodes.add(_Node(id: destId,   point: destination));

    // Reconstruct adjacency list from flat arrays (mutable copies so we can
    // append walkToRoute edges without touching the precomputed data).
    final adj = List<List<_Edge>>.generate(n + 2, (i) {
      if (i >= n) return <_Edge>[];
      final tos   = precomputed.adjTo[i];
      final costs = precomputed.adjCost[i];
      final kinds = precomputed.adjKind[i];
      return List<_Edge>.generate(
        tos.length,
        (j) => _Edge(to: tos[j], cost: costs[j], kind: _EdgeKind.values[kinds[j]]),
      );
    });

    // walkToRoute edges: origin → nearby stops.
    const walkCostMultiplier = 3.0;
    for (int id = 0; id < n; id++) {
      final walkDist = _haversine(origin, nodes[id].point);
      if (walkDist <= radiusMeters) {
        adj[originId].add(_Edge(
          to:   id,
          cost: walkDist * walkCostMultiplier,
          kind: _EdgeKind.walkToRoute,
        ));
      }
    }

    // walkToRoute edges: nearby stops → destination.
    for (int id = 0; id < n; id++) {
      final d = _haversine(nodes[id].point, destination);
      if (d <= radiusMeters) {
        adj[id].add(_Edge(to: destId, cost: d, kind: _EdgeKind.walkToRoute));
      }
    }

    return _Graph(
      nodes:        nodes,
      adj:          adj,
      originId:     originId,
      destId:       destId,
      routeNodeIds: precomputed.routeNodeIds,
      routeIndex:   precomputed.routeIndex,
    );
  }
  // ════════════════════════════════════════════════════════════════════════════

  _DResult _dijkstra(_Graph graph) {
    final numRoutes  = graph.routeIndex.length;
    final maskRange  = 1 << numRoutes;           // 2^numRoutes possible masks
    final tRange     = maxTransfersAllowed + 1;  // 0..maxTransfersAllowed
    final stride     = tRange * maskRange;
    final totalStates = graph.nodes.length * stride;

    // Flat arrays replace HashMap — O(1) access with zero hash overhead.
    final dist    = List<double>.filled(totalStates, double.infinity);
    final prevKey = List<int>.filled(totalStates, -1);

    final result = _DResult(
      dist: dist, prevKey: prevKey,
      stride: stride, maskRange: maskRange,
    );

    int encode(int nodeId, int t, int mask) =>
        nodeId * stride + t * maskRange + mask;

    final pq       = _MinHeap<_DState>();
    final startKey = encode(graph.originId, 0, 0);
    dist[startKey] = 0;
    pq.add(_DState(graph.originId, 0.0, 0, 0));

    while (pq.isNotEmpty) {
      final cur = pq.removeFirst();
      final ck  = encode(cur.nodeId, cur.transfers, cur.routeMask);

      // Skip stale entries
      if (cur.cost > dist[ck] + 1e-9) continue;

      // Early exit once destination is settled
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
            // No-re-boarding: skip if this route's bit is already set
            if (bit != null && (cur.routeMask & (1 << bit)) != 0) continue;

            newTransfers += 1;
            if (newTransfers > maxTransfersAllowed) continue;

            if (bit != null) newMask |= (1 << bit);
          }
        }
        // onRoute edges: still on same jeepney, mask unchanged.

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
    _Graph   graph,
    _DResult result,
    LatLng   origin,
    LatLng   destination, {
    double        walkWeight = 1.0,
    double        rideWeight = 0.25,
    RoutePriority priority   = RoutePriority.balanced,
  }) {
    final journeys = <RouteJourney>[];

    for (int t = 1; t <= maxTransfersAllowed; t++) {
      int    bestKey  = -1;
      double bestCost = double.infinity;
      for (int mask = 0; mask < result.maskRange; mask++) {
        final k = result.encode(graph.destId, t, mask);
        if (result.dist[k] < bestCost) {
          bestCost = result.dist[k];
          bestKey  = k;
        }
      }
      if (bestKey == -1 || bestCost.isInfinite) continue;

      final journey = _backtrack(
          graph, result, graph.destId, t, bestKey, origin, destination,
          rideWeight: rideWeight, walkWeight: walkWeight, priority: priority);
      if (journey != null) journeys.add(journey);
    }

    return journeys;
  }

  /// Backtrack from [destKey] through prevKey to reconstruct RouteSegments.
  RouteJourney? _backtrack(
    _Graph   graph,
    _DResult result,
    int      destId,
    int      transfers,
    int      destKey,
    LatLng   origin,
    LatLng   destination, {
    double        rideWeight = 0.25,
    double        walkWeight = 1.0,
    RoutePriority priority   = RoutePriority.balanced,
  }) {
    // Walk back through integer parent pointers.
    final rawKeys = <int>[];
    int cur = destKey;
    while (cur != -1) {
      rawKeys.add(cur);
      cur = result.prevKey[cur];
    }
    rawKeys.reversed.toList(); // keep in forward order below

    // Decode keys back to nodeIds in forward order.
    final nodeIds = rawKeys.reversed
        .map((k) => k ~/ result.stride) // nodeId = key / stride
        .toList();

    if (nodeIds.isEmpty || nodeIds.first != graph.originId) return null;

    // ── Convert node sequence into RouteSegments ────────────────────────────
    final segments       = <RouteSegment>[];
    final transferPoints = <LatLng>[];

    // Strip virtual origin and destination nodes; keep only route nodes.
    final routeNodes = nodeIds
        .where((id) => graph.nodes[id].route != null)
        .map((id) => graph.nodes[id])
        .toList();

    if (routeNodes.isEmpty) return null;

    // Group consecutive nodes that share the same route into segments.
    // For each segment: board at nearest stop to previous location,
    // alight at the last consecutive stop on this route.
    int segStart = 0;
    while (segStart < routeNodes.length) {
      final segRoute = routeNodes[segStart].route!;
      int segEnd = segStart;
      while (segEnd + 1 < routeNodes.length &&
          routeNodes[segEnd + 1].route?.routeId == segRoute.routeId) {
        segEnd++;
      }

      // Boarding: use the exact path index Dijkstra traversed.
      // Do NOT re-run a nearest-stop search here — that would override the
      // graph path and can fabricate segments on routes Dijkstra never used,
      // breaking the no-re-boarding guarantee enforced during the search.
      final boardingIdx = routeNodes[segStart].pathIndex!;
      final prevLocation = segments.isEmpty ? origin : segments.last.dropoffPoint;
      final nearestToBoardDist =
          _haversine(prevLocation, segRoute.path[boardingIdx]);

      // Dropoff index:
      // • Intermediate segments: use Dijkstra's exact exit node (transfer pt).
      // • Final segment: scan all stops forward from boardingIdx and pick the
      //   one with the MINIMUM walk distance to the destination, mirroring
      //   exactly what _evaluate does on the single-route path.
      //
      //   "Nearest to destination" rather than "first within radius" — the
      //   earlier "first reachable" logic was wrong: the first stop within
      //   radiusMeters can still be 900m from the destination while a later
      //   stop is only 30m away.
      final bool isLastSegment = (segEnd + 1 >= routeNodes.length);
      int dropoffIdx;
      if (isLastSegment) {
        final pathLen     = segRoute.path.length;
        final isCircRoute = _isCircular(segRoute);
        dropoffIdx        = routeNodes[segEnd].pathIndex!; // fallback

        // Build prefix-sum of cumulative path distances so ride distance
        // from boardingIdx to any stop i is O(1): prefix[i] - prefix[boardingIdx].
        // This mirrors exactly what _evaluate() does for single-route scoring.
        final prefix = List<double>.filled(pathLen, 0);
        for (int i = 1; i < pathLen; i++) {
          prefix[i] = prefix[i - 1] +
              _haversine(segRoute.path[i - 1], segRoute.path[i]);
        }
        final totalPathLen = prefix[pathLen - 1];

        // Use the same balanced score as _singleScore():
        //   score = walkFromAlight + rideDistance × rideWeight
        //
        // Purely minimising walkFromAlight (the old logic) ignores ride
        // distance and causes the route to go the long way around a circular
        // loop just to save a few metres of walking at the end.
        double bestScore = double.infinity;

        // Forward pass: boardingIdx+1 → end of path
        for (int i = boardingIdx + 1; i < pathLen; i++) {
          final walkDist = _haversine(segRoute.path[i], destination);
          if (walkDist > radiusMeters) continue;
          final rideDist = prefix[i] - prefix[boardingIdx];
          final score    = walkDist + rideDist * rideWeight;
          if (score < bestScore) { bestScore = score; dropoffIdx = i; }
        }
        // Wrap pass for circular routes
        if (isCircRoute) {
          for (int i = 0; i < boardingIdx; i++) {
            final walkDist = _haversine(segRoute.path[i], destination);
            if (walkDist > radiusMeters) continue;
            final rideDist = (totalPathLen - prefix[boardingIdx]) + prefix[i];
            final score    = walkDist + rideDist * rideWeight;
            if (score < bestScore) { bestScore = score; dropoffIdx = i; }
          }
        }
      } else {
        dropoffIdx = routeNodes[segEnd].pathIndex!;
      }

      // Guard: segment must travel forward OR wrap around a circular route.
      final isWrap = boardingIdx > dropoffIdx && _isCircular(segRoute);
      if (boardingIdx >= dropoffIdx && !isWrap) {
        segStart = segEnd + 1;
        continue;
      }

      // Guard: minimum ride length — mirrors single-route _evaluate() check.
      final stopCount = isWrap
          ? (segRoute.path.length - 1 - boardingIdx) + dropoffIdx
          : dropoffIdx - boardingIdx;
      if (stopCount < 2) {
        segStart = segEnd + 1;
        continue;
      }

      // Guard: circular route long-ride rejection.
      // For a circular/loop route the forward scan always finds the nearest
      // stop to the destination, but that stop may require riding 80-90% of
      // the full loop — the classic "long way around" problem. Reject any
      // segment whose ride covers more than 65% of the total path length;
      // a useful circular ride should use at most the shorter arc.
      if (_isCircular(segRoute) &&
          stopCount > (segRoute.path.length * 0.65).round()) {
        return null;
      }

      final boardingPt = segRoute.path[boardingIdx];
      final walkToBoard = nearestToBoardDist;
      
      final dropoffPt = segRoute.path[dropoffIdx];
      
      // Walk from dropoff: to nearest on next route, or destination
      double walkFromDrop;
      if (segEnd + 1 < routeNodes.length) {
        final nextRoute = routeNodes[segEnd + 1].route!;
        double nearestToDrop = double.infinity;
        for (int i = 0; i < nextRoute.path.length; i++) {
          final d = _haversine(dropoffPt, nextRoute.path[i]);
          if (d < nearestToDrop) {
            nearestToDrop = d;
          }
        }
        walkFromDrop = nearestToDrop;
      } else {
        walkFromDrop = _haversine(dropoffPt, destination);
      }

      if (segments.isNotEmpty) {
        // Transfer point is the midpoint of the walk between two routes
        transferPoints.add(_midpoint(segments.last.dropoffPoint, boardingPt));
      }

      segments.add(RouteSegment(
        route:                 segRoute,
        boardingIndex:         boardingIdx,
        dropoffIndex:          dropoffIdx,
        walkToBoardingMeters:  walkToBoard,
        walkFromDropoffMeters: walkFromDrop,
        isWrapAround:          isWrap,
      ));

      segStart = segEnd + 1;
    }

    if (segments.isEmpty) return null;

    // ── Compute summary metrics ──────────────────────────────────────────────
    final totalWalk = segments.fold(
      0.0,
      (sum, s) => sum + s.walkToBoardingMeters + s.walkFromDropoffMeters,
    );
    final rideKm = segments.fold(
      0.0, (sum, s) => sum + s.rideDistanceMeters,
    ) / 1000.0;
    final walkKm = totalWalk / 1000.0;

    // Rough estimate: 5 km/h walking, 20 km/h riding, 5 min per transfer
    final estimatedMinutes =
        (walkKm / 5.0 * 60.0) + (rideKm / 20.0 * 60.0) + (transfers * 5.0);

    // Score: re-derive a clean comparable score that respects priority.
    final score = totalWalk * walkWeight + (rideKm * 1000.0 * rideWeight) +
                  (transfers * transferPenaltyMeters);

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
    required double        walkToBoarding,
    required double        walkFromDropoff,
    required double        rideMeters,
    double                 walkWeight = 1.0,
    double                 rideWeight = 0.25,
    RoutePriority          priority   = RoutePriority.balanced,
    bool                   isModern   = false,
  }) {
    return (walkToBoarding + walkFromDropoff) * walkWeight + (rideMeters * rideWeight);
  }

  double _haversine(LatLng a, LatLng b) => _dist.as(LengthUnit.Meter, a, b);

  LatLng _midpoint(LatLng a, LatLng b) => LatLng(
    (a.latitude  + b.latitude)  / 2.0,
    (a.longitude + b.longitude) / 2.0,
  );
}

// ── Polyline distance helper (file-private) ───────────────────────────────────
double _polylineDistance(List<LatLng> pts) {
  const d = Distance();
  double total = 0;
  for (int i = 0; i + 1 < pts.length; i++) {
    total += d.as(LengthUnit.Meter, pts[i], pts[i + 1]);
  }
  return total;
}

// ════════════════════════════════════════════════════════════════════════════
// INTERNAL TYPES  (file-private)
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

/// Axis-aligned bounding box for a route path, used for transfer-edge pruning.
class _BBox {
  final double minLat, maxLat, minLng, maxLng;
  const _BBox(this.minLat, this.maxLat, this.minLng, this.maxLng);
}
// ── Minimal binary min-heap (no external packages needed) ────────────────────
// Pure Dart replacement for the removed HeapPriorityQueue.
// T must implement Comparable<T>.

class _MinHeap<T extends Comparable<T>> {
  final _data = <T>[];

  bool get isNotEmpty => _data.isNotEmpty;

  void add(T item) {
    _data.add(item);
    _bubbleUp(_data.length - 1);
  }

  T removeFirst() {
    final top  = _data.first;
    final last = _data.removeLast();
    if (_data.isNotEmpty) {
      _data[0] = last;
      _sinkDown(0);
    }
    return top;
  }

  void _bubbleUp(int i) {
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_data[i].compareTo(_data[parent]) < 0) {
        final tmp      = _data[i];
        _data[i]       = _data[parent];
        _data[parent]  = tmp;
        i              = parent;
      } else break;
    }
  }

  void _sinkDown(int i) {
    final n = _data.length;
    while (true) {
      int smallest = i;
      final l = 2 * i + 1, r = 2 * i + 2;
      if (l < n && _data[l].compareTo(_data[smallest]) < 0) smallest = l;
      if (r < n && _data[r].compareTo(_data[smallest]) < 0) smallest = r;
      if (smallest == i) break;
      final tmp         = _data[i];
      _data[i]          = _data[smallest];
      _data[smallest]   = tmp;
      i                 = smallest;
    }
  }
}

// ── compute() helpers ─────────────────────────────────────────────────────────
// compute() requires a top-level function and a single serialisable argument.
// _RoutingMessage bundles everything the isolate needs; runRoutingIsolate is
// the top-level entry point passed to compute().

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

  /// Optional precomputed static graph. When provided, _buildGraph skips the
  /// expensive node-creation and transfer-edge scan on every query.
  final PrecomputedRouteGraph? precomputedGraph;

  const RoutingMessage({
    required this.origin,
    required this.destination,
    required this.allRoutes,
    required this.radiusMeters,
    required this.transferRadiusMeters,
    required this.transferPenaltyMeters,
    required this.maxTransfersAllowed,
    required this.maxResults,
    this.priority = RoutePriority.balanced,
    this.precomputedGraph,
  });
}

/// Top-level function executed in a background isolate via Flutter's compute().
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
  );
}