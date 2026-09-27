import "package:equatable/equatable.dart";
import "package:flutter_webrtc/flutter_webrtc.dart";
import "../../../domain/usecases/calls/webrtc_service.dart";

abstract class CallBlocState extends Equatable {
  const CallBlocState();

  @override
  List<Object?> get props => [];
}

/// Initial idle state - no calls in progress.
class CallInitial extends CallBlocState {
  const CallInitial();
}

/// Incoming call is ringing.
class CallIncoming extends CallBlocState {
  final String callId;
  final String callerUserId;
  final String? callerName;
  final String? callerAvatarUrl;
  final CallType callType;
  final RTCSessionDescription offer;

  const CallIncoming({
    required this.callId,
    required this.callerUserId,
    this.callerName,
    this.callerAvatarUrl,
    required this.callType,
    required this.offer,
  });

  @override
  List<Object?> get props => [callId, callerUserId, callerName, callerAvatarUrl, callType, offer];
}

/// Active call in progress (outgoing ringing, connecting, or connected).
class CallActive extends CallBlocState {
  final String callId;
  final String peerUserId;
  final String? peerName;
  final String? peerAvatarUrl;
  final CallType callType;
  final CallState connectionState;
  final bool isAudioMuted;
  final bool isVideoOff;
  final bool isSpeakerOn;
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;
  final int durationSeconds;

  const CallActive({
    required this.callId,
    required this.peerUserId,
    this.peerName,
    this.peerAvatarUrl,
    required this.callType,
    required this.connectionState,
    this.isAudioMuted = false,
    this.isVideoOff = false,
    this.isSpeakerOn = false,
    required this.localRenderer,
    required this.remoteRenderer,
    this.durationSeconds = 0,
  });

  CallActive copyWith({
    String? callId,
    String? peerUserId,
    String? peerName,
    String? peerAvatarUrl,
    CallType? callType,
    CallState? connectionState,
    bool? isAudioMuted,
    bool? isVideoOff,
    bool? isSpeakerOn,
    RTCVideoRenderer? localRenderer,
    RTCVideoRenderer? remoteRenderer,
    int? durationSeconds,
  }) {
    return CallActive(
      callId: callId ?? this.callId,
      peerUserId: peerUserId ?? this.peerUserId,
      peerName: peerName ?? this.peerName,
      peerAvatarUrl: peerAvatarUrl ?? this.peerAvatarUrl,
      callType: callType ?? this.callType,
      connectionState: connectionState ?? this.connectionState,
      isAudioMuted: isAudioMuted ?? this.isAudioMuted,
      isVideoOff: isVideoOff ?? this.isVideoOff,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      localRenderer: localRenderer ?? this.localRenderer,
      remoteRenderer: remoteRenderer ?? this.remoteRenderer,
      durationSeconds: durationSeconds ?? this.durationSeconds,
    );
  }

  @override
  List<Object?> get props => [
        callId,
        peerUserId,
        peerName,
        peerAvatarUrl,
        callType,
        connectionState,
        isAudioMuted,
        isVideoOff,
        isSpeakerOn,
        durationSeconds,
      ];
}

/// Call has terminated.
class CallEnded extends CallBlocState {
  final String? reason;
  final int durationSeconds;

  const CallEnded({this.reason, this.durationSeconds = 0});

  @override
  List<Object?> get props => [reason, durationSeconds];
}
