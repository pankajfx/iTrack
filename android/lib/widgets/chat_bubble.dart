import 'package:flutter/material.dart';

import 'package:itrack_fe/models/chat_message.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/utils/time_utils.dart';
import 'package:itrack_fe/widgets/base64_image.dart';

/// One chat message. Own messages (FE) align right in the theme color;
/// the other party's align left in grey — matching the web chat component.
class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  final void Function(String dataUrl)? onTapImage;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onTapImage,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isMine ? AppTheme.primary : Colors.white;
    final fg = isMine ? Colors.white : Colors.black87;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMine ? 14 : 2),
            bottomRight: Radius.circular(isMine ? 2 : 14),
          ),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 3,
                offset: const Offset(0, 1)),
          ],
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMine)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  message.senderName,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600),
                ),
              ),
            if (message.type == 'image' && (message.fileUrl ?? '').isNotEmpty)
              GestureDetector(
                onTap: () => onTapImage?.call(message.fileUrl!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Base64Image(message.fileUrl!,
                      width: 180, height: 180, fit: BoxFit.cover),
                ),
              )
            else
              Text(message.message, style: TextStyle(color: fg, fontSize: 14)),
            const SizedBox(height: 3),
            Text(
              formatIstShort(message.timestamp),
              style: TextStyle(
                fontSize: 10,
                color: isMine ? Colors.white70 : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
