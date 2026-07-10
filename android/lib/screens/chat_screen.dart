import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/services/image_service.dart';
import 'package:itrack_fe/state/auth_state.dart';
import 'package:itrack_fe/state/chat_state.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/screens/image_viewer_screen.dart';
import 'package:itrack_fe/widgets/chat_bubble.dart';
import 'package:itrack_fe/widgets/empty_state.dart';

/// FE ↔ NOC chat. Unlock state comes from the server; when locked the
/// composer is hidden. Text + image only (voice deferred, per v1 scope).
class ChatScreen extends StatefulWidget {
  final String trackerId;
  const ChatScreen({super.key, required this.trackerId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatState _state;
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final ImageService _images = ImageService();
  String _myRole = '';

  @override
  void initState() {
    super.initState();
    _myRole = context.read<AuthState>().user?.role ?? '';
    _state = ChatState(widget.trackerId)..start();
    _state.addListener(_autoScroll);
  }

  @override
  void dispose() {
    _state.removeListener(_autoScroll);
    _controller.dispose();
    _scrollController.dispose();
    _state.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _sendText() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    final error = await _state.sendText(text);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _sendImage(bool fromCamera) async {
    if (fromCamera && !await _images.ensureCameraPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera permission required')));
      }
      return;
    }
    final bytes = fromCamera
        ? await _images.captureJpeg()
        : await _images.pickFromGallery();
    if (bytes == null) return;
    final error = await _state.sendImage(bytes);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _state,
      child: Scaffold(
        appBar: AppBar(title: const Text('Coordination Chat')),
        body: Consumer<ChatState>(
          builder: (context, state, _) {
            return Column(
              children: [
                Expanded(child: _buildMessages(state)),
                if (state.chatUnlocked && state.canInteract)
                  _buildComposer(state)
                else
                  _buildLockedBar(state),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMessages(ChatState state) {
    if (state.loading && state.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.messages.isEmpty) {
      return EmptyState(
        icon: state.chatUnlocked ? Icons.chat_bubble_outline : Icons.lock,
        title: state.chatUnlocked ? 'No messages yet' : 'Chat locked',
        subtitle: state.chatUnlocked
            ? 'Start the conversation with NOC Support.'
            : 'Chat opens once the installation reaches coordination.',
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.messages.length,
      itemBuilder: (context, i) {
        final message = state.messages[i];
        return ChatBubble(
          message: message,
          isMine: message.senderRole == _myRole,
          onTapImage: (dataUrl) =>
              ImageViewerScreen.open(context, dataUrl, title: 'Chat image'),
        );
      },
    );
  }

  Widget _buildComposer(ChatState state) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 4,
                offset: const Offset(0, -1)),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.photo_camera, color: AppTheme.primary),
              onPressed: state.sending ? null : () => _sendImage(true),
            ),
            IconButton(
              icon: const Icon(Icons.photo_library, color: AppTheme.primary),
              onPressed: state.sending ? null : () => _sendImage(false),
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Type a message…',
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _sendText(),
              ),
            ),
            state.sending
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    icon: const Icon(Icons.send, color: AppTheme.primary),
                    onPressed: _sendText,
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildLockedBar(ChatState state) {
    final message = !state.chatUnlocked
        ? 'Chat is locked until coordination begins'
        : 'You can view this chat but cannot send messages';
    return SafeArea(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        color: Colors.grey.shade100,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock, size: 16, color: Colors.grey.shade500),
            const SizedBox(width: 8),
            Flexible(
              child: Text(message,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
