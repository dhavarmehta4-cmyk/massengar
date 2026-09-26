// ================================================================
// Massengar - WebRTC Voice & Video Call Service (Flutter)
// Phase 5: P2P Encrypted Audio/Video via WebRTC + Coturn STUN/TURN
// ================================================================

import "dart:async";
import "dart:convert";
import "package:flutter_webrtc/flutter_webrtc.dart";
import "package:socket_io_client/socket_io_client.dart" as IO;
import "package:uuid/uuid.dart";

enum CallState { idle, outgoing, incoming, connecting, connected, ended }
enum CallType { audio, video }

class CallEvent {
  final String type;
  final Map<String, dynamic> data;
  const CallEvent({required this.type, required this.data});
}

class WebRtcService {
  static final WebRtcService _instance = WebRtcService._internal();
  factory WebRtcService() => _instance;
  WebRtcService._internal();

  IO.Socket? _socket;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final _uuid = const Uuid();
  String? _currentCallId;
  String? _currentPeerId;
  CallState _callState = CallState.idle;
  CallType _callType = CallType.audio;

  // Stream controllers for UI
  final _callStateController = StreamController<CallState>.broadcast();
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();
  final _callEventController = StreamController<CallEvent>.broadcast();

  Stream<CallState> get callStateStream => _callStateController.stream;
  Stream<MediaStream?> get remoteStreamStream => _remoteStreamController.stream;
  Stream<CallEvent> get callEventStream => _callEventController.stream;

  CallState get callState => _callState;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  // -- ICE Server Config (from backend TURN endpoint) ----------------

  static List<Map<String, dynamic>> _iceServers = [
    {"urls": "stun:stun.l.google.com:19302"},
    {"urls": "stun:stun1.l.google.com:19302"},
  ];

  static void updateIceServers(List<Map<String, dynamic>> servers) {
    _iceServers = servers;
  }

  // -- Initialize with Socket ----------------------------------------

  void initializeSocket(IO.Socket socket) {
    _socket = socket;
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    _socket?.on("webrtc:offer", _handleIncomingOffer);
    _socket?.on("webrtc:answer", _handleAnswer);
    _socket?.on("webrtc:ice-candidate", _handleIceCandidate);
    _socket?.on("webrtc:call-end", _handleCallEnd);
  }

  // -- Start Outgoing Call -------------------------------------------

  Future<String> startCall({
    required String targetUserId,
    required CallType callType,
  }) async {
    if (_callState != CallState.idle) throw Exception("Already in a call");

    _currentCallId = _uuid.v4();
    _currentPeerId = targetUserId;
    _callType = callType;
    _updateCallState(CallState.outgoing);

    // Get local media
    _localStream = await _getUserMedia(callType);

    // Create peer connection
    await _createPeerConnection();

    // Add local tracks
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    // Create offer
    final offer = await _peerConnection!.createOffer(
      callType == CallType.audio
        ? {"offerToReceiveAudio": true, "offerToReceiveVideo": false}
        : {"offerToReceiveAudio": true, "offerToReceiveVideo": true},
    );
    await _peerConnection!.setLocalDescription(offer);

    // Send offer via signaling
    _socket?.emit("webrtc:offer", {
      "callId": _currentCallId,
      "targetUserId": targetUserId,
      "sdp": offer.toMap(),
      "callType": callType == CallType.audio ? "audio" : "video",
    });

    _callEventController.add(CallEvent(type: "outgoing_call_started", data: {
      "callId": _currentCallId,
      "targetUserId": targetUserId,
      "callType": callType.name,
    }));

    return _currentCallId!;
  }

  // -- Accept Incoming Call ------------------------------------------

  Future<void> acceptCall({
    required String callId,
    required String callerUserId,
    required RTCSessionDescription offer,
    required CallType callType,
  }) async {
    _currentCallId = callId;
    _currentPeerId = callerUserId;
    _callType = callType;
    _updateCallState(CallState.connecting);

    _localStream = await _getUserMedia(callType);
    await _createPeerConnection();

    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    await _peerConnection!.setRemoteDescription(offer);
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    _socket?.emit("webrtc:answer", {
      "callId": callId,
      "targetUserId": callerUserId,
      "sdp": answer.toMap(),
    });
  }

  // -- Reject / End Call ---------------------------------------------

  Future<void> rejectCall({required String callId, required String callerUserId}) async {
    _socket?.emit("webrtc:call-end", {
      "callId": callId,
      "targetUserId": callerUserId,
      "reason": "rejected",
    });
    await _cleanup();
  }

