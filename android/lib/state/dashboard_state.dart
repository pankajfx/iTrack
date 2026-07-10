import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:itrack_fe/api/trackers_api.dart';
import 'package:itrack_fe/models/tracker.dart';
import 'package:itrack_fe/models/user.dart';
import 'package:itrack_fe/services/socket_service.dart';
import 'package:itrack_fe/utils/constants.dart';

/// Dashboard list state: fetches /api/trackers/all-fe, splits into the three
/// web buckets, applies the search filter, and keeps itself fresh via
/// Socket.IO events + 30 s polling (the web app's hybrid mode).
class DashboardState extends ChangeNotifier {
  final TrackersApi _api = TrackersApi();

  List<Tracker> _all = [];
  String _search = '';
  TrackerBucket _bucket = TrackerBucket.unassigned;
  bool _loading = false;
  String? _error;

  Timer? _pollTimer;
  Timer? _socketDebounce;
  final List<void Function()> _socketUnsubs = [];
  User? _joinedAs;

  bool get loading => _loading;
  String? get error => _error;
  TrackerBucket get bucket => _bucket;
  String get search => _search;

  List<Tracker> get visibleTrackers {
    Iterable<Tracker> list = _all.where((t) => bucketForStatus(t.status) == _bucket);
    final query = _search.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list.where((t) => t.searchText.contains(query));
    }
    return list.toList();
  }

  int countFor(TrackerBucket bucket) =>
      _all.where((t) => bucketForStatus(t.status) == bucket).length;

  void setBucket(TrackerBucket value) {
    _bucket = value;
    notifyListeners();
  }

  void setSearch(String value) {
    _search = value;
    notifyListeners();
  }

  /// Start listening: initial fetch + socket room join + polling.
  /// Call from the dashboard screen's initState with the logged-in user.
  void start(User user) {
    _joinedAs = user;
    refresh();

    SocketService.instance.joinDashboard(user.userId, user.role);
    _socketUnsubs.add(
        SocketService.instance.on('dashboard_update', (_) => _debouncedRefresh()));
    _socketUnsubs.add(
        SocketService.instance.on('tracker_update', (_) => _debouncedRefresh()));
    _socketUnsubs.add(SocketService.instance
        .on('user_notification', (_) => _debouncedRefresh()));

    _pollTimer = Timer.periodic(pollInterval, (_) => refresh(silent: true));
  }

  void stop() {
    _pollTimer?.cancel();
    _socketDebounce?.cancel();
    for (final unsub in _socketUnsubs) {
      unsub();
    }
    _socketUnsubs.clear();
    if (_joinedAs != null) {
      SocketService.instance.leaveDashboard(_joinedAs!.userId, _joinedAs!.role);
      _joinedAs = null;
    }
  }

  Future<void> refresh({bool silent = false}) async {
    if (!silent) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    try {
      _all = await _api.allFe();
      _error = null;
    } catch (e) {
      // Keep stale data on silent poll failures; surface error on manual load.
      if (!silent) _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Socket bursts (multiple events per action) → single refetch.
  void _debouncedRefresh() {
    _socketDebounce?.cancel();
    _socketDebounce =
        Timer(const Duration(seconds: 2), () => refresh(silent: true));
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
