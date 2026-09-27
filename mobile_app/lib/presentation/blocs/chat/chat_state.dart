// ================================================================
// Massengar - ChatState
// Immutable states emitted by ChatBloc
// ================================================================

part of 'chat_bloc.dart';

abstract class ChatState {}

// -- Initial / Loading --------------------------------------------

class ChatInitial extends ChatState {}

class ChatLoading extends ChatState {}

// -- Conversation List States -------------------------------------

class ConversationsLoaded extends ChatState {
  final List<Conversation> conversations;
  ConversationsLoaded(this.conversations);
}

// -- Active Chat Room States --------------------------------------

class ChatRoomActive extends ChatState {
  final String conversationId;
  final List<ChatMessage> messages;
  final bool isSending;

  ChatRoomActive({
    required this.conversationId,
    required this.messages,
    this.isSending = false,
  });

  ChatRoomActive copyWith({
    List<ChatMessage>? messages,
    bool? isSending,
  }) {
    return ChatRoomActive(
      conversationId: conversationId,
      messages:       messages   ?? this.messages,
      isSending:      isSending  ?? this.isSending,
    );
  }
}

// -- Error State --------------------------------------------------

class ChatError extends ChatState {
  final String message;
  ChatError(this.message);
}