  Future<void> endCall() async {
    if (_currentCallId == null || _currentPeerId == null) return;
    _socket?.emit("webrtc:call-end", {
      "callId": _currentCallId,
      "targetUserId": _currentPeerId,
      "reason": "ended",
    });
    await _cleanup();
  }

  // -- Audio/Video Controls ------------------------------------------

  Future<void> toggleMute(bool muted) async {
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !muted;
    });
  }

  Future<void> toggleCamera(bool cameraOff) async {
    _localStream?.getVideoTracks().forEach((track) {
      track.enabled = !cameraOff;
    });
  }

  Future<void> switchCamera() async {
    if (_localStream == null) return;
    final videoTrack = _localStream!.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
  }

  Future<void> setSpeakerphone(bool speakerOn) async {
    await Helper.setSpeakerphoneOn(speakerOn);
  }

  // -- Signal Handlers -----------------------------------------------

  Future<void> _handleIncomingOffer(dynamic data) async {
    final callId = data["callId"] as String;
    final fromUserId = data["fromUserId"] as String;
    final sdp = data["sdp"] as Map<String, dynamic>;
    final callTypeStr = data["callType"] as String;
    final callType = callTypeStr == "video" ? CallType.video : CallType.audio;

    final offer = RTCSessionDescription(sdp["sdp"] as String?, sdp["type"] as String?);
    _updateCallState(CallState.incoming);

    _callEventController.add(CallEvent(type: "incoming_call", data: {
      "callId": callId,
      "fromUserId": fromUserId,
      "callType": callTypeStr,
      "offer": offer,
    }));
  }

  Future<void> _handleAnswer(dynamic data) async {
    final sdp = data["sdp"] as Map<String, dynamic>;
    final answer = RTCSessionDescription(sdp["sdp"] as String?, sdp["type"] as String?);
    await _peerConnection?.setRemoteDescription(answer);
    _updateCallState(CallState.connected);
  }

  Future<void> _handleIceCandidate(dynamic data) async {
    final candidate = data["candidate"] as Map<String, dynamic>;
    await _peerConnection?.addCandidate(RTCIceCandidate(
      candidate["candidate"] as String?,
      candidate["sdpMid"] as String?,
      candidate["sdpMLineIndex"] as int?,
    ));
  }

  Future<void> _handleCallEnd(dynamic data) async {
    final reason = data["reason"] as String;
    _callEventController.add(CallEvent(type: "call_ended", data: {"reason": reason}));
    await _cleanup();
  }

  // -- Peer Connection -----------------------------------------------

  Future<void> _createPeerConnection() async {
    final config = {
      "iceServers": _iceServers,
      "sdpSemantics": "unified-plan",
    };

    _peerConnection = await createPeerConnection(config);

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null && _currentPeerId != null) {
        _socket?.emit("webrtc:ice-candidate", {
          "callId": _currentCallId,
          "targetUserId": _currentPeerId,
          "candidate": candidate.toMap(),
        });
      }
    };

    _peerConnection!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _updateCallState(CallState.connected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _cleanup();
      }
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteStreamController.add(_remoteStream);
      }
    };

    _peerConnection!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _updateCallState(CallState.connected);
      }
    };
  }

  // -- Media ---------------------------------------------------------

  Future<MediaStream> _getUserMedia(CallType callType) async {
    final constraints = {
      "audio": true,
      "video": callType == CallType.video
        ? {
            "facingMode": "user",
            "width": {"ideal": 1280},
            "height": {"ideal": 720},
            "frameRate": {"ideal": 30},
          }
        : false,
    };
    return navigator.mediaDevices.getUserMedia(constraints);
  }

  void _updateCallState(CallState state) {
    _callState = state;
    _callStateController.add(state);
  }

  Future<void> _cleanup() async {
    _updateCallState(CallState.ended);

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;

    _remoteStream?.dispose();
    _remoteStream = null;
    _remoteStreamController.add(null);

    await _peerConnection?.close();
    _peerConnection = null;

    _currentCallId = null;
    _currentPeerId = null;

    // Reset to idle after brief delay
    await Future.delayed(const Duration(milliseconds: 500));
    _updateCallState(CallState.idle);
  }

  Future<void> dispose() async {
    await _cleanup();
    await _callStateController.close();
    await _remoteStreamController.close();
    await _callEventController.close();
  }
}
