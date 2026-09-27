// ================================================================
// Massengar - ChatMessage domain entity
// ================================================================

import 'package:equatable/equatable.dart';

enum MessageStatus { sending, sent, delivered, read, failed }

class ChatMessage extends Equatable {
  final String id;
  final String conversationId;
  final String senderId;
  final String text;
  final DateTime timestamp;
  final bool isMe;
  final MessageStatus status;
  final String? mediaUrl;
  final String? mediaType; // 'image' | 'video' | 'audio' | 'file'

  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.isMe,
    this.status = MessageStatus.sent,
    this.mediaUrl,
    this.mediaType,
  });

  /// Human-readable formatted time (e.g. "12:30 PM")
  String get formattedTime {
    final h = timestamp.hour;
    final m = timestamp.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$hour12:$m $period';
  }

  factory ChatMessage.fromSocketPayload(Map<String, dynamic> data, String currentUserId) {
    return ChatMessage(
      id:             data['id']?.toString()             ?? DateTime.now().millisecondsSinceEpoch.toString(),
      conversationId: data['conversationId']?.toString() ?? '',
      senderId:       data['senderId']?.toString()       ?? '',
      text:           data['text']?.toString()           ?? '',
      timestamp:      data['timestamp'] != null
          ? DateTime.tryParse(data['timestamp'].toString()) ?? DateTime.now()
          : DateTime.now(),
      isMe:           data['senderId']?.toString() == currentUserId,
      status:         MessageStatus.delivered,
      mediaUrl:       data['mediaUrl']?.toString(),
      mediaType:      data['mediaType']?.toString(),
    );
  }

  ChatMessage copyWith({MessageStatus? status}) {
    return ChatMessage(
      id:             id,
      conversationId: conversationId,
      senderId:       senderId,
      text:           text,
      timestamp:      timestamp,
      isMe:           isMe,
      status:         status ?? this.status,
      mediaUrl:       mediaUrl,
      mediaType:      mediaType,
    );
  }

  @override
  List<Object?> get props => [id, conversationId, senderId, text, timestamp, isMe, status];
}

// -- Conversation (chat list entry) --------------------------------

class Conversation extends Equatable {
  final String id;
  final String name;
  final String avatarUrl;
  final String lastMessage;
  final DateTime lastMessageTime;
  final int unreadCount;
  final bool isLocked;
  final bool isOnline;
  final String? _participantId;

  String get participantId => _participantId ?? id;

  const Conversation({
    required this.id,
    required this.name,
    required this.avatarUrl,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.isLocked = false,
    this.isOnline = false,
    String? participantId,
  }) : _participantId = participantId;

  String get formattedTime {
    final now  = DateTime.now();
    final diff = now.difference(lastMessageTime);
    if (diff.inDays == 0) {
      final h      = lastMessageTime.hour;
      final m      = lastMessageTime.minute.toString().padLeft(2, '0');
      final period = h >= 12 ? 'PM' : 'AM';
      final h12    = h == 0 ? 12 : (h > 12 ? h - 12 : h);
      return '$h12:$m $period';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else {
      return '${diff.inDays} days ago';
    }
  }

  Conversation copyWith({
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    bool? isOnline,
  }) {
    return Conversation(
      id:              id,
      name:            name,
      avatarUrl:       avatarUrl,
      lastMessage:     lastMessage     ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount:     unreadCount     ?? this.unreadCount,
      isLocked:        isLocked,
      isOnline:        isOnline        ?? this.isOnline,
    );
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id:              json['id']?.toString()          ?? '',
      name:            json['name']?.toString()        ?? 'Unknown',
      avatarUrl:       json['avatarUrl']?.toString()   ?? 'https://i.pravatar.cc/150?u=${json['id']}',
      lastMessage:     json['lastMessage']?.toString() ?? '',
      lastMessageTime: json['lastMessageTime'] != null
          ? DateTime.tryParse(json['lastMessageTime'].toString()) ?? DateTime.now()
          : DateTime.now(),
      unreadCount: (json['unreadCount'] as int?) ?? 0,
      isLocked:    (json['isLocked']    as bool?) ?? false,
      isOnline:    (json['isOnline']    as bool?) ?? false,
    );
  }

  @override
  List<Object?> get props => [id, name, lastMessage, lastMessageTime, unreadCount, isOnline];
}
