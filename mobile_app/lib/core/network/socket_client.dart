import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:async';

class SocketClient {
  static final SocketClient _instance = SocketClient._internal();
  factory SocketClient() => _instance;
  SocketClient._internal();

  IO.Socket? _socket;
  final StreamController<Map<String, dynamic>> _messageStreamController = StreamController.broadcast();

  Stream<Map<String, dynamic>> get messageStream => _messageStreamController.stream;

  void connect(String serverUrl, String token) {
    _socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'auth': {'token': token}
    });

    _socket?.connect();

    _socket?.onConnect((_) {
      print('Connected to Socket.IO server');
    });

    _socket?.on('message:new', (data) {
      _messageStreamController.add(Map<String, dynamic>.from(data));
    });

    _socket?.onDisconnect((_) => print('Disconnected from Socket.IO server'));
  }

  void sendMessage(Map<String, dynamic> payload) {
    _socket?.emit('message:send', payload);
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }
}
