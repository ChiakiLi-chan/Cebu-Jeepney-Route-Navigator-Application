// lib/models/routing_models.dart
//
// Public result types returned by JeepneyRouter.
// Imported by routing consumers (route_finder_page, route_finder_widgets).
// Contains no algorithm logic.

import 'package:latlong2/latlong.dart';
import 'package:thesis_app/data/jeepney_routes.dart';

// ══════════════════════════════════════════════════════════════════════════════
// REJECTION DIAGNOSTICS  (unchanged)
// ══════════════════════════════════════════════════════════════════════════════

/// Which gate eliminated a route.
enum RejectionGate {
  originTooFar,    // nearest point to Origin exceeded radiusMeters
  destTooFar,      // nearest point to Destination exceeded radiusMeters
  wrongDirection,  // boarding index >= dropoff index (route runs backwards)
  rideTooShort,    // dropoff - boarding < 2 (trivially short segment)
}

extension RejectionGateLabel on RejectionGate {
  String get label {
    switch (this) {
      case RejectionGate.originTooFar:   return 'Origin too far from route';
      case RejectionGate.destTooFar:     return 'Destination too far from route';
      case RejectionGate.wrongDirection: return 'Route travels in wrong direction';
      case RejectionGate.rideTooShort:   return 'Ride segment too short';
    }
  }
}

/// Diagnostic record for one rejected route.
class RouteRejection {
  final JeepneyRoute  route;
  final RejectionGate gate;
  final double?       nearestOriginMeters;
  final double?       nearestDestMeters;

  const RouteRejection({
    required this.route,
    required this.gate,
    this.nearestOriginMeters,
    this.nearestDestMeters,
  });

