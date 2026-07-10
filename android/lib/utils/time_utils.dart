import 'package:intl/intl.dart';

/// Server timestamps are naive UTC serialized as ISO-8601 with a `Z` suffix
/// (see serialize_doc in app.py). The web UI displays them in IST (+5:30).
/// India has no DST, so a fixed offset is correct.
const Duration _istOffset = Duration(hours: 5, minutes: 30);

/// Parse a server timestamp string into a UTC [DateTime].
/// Returns null for null/empty/unparseable input.
DateTime? parseServerTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;
  // Server strings carry Z so parse yields UTC; normalize just in case.
  return parsed.isUtc ? parsed : parsed.toUtc();
}

DateTime _toIst(DateTime utc) => utc.add(_istOffset);

/// "09 Jul 2026, 02:45 PM" — matches the web app's IST display style.
String formatIst(DateTime? utc) {
  if (utc == null) return '—';
  return DateFormat('dd MMM yyyy, hh:mm a').format(_toIst(utc));
}

/// Short form for dense lists: "09 Jul, 02:45 PM".
String formatIstShort(DateTime? utc) {
  if (utc == null) return '—';
  return DateFormat('dd MMM, hh:mm a').format(_toIst(utc));
}

/// "5m ago" / "3h ago" / "2d ago" — mirrors formatTimeAgo in fe_dashboard.html.
String formatTimeAgo(DateTime? utc) {
  if (utc == null) return '—';
  final diff = DateTime.now().toUtc().difference(utc);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

/// Elapsed time as "2d 5h" / "5h 12m" — for the detail status card.
String formatElapsed(DateTime? startUtc, [DateTime? endUtc]) {
  if (startUtc == null) return '—';
  final end = endUtc ?? DateTime.now().toUtc();
  final diff = end.difference(startUtc);
  if (diff.isNegative) return '—';
  if (diff.inDays > 0) return '${diff.inDays}d ${diff.inHours % 24}h';
  if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
  return '${diff.inMinutes}m';
}
