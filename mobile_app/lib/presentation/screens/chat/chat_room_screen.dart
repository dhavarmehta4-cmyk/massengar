import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/security/biometric_lock_service.dart';
import '../../../domain/entities/chat_entities.dart';
import '../../../domain/usecases/calls/webrtc_service.dart';
import '../../blocs/calls/call_bloc.dart';
import '../../blocs/chat/chat_bloc.dart';
import '../calls/call_screen.dart';

class ChatRoomScreen extends StatefulWidget {
  final Conversation conversation;
  const ChatRoomScreen({super.key, required this.conversation});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _scrollCtrl   = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.conversation.isLocked) {
      ScreenSecurityService.enableSecureMode();
    }
  }

  @override
  void dispose() {
    if (widget.conversation.isLocked) {
      ScreenSecurityService.disableSecureMode();
    }
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    _msgCtrl.clear();
    try {
      context.read<ChatBloc>().add(SendMessage(text: text));
      // Scroll to bottom after a brief paint delay
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundImage: NetworkImage(widget.conversation.avatarUrl),
                ),
                if (widget.conversation.isOnline)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: AppTheme.secondary,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppTheme.background, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.conversation.name, style: const TextStyle(fontSize: 16)),
                  Text(
                    widget.conversation.isOnline ? 'Online' : 'Offline',
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.conversation.isOnline ? AppTheme.secondary : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () {
              context.read<CallBloc>().add(StartCall(
                targetUserId: widget.conversation.participantId,
                targetUserName: widget.conversation.name,
                callType: CallType.audio,
              ));
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CallScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () {
              context.read<CallBloc>().add(StartCall(
                targetUserId: widget.conversation.participantId,
                targetUserName: widget.conversation.name,
                callType: CallType.video,
              ));
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CallScreen()),
              );
            },
          ),
        ],
      ),
      body: BlocConsumer<ChatBloc, ChatState>(
        // Only rebuild message list when we're in an active room state.
        buildWhen: (prev, curr) =>
            curr is ChatRoomActive || curr is ChatLoading || curr is ChatError,
        listenWhen: (prev, curr) => curr is ChatError,
        listener: (context, state) {
          if (state is ChatError) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                action: SnackBarAction(
                  label: 'Dismiss',
                  onPressed: () => context.read<ChatBloc>().add(ClearChatError()),
                ),
              ),
            );
          }
        },
        builder: (context, state) {
          if (state is ChatLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state is ChatError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: AppTheme.textMuted),
                  const SizedBox(height: 12),
                  Text(state.message, style: const TextStyle(color: AppTheme.textMuted)),
                ],
              ),
            );
          }

          final messages = state is ChatRoomActive ? state.messages : <ChatMessage>[];
          final isSending = state is ChatRoomActive ? state.isSending : false;

          // Auto-scroll on new messages
          if (messages.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollCtrl.hasClients) {
                _scrollCtrl.animateTo(
                  _scrollCtrl.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              }
            });
          }

          return Column(
            children: [
              // Message List
              Expanded(
                child: messages.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock_outline, size: 48, color: AppTheme.textMuted),
                            SizedBox(height: 12),
                            Text(
                              'Messages are end-to-end encrypted.\nSay hello! 👋',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final msg = messages[index];
                          return _buildMessageBubble(msg);
                        },
                      ),
              ),

              // Sending indicator
              if (isSending)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primary.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Sending…',
                        style: TextStyle(fontSize: 12, color: AppTheme.textMuted.withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                ),

              // Input Bar
              _buildInputArea(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isMe = msg.isMe;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isMe ? AppTheme.primary : AppTheme.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.only(
            topLeft:     const Radius.circular(20),
            topRight:    const Radius.circular(20),
            bottomLeft:  isMe ? const Radius.circular(20) : const Radius.circular(4),
            bottomRight: isMe ? const Radius.circular(4)  : const Radius.circular(20),
          ),
          border: isMe ? null : Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(msg.text, style: const TextStyle(fontSize: 15, color: Colors.white)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  msg.formattedTime,
                  style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.6)),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  _buildStatusIcon(msg.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return Icon(Icons.access_time, size: 12, color: Colors.white.withValues(alpha: 0.5));
      case MessageStatus.sent:
        return Icon(Icons.check, size: 12, color: Colors.white.withValues(alpha: 0.5));
      case MessageStatus.delivered:
        return Icon(Icons.done_all, size: 12, color: Colors.white.withValues(alpha: 0.5));
      case MessageStatus.read:
        return const Icon(Icons.done_all, size: 12, color: AppTheme.secondary);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.redAccent);
    }
  }

  Widget _buildInputArea() {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: AppTheme.surface.withValues(alpha: 0.6),
          child: SafeArea(
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file, color: AppTheme.textMuted),
                  onPressed: () {},
                ),
                Expanded(
                  child: TextField(
                    controller: _msgCtrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: 'Message…',
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      fillColor: Colors.black.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppTheme.primaryGradient,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
