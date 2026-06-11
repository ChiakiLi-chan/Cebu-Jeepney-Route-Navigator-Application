// lib/services/pdf_exporter.dart
//
// PDF export for the System Log and the Trip Tracker.
// Uses the `pdf` package to build pages and `printing` to surface the
// platform share / save / print sheet.
//
// Add these to pubspec.yaml under `dependencies:`:
//   pdf: ^3.10.8
//   printing: ^5.12.0
//
// Then run `flutter pub get`.

import 'package:flutter/material.dart' show Color;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:thesis_app/models/log_entry.dart';
import 'package:thesis_app/screens/route_finder.dart' show LogEntry, LogEventType;
import 'package:thesis_app/screens/trip_tracker.dart' show TripRecord;

class PdfExporter {

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Build a PDF of all log entries and open the platform share sheet.
  static Future<void> exportLogs(List<LogEntry> entries) async {
    final doc = pw.Document(
      title:  'Jeepney Route Finder — System Log',
      author: 'Jeepney Route Finder',
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat:    PdfPageFormat.a4,
        margin:        const pw.EdgeInsets.fromLTRB(36, 36, 36, 48),
        header:        (ctx) => _docHeader(
          title:    'System Log',
          subtitle: '${entries.length} '
                    'event${entries.length == 1 ? '' : 's'} recorded',
        ),
        footer:        _pageFooter,
        build: (ctx) {
          if (entries.isEmpty) {
            return [_emptyState('No events recorded.')];
          }
          return [_logTable(entries)];
        },
      ),
    );

