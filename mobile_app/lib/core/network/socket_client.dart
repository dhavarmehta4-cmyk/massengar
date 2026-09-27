import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io_client;
import 'dart:async';

class SocketClient {
  static final SocketClient _instance = SocketClient._internal();
  factory SocketClient() => _instance;
  SocketClient._internal();

  io_client.Socket? _socket;
  io_client.Socket? get socket => _socket;

  final StreamController<Map<String, dynamic>> _messageStreamController = StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _webrtcOfferController = StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _webrtcAnswerController = StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _webrtcIceCandidateController = StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _webrtcCallEndController = StreamController.broadcast();

  Stream<Map<String, dynamic>> get messageStream => _messageStreamController.stream;
  Stream<Map<String, dynamic>> get webrtcOfferStream => _webrtcOfferController.stream;
  Stream<Map<String, dynamic>> get webrtcAnswerStream => _webrtcAnswerController.stream;
  Stream<Map<String, dynamic>> get webrtcIceCandidateStream => _webrtcIceCandidateController.stream;
  Stream<Map<String, dynamic>> get webrtcCallEndStream => _webrtcCallEndController.stream;

  void connect(String serverUrl, String token) {
    _socket = io_client.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'auth': {'token': token}
    });

    _socket?.connect();

    _socket?.onConnect((_) {
      debugPrint('Connected to Socket.IO server');
    });

    _socket?.on('message:new', (data) {
      if (data != null) {
        _messageStreamController.add(Map<String, dynamic>.from(data as Map));
      }
    });

    // WebRTC Signaling
    _socket?.on('webrtc:offer', (data) {
      if (data != null) {
        _webrtcOfferController.add(Map<String, dynamic>.from(data as Map));
      }
    });

    _socket?.on('webrtc:answer', (data) {
      if (data != null) {
        _webrtcAnswerController.add(Map<String, dynamic>.from(data as Map));
      }
    });

    _socket?.on('webrtc:ice-candidate', (data) {
      if (data != null) {
        _webrtcIceCandidateController.add(Map<String, dynamic>.from(data as Map));
      }
    });

    _socket?.on('webrtc:call-end', (data) {
      if (data != null) {
        _webrtcCallEndController.add(Map<String, dynamic>.from(data as Map));
      }
    });

    _socket?.onDisconnect((_) => debugPrint('Disconnected from Socket.IO server'));
  }

  void sendMessage(Map<String, dynamic> payload) {
    _socket?.emit('message:send', payload);
  }

  void emitSignaling(String event, Map<String, dynamic> payload) {
    _socket?.emit(event, payload);
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }
}
