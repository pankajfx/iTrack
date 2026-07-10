import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:itrack_fe/api/chat_api.dart';
import 'package:itrack_fe/models/chat_message.dart';
import 'package:itrack_fe/services/socket_service.dart';
import 'package:itrack_fe/utils/constants.dart';

/// Chat state for one tracker. Unlock/interact flags come from the server
/// response, never computed locally. Live updates via the tracker room's
/// new_chat_message event (the detail screen already joined the room);
/// 30 s polling as the safety net, matching the web component.
class ChatState extends ChangeNotifier {
  final ChatApi _api = ChatApi();
  final String trackerId;

  List<ChatMessage> _messages = [];
  bool _chatUnlocked = false;
  bool _canInteract = false;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  Timer? _pollTimer;
  final List<void Function()> _socketUnsubs = [];

  ChatState(this.trackerId);

  List<ChatMessage> get messages => _messages;
  bool get chatUnlocked => _chatUnlocked;
  bool get canInteract => _canInteract;
  bool get loading => _loading;
  bool get sending => _sending;
  String? get error => _error;

  void start() {
    refresh();
    // The chat screen keeps its own room membership so chat works even if
    // opened directly (join is idempotent server-side).
    SocketService.instance.joinTracker(trackerId);
    _socketUnsubs.add(SocketService.instance.on('new_chat_message', (data) {
      if (data is Map && '${data['tracker_id']}' == trackerId) {
        refresh(silent: true, markRead: true);
      }
    }));
    _socketUnsubs.add(SocketService.instance.on('tracker_update', (data) {
      if (data is Map && '${data['tracker_id']}' == trackerId) {
        refresh(silent: true); // status change may lock/unlock chat
      }
    }));
    _pollTimer =
        Timer.periodic(pollInterval, (_) => refresh(silent: true));
  }

  void stop() {
    _pollTimer?.cancel();
    for (final unsub in _socketUnsubs) {
      unsub();
    }
    _socketUnsubs.clear();
  }

  Future<void> refresh({bool silent = false, bool markRead = false}) async {
    if (!silent) {
      _loading = true;
      notifyListeners();
    }
    try {
      final feed = await _api.messages(trackerId);
      _messages = feed.messages;
      _chatUnlocked = feed.chatUnlocked;
      _canInteract = feed.canInteract;
      _error = null;
      if (markRead || !silent) {
        // Fire-and-forget; failing to mark read is not a user-facing error.
        _api.markRead(trackerId).catchError((_) {});
      }
    } catch (e) {
      if (!silent) _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<String?> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return _send(() => _api.sendText(trackerId, trimmed));
  }

  Future<String?> sendImage(Uint8List jpegBytes) =>
      _send(() => _api.sendImage(trackerId, jpegBytes));

  /// Returns an error message for the UI, or null on success.
  Future<String?> _send(Future<ChatMessage> Function() action) async {
    _sending = true;
    notifyListeners();
    try {
      final message = await action();
      _messages = [..._messages, message];
      return null;
    } catch (e) {
      return '$e';
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
