import 'package:socket_io_client/socket_io_client.dart' as io;

/// Socket.IO connection to the Flask-SocketIO server (hybrid realtime mode,
/// mirroring the web app: sockets for freshness, 30 s polling as safety net).
///
/// Rooms (server handlers in app.py):
/// - join_dashboard {user_id, role} → dashboard_{role} + user_{user_id}
/// - join_tracker {tracker_id}      → tracker_{tracker_id}
///
/// Server → client events: tracker_update, new_chat_message,
/// dashboard_update, user_notification.
class SocketService {
  SocketService._();
  static final SocketService instance = SocketService._();

  io.Socket? _socket;

  final Map<String, List<void Function(dynamic)>> _listeners = {};

  bool get isConnected => _socket?.connected ?? false;

  /// Connect (or reconnect) to [baseUrl]. Safe to call repeatedly.
  void connect(String baseUrl) {
    if (_socket != null && _socket!.io.uri == baseUrl) {
      if (!_socket!.connected) _socket!.connect();
      return;
    }
    disconnect();

    _socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .enableReconnection()
          .build(),
    );

    for (final event in const [
      'tracker_update',
      'new_chat_message',
      'dashboard_update',
      'user_notification',
    ]) {
      _socket!.on(event, (data) {
        for (final handler in List.of(_listeners[event] ?? const [])) {
          handler(data);
        }
      });
    }
  }

  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }

  /// Register a handler; returns a function that unregisters it
  /// (call it from the screen's dispose()).
  void Function() on(String event, void Function(dynamic data) handler) {
    _listeners.putIfAbsent(event, () => []).add(handler);
    return () => _listeners[event]?.remove(handler);
  }

  void joinDashboard(String userId, String role) =>
      _socket?.emit('join_dashboard', {'user_id': userId, 'role': role});

  void leaveDashboard(String userId, String role) =>
      _socket?.emit('leave_dashboard', {'user_id': userId, 'role': role});

  void joinTracker(String trackerId) =>
      _socket?.emit('join_tracker', {'tracker_id': trackerId});

  void leaveTracker(String trackerId) =>
      _socket?.emit('leave_tracker', {'tracker_id': trackerId});
}
