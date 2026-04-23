import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

// ─── Jeepney Route Model ──────────────────────────────────────────────────────
class JeepneyRoute {
  final String routeId;
  final String routeName;
  final Color color;
  final List<LatLng> path;

  const JeepneyRoute({
    required this.routeId,
    required this.routeName,
    required this.color,
    required this.path,
  });
}

// ─── Cebu Jeepney Route Dataset ───────────────────────────────────────────────
// ⚠️  NOTE: These coordinates are approximate placeholders for development.
//     Replace with GPS-traced or LTFRB-sourced data before thesis submission.
//
// To add a new route:
//   1. Pick a unique routeId and routeName
//   2. Choose a color that isn't already used
//   3. Add LatLng waypoints that follow the real road path
//   4. Append a new JeepneyRoute(...) entry to the list below
// ─────────────────────────────────────────────────────────────────────────────
final List<JeepneyRoute> cebuJeepneyRoutes = [


  // ── 13-B: Talamban - Carbon ──────────────────────────────
  JeepneyRoute(
    routeId: '13-B',
    routeName: 'Talamban - Carbon',
    color: Color(0xFFE53935), // red
    path: [
      LatLng(10.371254, 123.924566), //Tintay
      LatLng(10.371166, 123.924418),
      LatLng(10.371626, 123.924116),
      LatLng(10.371159, 123.922571),
      LatLng(10.371135, 123.922053),
      LatLng(10.371022, 123.921814),
      LatLng(10.370457, 123.921130),
      LatLng(10.370420, 123.920835),
      LatLng(10.370861, 123.920218),
      LatLng(10.370795, 123.919974),
      LatLng(10.370146, 123.919274),
      LatLng(10.369824, 123.918797),
      LatLng(10.369481, 123.917727),
      LatLng(10.369331, 123.916890),
      LatLng(10.369106, 123.916324),
      LatLng(10.367676, 123.914057),
      LatLng(10.367046, 123.913886),
      LatLng(10.366901, 123.913835),
      LatLng(10.365671, 123.913832),
      LatLng(10.365048, 123.914025),
      LatLng(10.364671, 123.914508),
      LatLng(10.364344, 123.914752),
      LatLng(10.361935, 123.915366),
      LatLng(10.360927, 123.915310),
      LatLng(10.358840, 123.915696),
      LatLng(10.358618, 123.915683),
      LatLng(10.358318, 123.915546),
      LatLng(10.357687, 123.915136),
      LatLng(10.356014, 123.915085),
      LatLng(10.355637, 123.915036),
      LatLng(10.345787, 123.912705),
      LatLng(10.340053, 123.911713),
      LatLng(10.334255, 123.910702),
      LatLng(10.331375, 123.910061),
      LatLng(10.327923, 123.908642),
      LatLng(10.326124, 123.907808),
      LatLng(10.325678, 123.907344),
      LatLng(10.324129, 123.906271),
      LatLng(10.321910, 123.904801),
      LatLng(10.321477, 123.904431),
      LatLng(10.320495, 123.903798),
      LatLng(10.320276, 123.903927),
      LatLng(10.320044, 123.904493),
      LatLng(10.320078, 123.905426),
      LatLng(10.319936, 123.905767),
      LatLng(10.318458, 123.907711),
      LatLng(10.318257, 123.907757),
      LatLng(10.317453, 123.907043),
      LatLng(10.317057, 123.906257),
      LatLng(10.316748, 123.905965),
      LatLng(10.316363, 123.905785),
      LatLng(10.316286, 123.905568),
      LatLng(10.316611, 123.904420),
      LatLng(10.317228, 123.903728),
      LatLng(10.317468, 123.903272),
      LatLng(10.317767, 123.902628),
      LatLng(10.316431, 123.902033),
      LatLng(10.315268, 123.901604),
      LatLng(10.310837, 123.903908),
      LatLng(10.310652, 123.903937),
      LatLng(10.309335, 123.903484),
      LatLng(10.307937, 123.903082),
      LatLng(10.306776, 123.902518),
      LatLng(10.306533, 123.902390),
      LatLng(10.306216, 123.902079),
      LatLng(10.305710, 123.901411),
      LatLng(10.306493, 123.900684),
      LatLng(10.306607, 123.900370),
      LatLng(10.306652, 123.899721),
      LatLng(10.305198, 123.899898),
      LatLng(10.305153, 123.899882),
      LatLng(10.304725, 123.898302),
      LatLng(10.304802, 123.898176),
      LatLng(10.302936, 123.898219),
      LatLng(10.301941, 123.898240),
      LatLng(10.300725, 123.898900),
      LatLng(10.299764, 123.899431),
      LatLng(10.298917, 123.899925),
      LatLng(10.297597, 123.900649),
      LatLng(10.297793, 123.902052),
      LatLng(10.296906, 123.902154),
      LatLng(10.296858, 123.901370),
      LatLng(10.296328, 123.900126),
      LatLng(10.295703, 123.899488),
      LatLng(10.294362, 123.899053),
      LatLng(10.292348, 123.898471),
      LatLng(10.291974, 123.899589)
    ],
  ),

  // ── 04-A: Ayala Center – IT Park – Lahug ─────────────────────────────────
  JeepneyRoute(
    routeId: '04-A',
    routeName: 'Ayala – IT Park – Lahug',
    color: Color(0xFF1E88E5), // blue
    path: [
      LatLng(10.3179, 123.9050), // Ayala Center Cebu
      LatLng(10.3210, 123.9065), // Cebu Business Park
      LatLng(10.3252, 123.9072), // Archbishop Reyes Ave
      LatLng(10.3295, 123.9063), // Salinas Drive
      LatLng(10.3321, 123.9054), // near IT Park south gate
      LatLng(10.3354, 123.9045), // Cebu IT Park (Apas)
      LatLng(10.3388, 123.9032), // IT Park north exit
      LatLng(10.3421, 123.9018), // General Maxilom Ave
      LatLng(10.3461, 123.8998), // Lahug proper
      LatLng(10.3495, 123.8982), // Lahug terminus
    ],
  ),

  // ── 06-B: Talisay – Colon – Carbon ───────────────────────────────────────
  JeepneyRoute(
    routeId: '06-B',
    routeName: 'Talisay – Carbon',
    color: Color(0xFF43A047), // green
    path: [
      LatLng(10.2448, 123.8487), // Talisay City Hall
      LatLng(10.2521, 123.8542), // Tabunok
      LatLng(10.2589, 123.8601), // Linao
      LatLng(10.2665, 123.8658), // Bulacao
      LatLng(10.2745, 123.8713), // Pardo
      LatLng(10.2851, 123.8778), // Basak
      LatLng(10.2955, 123.8832), // Mambaling
      LatLng(10.3062, 123.8871), // Pasil
      LatLng(10.3131, 123.8888), // Carbon Market
      LatLng(10.3190, 123.8911), // Colon St terminus
    ],
  ),

  // ── 10-C: Talamban – Ayala via AS Fortuna ────────────────────────────────
  JeepneyRoute(
    routeId: '10-C',
    routeName: 'Talamban – Ayala',
    color: Color(0xFFFB8C00), // orange
    path: [
      LatLng(10.3852, 123.9121), // Talamban terminus
      LatLng(10.3798, 123.9095), // near Talamban Rd
      LatLng(10.3742, 123.9071), // Pit-os
      LatLng(10.3685, 123.9052), // AS Fortuna north
      LatLng(10.3621, 123.9038), // AS Fortuna mid (Mandaue boundary)
      LatLng(10.3558, 123.9029), // Tipolo
      LatLng(10.3489, 123.9021), // Subangdaku
      LatLng(10.3421, 123.9018), // Gen. Maxilom Ave
      LatLng(10.3354, 123.9045), // IT Park area
      LatLng(10.3252, 123.9072), // Archbishop Reyes Ave
      LatLng(10.3210, 123.9065), // Cebu Business Park
      LatLng(10.3179, 123.9050), // Ayala Center terminus
    ],
  ),

  // ── 62-C: Bulacao – SM via South Road Properties ─────────────────────────
  JeepneyRoute(
    routeId: '62-C',
    routeName: 'Bulacao – SM (SRP)',
    color: Color(0xFF8E24AA), // purple
    path: [
      LatLng(10.2665, 123.8658), // Bulacao
      LatLng(10.2721, 123.8612), // SRP south entry
      LatLng(10.2821, 123.8601), // SRP (South Road Properties)
      LatLng(10.2945, 123.8621), // SRP midpoint
      LatLng(10.3085, 123.8680), // SRP near SM area
      LatLng(10.3178, 123.8742), // SM Seaside connector
      LatLng(10.3225, 123.8812), // Reclamation Area
      LatLng(10.3312, 123.8875), // North Reclamation Rd
      LatLng(10.3420, 123.8955), // near Fuente
      LatLng(10.3522, 123.9057), // SM City Cebu terminus
    ],
  ),

];