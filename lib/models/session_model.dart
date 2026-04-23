import 'gps_point.dart';

class Session {
  final String id;
  final List<GPSPoint> points;

  Session({
    required this.id,
    required this.points,
  });
}