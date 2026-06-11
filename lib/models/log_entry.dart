// lib/models/log_entry.dart

import 'package:flutter/material.dart';

enum LogEventType {
  originSet,
  destinationSet,
  routingStarted,
  routingCompleted,
  routeSelected,
  cleared,
}

class LogEntry {
  final DateTime     timestamp;
  final LogEventType type;
  final String       message;
  final String?      detail;

  LogEntry({
    required this.type,
    required this.message,
    this.detail,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  IconData get icon {
    switch (type) {
      case LogEventType.originSet:        return Icons.trip_origin;
      case LogEventType.destinationSet:   return Icons.place;
      case LogEventType.routingStarted:   return Icons.directions;
      case LogEventType.routingCompleted: return Icons.check_circle_outline;
      case LogEventType.routeSelected:    return Icons.touch_app;
      case LogEventType.cleared:          return Icons.clear_all;
    }
  }

  Color get color {
    switch (type) {
      case LogEventType.originSet:        return const Color(0xFF34A853);
      case LogEventType.destinationSet:   return const Color(0xFFEA4335);
      case LogEventType.routingStarted:   return const Color(0xFF1A73E8);
      case LogEventType.routingCompleted: return const Color(0xFF0F9D58);
      case LogEventType.routeSelected:    return const Color(0xFFFB8C00);
      case LogEventType.cleared:          return Colors.grey;
    }
  }
}