    await Printing.sharePdf(
      bytes:    await doc.save(),
      filename: 'jeepney_log_${_filenameStamp()}.pdf',
    );
  }

  /// Build a PDF of all trips and open the platform share sheet.
  static Future<void> exportTrips(List<TripRecord> trips) async {
    final doc = pw.Document(
      title:  'Jeepney Route Finder — Trip Tracker',
      author: 'Jeepney Route Finder',
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat:    PdfPageFormat.a4,
        margin:        const pw.EdgeInsets.fromLTRB(36, 36, 36, 48),
        header:        (ctx) => _docHeader(
          title:    'Trip Tracker',
          subtitle: '${trips.length} '
                    'trip${trips.length == 1 ? '' : 's'} recorded',
        ),
        footer:        _pageFooter,
        build: (ctx) {
          if (trips.isEmpty) {
            return [_emptyState('No trips recorded.')];
          }
          // Newest first — matches the in-app ordering.
          final reversed = trips.reversed.toList();
          return [
            _summaryStrip(reversed),
            pw.SizedBox(height: 14),
            ...reversed.map((t) => _tripCard(t)),
          ];
        },
      ),
    );

    await Printing.sharePdf(
      bytes:    await doc.save(),
      filename: 'jeepney_trips_${_filenameStamp()}.pdf',
    );
  }

  // ── Shared layout helpers ───────────────────────────────────────────────────

  static pw.Widget _docHeader({required String title, required String subtitle}) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 12),
      margin:  const pw.EdgeInsets.only(bottom: 14),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(width: 1.2, color: PdfColors.grey400),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Jeepney Route Finder',
                    style: pw.TextStyle(
                      fontSize: 10,
                      color:    PdfColors.grey600,
                      fontWeight: pw.FontWeight.bold,
                      letterSpacing: 1.2,
                    )),
                pw.SizedBox(height: 2),
                pw.Text(title,
                    style: pw.TextStyle(
                      fontSize:   20,
                      fontWeight: pw.FontWeight.bold,
                      color:      PdfColors.black,
                    )),
                pw.SizedBox(height: 2),
                pw.Text(subtitle,
                    style: pw.TextStyle(
                      fontSize: 10,
                      color:    PdfColors.grey700,
                    )),
              ],
            ),
          ),
          pw.Text('Generated  ${_humanStamp(DateTime.now())}',
              style: pw.TextStyle(
                fontSize: 9,
                color:    PdfColors.grey600,
              )),
        ],
      ),
    );
  }

  static pw.Widget _pageFooter(pw.Context ctx) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(width: 0.5, color: PdfColors.grey300),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Jeepney Route Finder',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey500)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey500)),
        ],
      ),
    );
  }

  static pw.Widget _emptyState(String message) {
    return pw.Container(
      padding:    const pw.EdgeInsets.symmetric(vertical: 36),
      alignment:  pw.Alignment.center,
      child: pw.Text(message,
          style: pw.TextStyle(
            fontSize: 12,
            color:    PdfColors.grey600,
            fontStyle: pw.FontStyle.italic,
          )),
    );
  }

  // ── Log-specific layout ─────────────────────────────────────────────────────

  static pw.Widget _logTable(List<LogEntry> entries) {
    // Newest-first ordering matches the in-app log page.
    final reversed = entries.reversed.toList();

    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(70),
        1: pw.FixedColumnWidth(90),
        2: pw.FlexColumnWidth(),
      },
      border: pw.TableBorder(
        horizontalInside: pw.BorderSide(
            width: 0.5, color: PdfColors.grey300),
      ),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _th('Time'),
            _th('Type'),
            _th('Event'),
          ],
        ),
        ...reversed.map((e) => pw.TableRow(
          verticalAlignment: pw.TableCellVerticalAlignment.middle,
          children: [
            _td(_clockStamp(e.timestamp), mono: true),
            _td(_typeLabel(e.type), color: _pdfColor(e.color)),
            _logEventCell(e),
          ],
        )),
      ],
    );
  }

  static pw.Widget _logEventCell(LogEntry e) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisSize:       pw.MainAxisSize.min,
        children: [
          pw.Text(e.message,
              style: pw.TextStyle(
                fontSize:   10,
                fontWeight: pw.FontWeight.bold,
                color:      PdfColors.black,
              )),
          if (e.detail != null) ...[
            pw.SizedBox(height: 2),
            pw.Text(e.detail!,
                style: pw.TextStyle(
                  fontSize: 9,
                  color:    PdfColors.grey700,
                )),
          ],
        ],
      ),
    );
  }

  // ── Trip-specific layout ────────────────────────────────────────────────────

  static pw.Widget _summaryStrip(List<TripRecord> trips) {
    final totalDuration = trips.fold<Duration>(
      Duration.zero, (sum, t) => sum + t.duration);
    final avgAccuracy = trips.isEmpty
        ? 0.0
        : trips.fold<double>(0, (s, t) => s + t.accuracyPercent) / trips.length;

    pw.Widget cell(String label, String value) => pw.Expanded(
      child: pw.Container(
        padding:    const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: pw.BoxDecoration(
          color:        PdfColors.grey100,
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(label,
                style: pw.TextStyle(
                    fontSize: 8,
                    color:    PdfColors.grey600,
                    letterSpacing: 0.8)),
            pw.SizedBox(height: 3),
            pw.Text(value,
                style: pw.TextStyle(
                    fontSize:   13,
                    fontWeight: pw.FontWeight.bold,
                    color:      PdfColors.black)),
          ],
        ),
      ),
    );

    return pw.Row(
      children: [
        cell('TRIPS', trips.length.toString()),
        pw.SizedBox(width: 6),
        cell('TOTAL TIME', _humanDuration(totalDuration)),
        pw.SizedBox(width: 6),
        cell('AVG ACCURACY', '${avgAccuracy.toStringAsFixed(1)}%'),
      ],
    );
  }

  static pw.Widget _tripCard(TripRecord t) {
    final accuracyColor = t.accuracyPercent >= 80
        ? PdfColor.fromInt(0xFF0F9D58)
        : t.accuracyPercent >= 50
            ? PdfColor.fromInt(0xFFF9A825)
            : PdfColor.fromInt(0xFFEA4335);

    return pw.Container(
      margin:     const pw.EdgeInsets.only(bottom: 10),
      padding:    const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        border:       pw.Border.all(
            width: 0.6, color: PdfColors.grey300),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              // Route badge
              pw.Container(
                width:      32, height: 32,
                alignment:  pw.Alignment.center,
                decoration: pw.BoxDecoration(
                  color: _pdfColor(t.routeColor),
                  shape: pw.BoxShape.circle,
                ),
                child: pw.Text(t.routeCode,
                    style: pw.TextStyle(
                      color:      PdfColors.white,
                      fontSize:   7,
                      fontWeight: pw.FontWeight.bold,
                    )),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(t.routeCode,
                        style: pw.TextStyle(
                          fontSize:   12,
                          fontWeight: pw.FontWeight.bold,
                          color:      PdfColors.black,
                        )),
                    pw.SizedBox(height: 2),
                    pw.Text(t.routeName,
                        style: pw.TextStyle(
                          fontSize: 10,
                          color:    PdfColors.grey700,
                        )),
                  ],
                ),
              ),
              // Accuracy badge
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: pw.BoxDecoration(
                  color:        PdfColor(
                      accuracyColor.red,
                      accuracyColor.green,
                      accuracyColor.blue,
                      0.12),
                  borderRadius: pw.BorderRadius.circular(10),
                ),
                child: pw.Text(
                    '${t.accuracyPercent.toStringAsFixed(1)}%',
                    style: pw.TextStyle(
                      fontSize:   10,
                      fontWeight: pw.FontWeight.bold,
                      color:      accuracyColor,
                    )),
              ),
            ],
          ),

          pw.SizedBox(height: 10),
          pw.Container(
            height: 0.5,
            color:  PdfColors.grey200,
          ),
          pw.SizedBox(height: 8),

          pw.Row(
            children: [
              _statTile('Started',   _humanStamp(t.startTime)),
              _statTile('Ended',     _humanStamp(t.endTime)),
              _statTile('Duration',  t.formattedDuration),
              _statTile('GPS pts',   t.gpsPath.length.toString()),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _statTile(String label, String value) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label,
            style: pw.TextStyle(
                fontSize: 7,
                color:    PdfColors.grey600,
                letterSpacing: 0.8)),
        pw.SizedBox(height: 2),
        pw.Text(value,
            style: pw.TextStyle(
              fontSize:   9,
              fontWeight: pw.FontWeight.bold,
              color:      PdfColors.black,
            )),
      ],
    ),
  );

  // ── Table cell helpers ──────────────────────────────────────────────────────

  static pw.Widget _th(String text) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    child: pw.Text(text,
        style: pw.TextStyle(
          fontSize:      9,
          fontWeight:    pw.FontWeight.bold,
          color:         PdfColors.grey700,
          letterSpacing: 0.8,
        )),
  );

  static pw.Widget _td(String text, {bool mono = false, PdfColor? color}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: pw.Text(text,
            style: pw.TextStyle(
              fontSize: 9,
              color:    color ?? PdfColors.black,
              fontWeight:
                  color != null ? pw.FontWeight.bold : pw.FontWeight.normal,
            )),
      );

  // ── Formatters ──────────────────────────────────────────────────────────────

  static String _clockStamp(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  static String _humanStamp(DateTime t) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${months[t.month]} ${t.day}, ${t.year}  $h:$m';
  }

  static String _filenameStamp() {
    final t = DateTime.now();
    return '${t.year}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}_'
        '${t.hour.toString().padLeft(2, '0')}'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  static String _humanDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }

  static String _typeLabel(LogEventType t) {
    switch (t) {
      case LogEventType.originSet:        return 'Origin';
      case LogEventType.destinationSet:   return 'Destination';
      case LogEventType.routingStarted:   return 'Routing';
      case LogEventType.routingCompleted: return 'Result';
      case LogEventType.routeSelected:    return 'Selection';
      case LogEventType.cleared:          return 'Cleared';
    }
  }

  /// Convert a Flutter [Color] to a pdf [PdfColor].
  static PdfColor _pdfColor(Color c) =>
      PdfColor(c.red / 255.0, c.green / 255.0, c.blue / 255.0, c.opacity);
}