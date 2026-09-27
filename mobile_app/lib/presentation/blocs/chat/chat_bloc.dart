// ================================================================
// Massengar - ChatBloc
// Manages real-time message state and wires the WebSocket
// SocketClient stream into the BLoC event pipeline.
// ================================================================

import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../../core/network/socket_client.dart';
import '../../../domain/entities/chat_entities.dart';

part 'chat_event.dart';
part 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final SocketClient _socketClient;
  StreamSubscription<Map<String, dynamic>>? _socketSubscription;

  /// The currently active conversation id (set by [EnterConversation]).
  String? _activeConversationId;

  /// Local message list for the active chat room.
  final List<ChatMessage> _messages = [];

  /// Flat conversation list (fed by initial load + WebSocket updates).
  final List<Conversation> _conversations = [];

  /// Simulated current user id – replace with your auth session value.
  static const String _currentUserId = 'me';

  static const _uuid = Uuid();

  ChatBloc({SocketClient? socketClient})
      : _socketClient = socketClient ?? SocketClient(),
        super(ChatInitial()) {
    on<LoadConversations>(_onLoadConversations);
    on<ConversationUpdated>(_onConversationUpdated);
    on<EnterConversation>(_onEnterConversation);
    on<LeaveConversation>(_onLeaveConversation);
    on<SendMessage>(_onSendMessage);
    on<MessageReceived>(_onMessageReceived);
    on<MessageAcknowledged>(_onMessageAcknowledged);
    on<ClearChatError>(_onClearChatError);
    on<_SocketError>(_onSocketError);

    // Subscribe to the socket stream once; route events by type.
    _startSocketSubscription();
  }

  // -- Socket Subscription ------------------------------------------

  void _startSocketSubscription() {
    try {
      _socketSubscription = _socketClient.messageStream.listen(
        (payload) {
          try {
            final type = payload['type']?.toString() ?? '';
            if (type == 'message:new') {
              add(MessageReceived(payload));
            } else if (type == 'message:ack') {
              add(MessageAcknowledged(
                messageId: payload['messageId']?.toString() ?? '',
                status:    _parseStatus(payload['status']?.toString()),
              ));
            } else if (type == 'conversation:update') {
              add(ConversationUpdated(payload));
            }
          } catch (e) {
            // Malformed payload – do not crash the entire subscription.
            addError(Exception('Malformed socket payload: $e'));
          }
        },
        onError: (Object error) {
          addError(Exception('Socket stream error: $error'));
          // Route through the event bus so emit() is always called
          // inside a registered handler – never directly from a callback.
          add(_SocketError('Connection error. Please retry.'));
        },
      );
    } catch (e) {
      // SocketClient not yet connected; subscription will be a no-op.
    }
  }

  static MessageStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'sent':      return MessageStatus.sent;
      case 'delivered': return MessageStatus.delivered;
      case 'read':      return MessageStatus.read;
      case 'failed':    return MessageStatus.failed;
      default:          return MessageStatus.sent;
    }
  }

  // -- Event Handlers -----------------------------------------------

  Future<void> _onLoadConversations(
    LoadConversations event,
    Emitter<ChatState> emit,
  ) async {
    emit(ChatLoading());
    try {
      // In production: fetch from your REST/GraphQL API or local SQLCipher.
      // Here we seed with empty list; the UI will replace mocks via this state.
      emit(ConversationsLoaded(List.unmodifiable(_conversations)));
    } catch (e) {
      emit(ChatError('Failed to load conversations: $e'));
    }
  }

  void _onConversationUpdated(
    ConversationUpdated event,
    Emitter<ChatState> emit,
  ) {
    try {
      final conv = Conversation.fromJson(event.payload);
      final idx  = _conversations.indexWhere((c) => c.id == conv.id);
      if (idx >= 0) {
        _conversations[idx] = conv;
      } else {
        _conversations.insert(0, conv);
      }
      emit(ConversationsLoaded(List.unmodifiable(_conversations)));
    } catch (e) {
      addError(Exception('ConversationUpdated handler error: $e'));
    }
  }

  Future<void> _onEnterConversation(
    EnterConversation event,
    Emitter<ChatState> emit,
  ) async {
    emit(ChatLoading());
    try {
      _activeConversationId = event.conversationId;
      _messages.clear();

      // In production: load history from SQLCipher, then paginate via API.
      // For now emit an empty room so the UI renders the live incoming stream.
      emit(ChatRoomActive(
        conversationId: event.conversationId,
        messages:       List.unmodifiable(_messages),
      ));

      // Mark conversation as read
      _markConversationRead(event.conversationId);
    } catch (e) {
      emit(ChatError('Failed to enter conversation: $e'));
    }
  }

  void _onLeaveConversation(
    LeaveConversation event,
    Emitter<ChatState> emit,
  ) {
    _activeConversationId = null;
    _messages.clear();
    emit(ConversationsLoaded(List.unmodifiable(_conversations)));
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (_activeConversationId == null) return;

    final optimisticMsg = ChatMessage(
      id:             _uuid.v4(),
      conversationId: _activeConversationId!,
      senderId:       _currentUserId,
      text:           event.text,
      timestamp:      DateTime.now(),
      isMe:           true,
      status:         MessageStatus.sending,
      mediaUrl:       event.mediaUrl,
      mediaType:      event.mediaType,
    );

    // Optimistic update
    _messages.add(optimisticMsg);
    if (state is ChatRoomActive) {
      emit((state as ChatRoomActive).copyWith(
        messages:  List.unmodifiable(_messages),
        isSending: true,
      ));
    }

    try {
      // NOTE: In production, encrypt via DoubleRatchetEngine before emitting.
      _socketClient.sendMessage({
        'type':           'message:send',
        'conversationId': _activeConversationId,
        'tempId':         optimisticMsg.id,
        'text':           event.text,
        if (event.mediaUrl  != null) 'mediaUrl':  event.mediaUrl,
        if (event.mediaType != null) 'mediaType': event.mediaType,
      });

      if (state is ChatRoomActive) {
        emit((state as ChatRoomActive).copyWith(isSending: false));
      }
    } catch (e) {
      // Mark the optimistic message as failed
      final idx = _messages.indexWhere((m) => m.id == optimisticMsg.id);
      if (idx >= 0) {
        _messages[idx] = _messages[idx].copyWith(status: MessageStatus.failed);
      }
      if (state is ChatRoomActive) {
        emit((state as ChatRoomActive).copyWith(
          messages:  List.unmodifiable(_messages),
          isSending: false,
        ));
      }
      addError(Exception('Send message failed: $e'));
    }
  }

  void _onMessageReceived(
    MessageReceived event,
    Emitter<ChatState> emit,
  ) {
    try {
      final convId = event.payload['conversationId']?.toString() ?? '';

      // Update conversation list last-message preview
      final convIdx = _conversations.indexWhere((c) => c.id == convId);
      if (convIdx >= 0) {
        final isActive = convId == _activeConversationId;
        _conversations[convIdx] = _conversations[convIdx].copyWith(
          lastMessage:     event.payload['text']?.toString() ?? '',
          lastMessageTime: DateTime.now(),
          unreadCount: isActive
              ? 0
              : (_conversations[convIdx].unreadCount + 1),
        );
      }

      // If this message belongs to the currently open chat room, add it.
      if (convId == _activeConversationId) {
        final msg = ChatMessage.fromSocketPayload(event.payload, _currentUserId);

        // Deduplicate (server echo of our own send)
        final alreadyExists = _messages.any((m) => m.id == msg.id);
        if (!alreadyExists) {
          _messages.add(msg);
          if (state is ChatRoomActive) {
            emit((state as ChatRoomActive).copyWith(
              messages: List.unmodifiable(_messages),
            ));
          }
        }
      } else {
        // Notify the conversation list of the updated preview
        emit(ConversationsLoaded(List.unmodifiable(_conversations)));
      }
    } catch (e) {
      addError(Exception('MessageReceived handler error: $e'));
    }
  }

  void _onMessageAcknowledged(
    MessageAcknowledged event,
    Emitter<ChatState> emit,
  ) {
    try {
      final idx = _messages.indexWhere((m) => m.id == event.messageId);
      if (idx >= 0) {
        _messages[idx] = _messages[idx].copyWith(status: event.status);
        if (state is ChatRoomActive) {
          emit((state as ChatRoomActive).copyWith(
            messages: List.unmodifiable(_messages),
          ));
        }
      }
    } catch (e) {
      addError(Exception('MessageAcknowledged handler error: $e'));
    }
  }

  void _onClearChatError(ClearChatError event, Emitter<ChatState> emit) {
    emit(ConversationsLoaded(List.unmodifiable(_conversations)));
  }

  void _onSocketError(_SocketError event, Emitter<ChatState> emit) {
    emit(ChatError(event.message));
  }

  // -- Helpers -------------------------------------------------------

  void _markConversationRead(String conversationId) {
    try {
      final idx = _conversations.indexWhere((c) => c.id == conversationId);
      if (idx >= 0 && _conversations[idx].unreadCount > 0) {
        _conversations[idx] = _conversations[idx].copyWith(unreadCount: 0);
      }
    } catch (_) {}
  }

  // -- Dispose -------------------------------------------------------

  @override
  Future<void> close() async {
    await _socketSubscription?.cancel();
    return super.close();
  }
}
