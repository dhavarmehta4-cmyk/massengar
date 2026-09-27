import "package:equatable/equatable.dart";
import "package:flutter_webrtc/flutter_webrtc.dart";
import "../../../domain/usecases/calls/webrtc_service.dart";

abstract class CallBlocEvent extends Equatable {
  const CallBlocEvent();

  @override
  List<Object?> get props => [];
}

/// Start an outgoing audio or video call.
class StartCall extends CallBlocEvent {
  final String targetUserId;
  final String? targetUserName;
  final String? targetAvatarUrl;
  final CallType callType;

  const StartCall({
    required this.targetUserId,
    this.targetUserName,
    this.targetAvatarUrl,
    this.callType = CallType.audio,
  });

  @override
  List<Object?> get props => [targetUserId, targetUserName, targetAvatarUrl, callType];
}

/// Accept an incoming call.
class AcceptCall extends CallBlocEvent {
  const AcceptCall();
}

/// Reject an incoming call.
class RejectCall extends CallBlocEvent {
  const RejectCall();
}

/// End the currently active or outgoing call.
class EndCall extends CallBlocEvent {
  const EndCall();
}

/// Mute or unmute microphone.
class MuteAudio extends CallBlocEvent {
  final bool? muted;
  const MuteAudio({this.muted});

  @override
  List<Object?> get props => [muted];
}

/// Turn camera on or off.
class ToggleVideo extends CallBlocEvent {
  final bool? videoOff;
  const ToggleVideo({this.videoOff});

  @override
  List<Object?> get props => [videoOff];
}

/// Flip between front and back camera.
class SwitchCamera extends CallBlocEvent {
  const SwitchCamera();
}

/// Toggle speakerphone on or off.
class ToggleSpeaker extends CallBlocEvent {
  final bool? speakerOn;
  const ToggleSpeaker({this.speakerOn});

  @override
  List<Object?> get props => [speakerOn];
}

// ------------------------------------------------------------------
// Internal Signaling Events (dispatched by SocketClient listeners)
// ------------------------------------------------------------------

class SignalingOfferReceived extends CallBlocEvent {
  final Map<String, dynamic> payload;
  const SignalingOfferReceived(this.payload);

  @override
  List<Object?> get props => [payload];
}

class SignalingAnswerReceived extends CallBlocEvent {
  final Map<String, dynamic> payload;
  const SignalingAnswerReceived(this.payload);

  @override
  List<Object?> get props => [payload];
}

class SignalingIceCandidateReceived extends CallBlocEvent {
  final Map<String, dynamic> payload;
  const SignalingIceCandidateReceived(this.payload);

  @override
  List<Object?> get props => [payload];
}

class SignalingCallEndReceived extends CallBlocEvent {
  final Map<String, dynamic> payload;
  const SignalingCallEndReceived(this.payload);

  @override
  List<Object?> get props => [payload];
}

class WebRtcCallStateChanged extends CallBlocEvent {
  final CallState state;
  const WebRtcCallStateChanged(this.state);

  @override
  List<Object?> get props => [state];
}

class WebRtcRemoteStreamChanged extends CallBlocEvent {
  final MediaStream? stream;
  const WebRtcRemoteStreamChanged(this.stream);

  @override
  List<Object?> get props => [stream];
}

class TickCallTimer extends CallBlocEvent {
  const TickCallTimer();
}
