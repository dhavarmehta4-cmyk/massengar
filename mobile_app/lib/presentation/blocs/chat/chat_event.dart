// ================================================================
// Massengar - ChatEvent
// Sealed events consumed by ChatBloc
// ================================================================

part of 'chat_bloc.dart';

abstract class ChatEvent {}

// -- Conversation List Events -------------------------------------

/// Triggered once on launch to load the conversation list.
class LoadConversations extends ChatEvent {}

/// A remote "conversation:update" WebSocket event arrived.
class ConversationUpdated extends ChatEvent {
  final Map<String, dynamic> payload;
  ConversationUpdated(this.payload);
}

// -- Message Events -----------------------------------------------

/// Enter a chat room – begins listening for incoming messages for [conversationId].
class EnterConversation extends ChatEvent {
  final String conversationId;
  EnterConversation(this.conversationId);
}

/// Leave the current chat room.
class LeaveConversation extends ChatEvent {}

/// User tapped "Send" – encrypt and emit via WebSocket.
class SendMessage extends ChatEvent {
  final String text;
  final String? mediaUrl;
  final String? mediaType;
  SendMessage({required this.text, this.mediaUrl, this.mediaType});
}

/// A new message arrived from the WebSocket stream.
class MessageReceived extends ChatEvent {
  final Map<String, dynamic> payload;
  MessageReceived(this.payload);
}

/// Message delivery acknowledgement received.
class MessageAcknowledged extends ChatEvent {
  final String messageId;
  final MessageStatus status;
  MessageAcknowledged({required this.messageId, required this.status});
}

/// Clear the error state.
class ClearChatError extends ChatEvent {}

/// Internal – emitted by the socket onError callback so emit()
/// is always invoked from within a registered handler.
class _SocketError extends ChatEvent {
  final String message;
  _SocketError(this.message);
}
