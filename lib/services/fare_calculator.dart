// lib/services/fare_calculator.dart
//
// Pure static utility — no Flutter or widget dependencies.
// Computes LTFRB fare amounts for traditional and modern/electric jeepneys.

class FareCalculator {
  // Traditional jeepney fare schedule
  static const double _tradMinFare = 13.0; // covers first 4 km
  static const double _tradPerKm   =  1.80; // per succeeding kilometre

  // Modern/electric jeepney fare schedule
  static const double _modernMinFare = 15.0; // covers first 4 km
  static const double _modernPerKm   =  2.20; // per succeeding kilometre

  static const double _minDistKm       = 4.0;  // minimum-fare distance
  static const double _studentDiscount = 0.20; // 20% off

  /// Compute the regular fare for a single jeepney segment.
  ///
  /// Formula:
  ///   fare = minFare + (distKm - 4) x perKm   (for distKm > 4)
  ///
  /// Result is rounded to the nearest 0.25 interval.
  /// e.g. 2.40 -> 2.50  |  2.30 -> 2.25  |  3.90 -> 4.00
  static double regular(double distanceMeters, {required bool isModern}) {
    final distKm  = distanceMeters / 1000.0;
    final minFare = isModern ? _modernMinFare : _tradMinFare;
    final perKm   = isModern ? _modernPerKm   : _tradPerKm;
    final extraKm = (distKm - _minDistKm).clamp(0.0, double.infinity);
    final raw     = minFare + extraKm * perKm;
    // Round to nearest 0.25: multiply by 4, round to int, divide by 4.
    return (raw * 4).round() / 4.0;
  }

  /// Apply the student discount to a regular fare, then re-round to 0.25.
  static double student(double regularFare) =>
      ((regularFare * (1.0 - _studentDiscount)) * 4).round() / 4.0;

  /// Format a peso amount as "₱X.XX".
  static String format(double amount) =>
      '\u20b1${amount.toStringAsFixed(2)}';
}