  String get detail {
    String fmt(double? m) => m == null
        ? ''
        : m < 1000
            ? ' (nearest: ${m.round()} m)'
            : ' (nearest: ${(m / 1000).toStringAsFixed(1)} km)';
    switch (gate) {
      case RejectionGate.originTooFar:   return gate.label + fmt(nearestOriginMeters);
      case RejectionGate.destTooFar:     return gate.label + fmt(nearestDestMeters);
      case RejectionGate.wrongDirection: return gate.label;
      case RejectionGate.rideTooShort:   return gate.label;
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SINGLE-ROUTE RESULT  (kept for backward compat; used internally as fallback)
// ══════════════════════════════════════════════════════════════════════════════

class RouteRecommendation {
  final JeepneyRoute route;
  final int          boardingIndex;
  final int          dropoffIndex;
  final double       walkToBoardingMeters;
  final double       walkFromDropoffMeters;
  final double       score;

  const RouteRecommendation({
    required this.route,
    required this.boardingIndex,
    required this.dropoffIndex,
    required this.walkToBoardingMeters,
    required this.walkFromDropoffMeters,
    required this.score,
  });

  LatLng get boardingPoint      => route.path[boardingIndex];
  LatLng get dropoffPoint       => route.path[dropoffIndex];
  double get totalWalkingMeters => walkToBoardingMeters + walkFromDropoffMeters;
  int    get rideSegmentCount   => dropoffIndex - boardingIndex;

  List<LatLng> get ridePolyline =>
      route.path.sublist(boardingIndex, dropoffIndex + 1);
}

// ══════════════════════════════════════════════════════════════════════════════
// MULTI-TRANSFER RESULT TYPES
// ══════════════════════════════════════════════════════════════════════════════

/// One leg of a multi-route journey: board one jeepney, ride it, alight.
class RouteSegment {
  final JeepneyRoute route;

  /// Index into route.path where the passenger boards.
  final int boardingIndex;

  /// Index into route.path where the passenger alights.
  final int dropoffIndex;

  /// Walk distance from the previous alight point (or origin) to boardingPoint.
  final double walkToBoardingMeters;

  /// Walk distance from dropoffPoint to the next board point (or destination).
  final double walkFromDropoffMeters;

  /// True when this segment wraps around the end of a circular route.
  /// boarding index > dropoff index in this case; the ride goes
  /// path[boardingIndex..last] + path[0..dropoffIndex].
  final bool isWrapAround;

  const RouteSegment({
    required this.route,
    required this.boardingIndex,
    required this.dropoffIndex,
    required this.walkToBoardingMeters,
    required this.walkFromDropoffMeters,
    this.isWrapAround = false,
  });

  LatLng get boardingPoint => route.path[boardingIndex];
  LatLng get dropoffPoint  => route.path[dropoffIndex];

  /// Number of stops in this ride leg (always positive).
  int get stopCount => isWrapAround
      ? (route.path.length - 1 - boardingIndex) + dropoffIndex
      : dropoffIndex - boardingIndex;

  /// Cumulative haversine distance of all on-route segments.
  double get rideDistanceMeters {
    double total = 0;
    final path   = route.path;
    if (isWrapAround) {
      // boarding → end of path
      for (int i = boardingIndex; i < path.length - 1; i++) {
        total += const Distance().as(LengthUnit.Meter, path[i], path[i + 1]);
      }
      // start of path → dropoff
      for (int i = 0; i < dropoffIndex; i++) {
        total += const Distance().as(LengthUnit.Meter, path[i], path[i + 1]);
      }
    } else {
      for (int i = boardingIndex; i < dropoffIndex; i++) {
        total += const Distance().as(LengthUnit.Meter, path[i], path[i + 1]);
      }
    }
    return total;
  }

  /// Ordered path points for the active ride (boarding → dropoff inclusive).
  List<LatLng> get ridePolyline {
    if (isWrapAround) {
      return [
        ...route.path.sublist(boardingIndex),
        ...route.path.sublist(0, dropoffIndex + 1),
      ];
    }
    return route.path.sublist(boardingIndex, dropoffIndex + 1);
  }
}

/// A complete journey from origin to destination, possibly spanning multiple
/// jeepney routes connected by walking transfer legs.
class RouteJourney {
  /// Ordered list of ride segments. Length 1 = direct (no transfer).
  final List<RouteSegment> segments;

  /// Walking waypoints between consecutive segments (length = segments.length - 1).
  /// Each element is the geographic midpoint of the transfer walk; useful for
  /// drawing the walk polyline on the map.
  final List<LatLng> transferPoints;

  final double totalWalkingMeters;
  final int    transferCount;

  /// Rough estimate: walking at 5 km/h + riding at 20 km/h +
  /// 5 min penalty per transfer.
  final double estimatedJourneyMinutes;

  /// Lower score = better. Combines walking, transfers, and ride efficiency.
  final double score;

  const RouteJourney({
    required this.segments,
    required this.transferPoints,
    required this.totalWalkingMeters,
    required this.transferCount,
    required this.estimatedJourneyMinutes,
    required this.score,
  });

  bool get isDirect => transferCount == 0;

  double get totalRideDistanceMeters =>
      segments.fold(0.0, (sum, s) => sum + s.rideDistanceMeters);

  /// Concatenated polyline: walk-to-first-board, ride, walk-to-transfer,
  /// ride, …, walk-to-destination.  Suitable for drawing the full path.
  List<LatLng> get fullPolyline {
    final points = <LatLng>[];
    for (int i = 0; i < segments.length; i++) {
      points.addAll(segments[i].ridePolyline);
      if (i < transferPoints.length) points.add(transferPoints[i]);
    }
    return points;
  }

  /// Convenience constructor: wrap a legacy RouteRecommendation as a
  /// single-segment RouteJourney so both code paths share one result type.
  factory RouteJourney.fromSingleRoute(RouteRecommendation rec) {
    final isWrap  = rec.boardingIndex > rec.dropoffIndex;
    final segment = RouteSegment(
      route:                 rec.route,
      boardingIndex:         rec.boardingIndex,
      dropoffIndex:          rec.dropoffIndex,
      walkToBoardingMeters:  rec.walkToBoardingMeters,
      walkFromDropoffMeters: rec.walkFromDropoffMeters,
      isWrapAround:          isWrap,
    );
    final walking = rec.totalWalkingMeters;
    final poly   = segment.ridePolyline;
    double rideDist = 0;
    for (int i = 0; i + 1 < poly.length; i++) {
      rideDist += const Distance().as(LengthUnit.Meter, poly[i], poly[i + 1]);
    }
    final rideKm  = rideDist / 1000.0;
    final minutes = (walking / 1000.0 / 5.0 * 60.0) + (rideKm / 20.0 * 60.0);

    return RouteJourney(
      segments:                [segment],
      transferPoints:          const [],
      totalWalkingMeters:      walking,
      transferCount:           0,
      estimatedJourneyMinutes: minutes,
      score:                   rec.score,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TOP-LEVEL RESULT TYPES
// ══════════════════════════════════════════════════════════════════════════════

sealed class RoutingResult {}

/// At least one viable journey was found.
/// [recommendations] is sorted ascending by score (best first).
/// Single-route journeys are returned here too (transferCount == 0).
class RoutingSuccess extends RoutingResult {
  final List<RouteJourney> recommendations;

  /// True when at least one result required a transfer.
  final bool hasTransfers;

  /// True when all quality-filtered candidates were suppressed and these
  /// results are the suppression fallback (best available, unfiltered).
  final bool isFallback;

  RoutingSuccess(this.recommendations, {this.hasTransfers = false, this.isFallback = false});
}

class RoutingFailure extends RoutingResult {
  final String            reason;
  final List<RouteRejection> rejections;

  RoutingFailure(this.reason, {this.rejections = const []});

  int get countOriginTooFar =>
      rejections.where((r) => r.gate == RejectionGate.originTooFar).length;
  int get countDestTooFar =>
      rejections.where((r) => r.gate == RejectionGate.destTooFar).length;
  int get countWrongDirection =>
      rejections.where((r) => r.gate == RejectionGate.wrongDirection).length;
  int get countRideTooShort =>
      rejections.where((r) => r.gate == RejectionGate.rideTooShort).length;

  RouteRejection? get closestOriginMiss {
    final c = rejections
        .where((r) => r.gate == RejectionGate.originTooFar && r.nearestOriginMeters != null)
        .toList()
      ..sort((a, b) => a.nearestOriginMeters!.compareTo(b.nearestOriginMeters!));
    return c.isEmpty ? null : c.first;
  }

  RouteRejection? get closestDestMiss {
    final c = rejections
        .where((r) => r.gate == RejectionGate.destTooFar && r.nearestDestMeters != null)
        .toList()
      ..sort((a, b) => a.nearestDestMeters!.compareTo(b.nearestDestMeters!));
    return c.isEmpty ? null : c.first;
  }
}