import 'package:itrack_fe/utils/time_utils.dart';

/// Chat message doc (chat_messages collection), as serialized by the server.
class ChatMessage {
  final String id;
  final String trackerId;
  final String senderId;
  final String senderRole;
  final String senderName;
  final String message;
  final String type; // 'text' | 'image' | 'audio'
  final String? fileUrl; // base64 data-URL for image/audio
  final DateTime? timestamp;
  final bool read;

  const ChatMessage({
    required this.id,
    required this.trackerId,
    required this.senderId,
    required this.senderRole,
    required this.senderName,
    required this.message,
    required this.type,
    this.fileUrl,
    this.timestamp,
    this.read = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['_id'] ?? '',
        trackerId: json['tracker_id'] ?? '',
        senderId: json['sender_id'] ?? '',
        senderRole: json['sender_role'] ?? '',
        senderName: json['sender_name'] ?? '',
        message: json['message'] ?? '',
        type: json['type'] ?? 'text',
        fileUrl: json['file_url'],
        timestamp: parseServerTime(json['timestamp']),
        read: json['read'] == true,
      );
}
