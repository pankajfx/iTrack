import 'package:dio/dio.dart';

import 'package:itrack_fe/api/api_client.dart';
import 'package:itrack_fe/models/chat_message.dart';

/// Messages + unlock/interact flags from GET .../chat/messages.
/// chat_unlocked is computed server-side from the tracker status — always
/// trust this over any client-side calculation.
class ChatFeed {
  final List<ChatMessage> messages;
  final bool chatUnlocked;
  final bool canInteract;
  const ChatFeed({
    required this.messages,
    required this.chatUnlocked,
    required this.canInteract,
  });
}

class ChatApi {
  final ApiClient _client;
  ChatApi([ApiClient? client]) : _client = client ?? ApiClient.instance;

  /// `GET /api/trackers/<id>/chat/messages`.
  Future<ChatFeed> messages(String trackerId) async {
    final body = await _client
        .requestJson((dio) => dio.get('/api/trackers/$trackerId/chat/messages'));
    return ChatFeed(
      messages: (body['messages'] as List? ?? [])
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      chatUnlocked: body['chat_unlocked'] == true,
      canInteract: body['can_interact'] == true,
    );
  }

  /// `POST /api/trackers/<id>/chat/send` — text message.
  Future<ChatMessage> sendText(String trackerId, String text) async {
    final body = await _client.requestJson((dio) => dio.post(
          '/api/trackers/$trackerId/chat/send',
          data: {'message': text, 'type': 'text'},
        ));
    return ChatMessage.fromJson(body['message'] as Map<String, dynamic>);
  }

  /// Two-step image send, exactly like the web:
  /// 1) multipart POST .../chat/upload → server re-encodes (1024px JPEG q85)
  ///    and returns a base64 data-URL;
  /// 2) POST .../chat/send with that data-URL as file_url.
  Future<ChatMessage> sendImage(String trackerId, List<int> jpegBytes) async {
    final upload = await _client.requestJson((dio) => dio.post(
          '/api/trackers/$trackerId/chat/upload',
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(jpegBytes, filename: 'chat.jpg'),
            'type': 'image',
          }),
        ));

    final body = await _client.requestJson((dio) => dio.post(
          '/api/trackers/$trackerId/chat/send',
          data: {
            'message': '',
            'type': 'image',
            'file_url': upload['file_url'],
          },
        ));
    return ChatMessage.fromJson(body['message'] as Map<String, dynamic>);
  }

  /// `POST /api/trackers/<id>/chat/mark-read` — clear the other party's unread.
  Future<void> markRead(String trackerId) async {
    await _client.requestJson(
        (dio) => dio.post('/api/trackers/$trackerId/chat/mark-read'));
  }
}
