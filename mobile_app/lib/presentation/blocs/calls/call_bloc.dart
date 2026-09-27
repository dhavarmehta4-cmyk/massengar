import "dart:async";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_webrtc/flutter_webrtc.dart";
import "../../../core/network/socket_client.dart";
import "../../../domain/usecases/calls/webrtc_service.dart";
import "call_event.dart";
import "call_state.dart";

export "call_event.dart";
export "call_state.dart";

class CallBloc extends Bloc<CallBlocEvent, CallBlocState> {
  final WebRtcService _webrtcService;
  final SocketClient _socketClient;

  StreamSubscription<Map<String, dynamic>>? _offerSub;
  StreamSubscription<Map<String, dynamic>>? _answerSub;
  StreamSubscription<Map<String, dynamic>>? _iceCandidateSub;
  StreamSubscription<Map<String, dynamic>>? _callEndSub;
  StreamSubscription<CallState>? _serviceStateSub;
  StreamSubscription<MediaStream?>? _remoteStreamSub;
  Timer? _callDurationTimer;

  CallBloc({
    WebRtcService? webrtcService,
    SocketClient? socketClient,
  })  : _webrtcService = webrtcService ?? WebRtcService(),
        _socketClient = socketClient ?? SocketClient(),
        super(const CallInitial()) {
    on<StartCall>(_onStartCall);
    on<AcceptCall>(_onAcceptCall);
    on<RejectCall>(_onRejectCall);
    on<EndCall>(_onEndCall);
    on<MuteAudio>(_onMuteAudio);
    on<ToggleVideo>(_onToggleVideo);
    on<SwitchCamera>(_onSwitchCamera);
    on<ToggleSpeaker>(_onToggleSpeaker);

    // Internal socket & WebRTC events
    on<SignalingOfferReceived>(_onOfferReceived);
    on<SignalingAnswerReceived>(_onAnswerReceived);
    on<SignalingIceCandidateReceived>(_onIceCandidateReceived);
    on<SignalingCallEndReceived>(_onCallEndReceived);
    on<WebRtcCallStateChanged>(_onCallStateChanged);
    on<WebRtcRemoteStreamChanged>(_onRemoteStreamChanged);
    on<TickCallTimer>(_onTickCallTimer);

    _bindSocketAndService();
  }

  void _bindSocketAndService() {
    // Listen to incoming WebRTC signaling from SocketClient
    _offerSub = _socketClient.webrtcOfferStream.listen(
      (data) => add(SignalingOfferReceived(data)),
    );
    _answerSub = _socketClient.webrtcAnswerStream.listen(
      (data) => add(SignalingAnswerReceived(data)),
    );
    _iceCandidateSub = _socketClient.webrtcIceCandidateStream.listen(
      (data) => add(SignalingIceCandidateReceived(data)),
    );
    _callEndSub = _socketClient.webrtcCallEndStream.listen(
      (data) => add(SignalingCallEndReceived(data)),
    );

    // Listen to WebRTC service lifecycle & streams
    _serviceStateSub = _webrtcService.callStateStream.listen(
      (state) => add(WebRtcCallStateChanged(state)),
    );
    _remoteStreamSub = _webrtcService.remoteStreamStream.listen(
      (stream) => add(WebRtcRemoteStreamChanged(stream)),
    );
  }

  Future<void> _onStartCall(StartCall event, Emitter<CallBlocState> emit) async {
    try {
      final callId = await _webrtcService.startCall(
        targetUserId: event.targetUserId,
        callType: event.callType,
      );

      emit(CallActive(
        callId: callId,
        peerUserId: event.targetUserId,
        peerName: event.targetUserName ?? "User",
        peerAvatarUrl: event.targetAvatarUrl,
        callType: event.callType,
        connectionState: CallState.outgoing,
        localRenderer: _webrtcService.localRenderer,
        remoteRenderer: _webrtcService.remoteRenderer,
      ));
    } catch (e) {
      emit(CallEnded(reason: "Failed to start call: $e"));
    }
  }

  Future<void> _onAcceptCall(AcceptCall event, Emitter<CallBlocState> emit) async {
    final current = state;
    if (current is! CallIncoming) return;

    try {
      await _webrtcService.acceptCall(
        callId: current.callId,
        callerUserId: current.callerUserId,
        offer: current.offer,
        callType: current.callType,
      );

      emit(CallActive(
        callId: current.callId,
        peerUserId: current.callerUserId,
        peerName: current.callerName ?? "User",
        peerAvatarUrl: current.callerAvatarUrl,
        callType: current.callType,
        connectionState: CallState.connecting,
        localRenderer: _webrtcService.localRenderer,
        remoteRenderer: _webrtcService.remoteRenderer,
      ));
    } catch (e) {
      emit(CallEnded(reason: "Failed to accept call: $e"));
    }
  }

  Future<void> _onRejectCall(RejectCall event, Emitter<CallBlocState> emit) async {
    final current = state;
    if (current is! CallIncoming) return;

    await _webrtcService.rejectCall(
      callId: current.callId,
      callerUserId: current.callerUserId,
    );

    emit(const CallEnded(reason: "rejected"));
  }

  Future<void> _onEndCall(EndCall event, Emitter<CallBlocState> emit) async {
    int duration = 0;
    if (state is CallActive) {
      duration = (state as CallActive).durationSeconds;
    }
    _stopTimer();
    await _webrtcService.endCall();
    emit(CallEnded(reason: "ended", durationSeconds: duration));
  }

  Future<void> _onMuteAudio(MuteAudio event, Emitter<CallBlocState> emit) async {
    final current = state;
    if (current is! CallActive) return;

    final newMuted = event.muted ?? !current.isAudioMuted;
    await _webrtcService.toggleMute(newMuted);
    emit(current.copyWith(isAudioMuted: newMuted));
  }

  Future<void> _onToggleVideo(ToggleVideo event, Emitter<CallBlocState> emit) async {
    final current = state;
    if (current is! CallActive) return;

    final newVideoOff = event.videoOff ?? !current.isVideoOff;
    await _webrtcService.toggleCamera(newVideoOff);
    emit(current.copyWith(isVideoOff: newVideoOff));
  }

  Future<void> _onSwitchCamera(SwitchCamera event, Emitter<CallBlocState> emit) async {
    if (state is! CallActive) return;
    await _webrtcService.switchCamera();
  }

  Future<void> _onToggleSpeaker(ToggleSpeaker event, Emitter<CallBlocState> emit) async {
    final current = state;
    if (current is! CallActive) return;

    final newSpeaker = event.speakerOn ?? !current.isSpeakerOn;
    await _webrtcService.setSpeakerphone(newSpeaker);
    emit(current.copyWith(isSpeakerOn: newSpeaker));
  }

  // ------------------------------------------------------------------
  // Signaling Handlers
  // ------------------------------------------------------------------

  void _onOfferReceived(SignalingOfferReceived event, Emitter<CallBlocState> emit) {
    final data = event.payload;
    final callId = data["callId"] as String? ?? "";
    final fromUserId = data["fromUserId"] as String? ?? "";
    final callTypeStr = data["callType"] as String? ?? "audio";
    final callType = callTypeStr == "video" ? CallType.video : CallType.audio;
    final sdp = Map<String, dynamic>.from(data["sdp"] as Map);
    final offer = RTCSessionDescription(sdp["sdp"] as String?, sdp["type"] as String?);

    emit(CallIncoming(
      callId: callId,
      callerUserId: fromUserId,
      callerName: "User $fromUserId",
      callType: callType,
      offer: offer,
    ));
  }

  Future<void> _onAnswerReceived(SignalingAnswerReceived event, Emitter<CallBlocState> emit) async {
    await _webrtcService.handleAnswer(event.payload);
  }

  Future<void> _onIceCandidateReceived(SignalingIceCandidateReceived event, Emitter<CallBlocState> emit) async {
    await _webrtcService.handleIceCandidate(event.payload);
  }

  void _onCallEndReceived(SignalingCallEndReceived event, Emitter<CallBlocState> emit) {
    int duration = 0;
    if (state is CallActive) {
      duration = (state as CallActive).durationSeconds;
    }
    _stopTimer();
    final reason = event.payload["reason"] as String? ?? "ended";
    emit(CallEnded(reason: reason, durationSeconds: duration));
  }

  void _onCallStateChanged(WebRtcCallStateChanged event, Emitter<CallBlocState> emit) {
    final current = state;
    if (current is CallActive) {
      if (event.state == CallState.connected) {
        _startTimer();
        emit(current.copyWith(connectionState: CallState.connected));
      } else if (event.state == CallState.ended || event.state == CallState.idle) {
        _stopTimer();
        emit(CallEnded(reason: "disconnected", durationSeconds: current.durationSeconds));
      } else {
        emit(current.copyWith(connectionState: event.state));
      }
    }
  }

  void _onRemoteStreamChanged(WebRtcRemoteStreamChanged event, Emitter<CallBlocState> emit) {
    final current = state;
    if (current is CallActive) {
      emit(current.copyWith(remoteRenderer: _webrtcService.remoteRenderer));
    }
  }

  void _onTickCallTimer(TickCallTimer event, Emitter<CallBlocState> emit) {
    final current = state;
    if (current is CallActive) {
      emit(current.copyWith(durationSeconds: current.durationSeconds + 1));
    }
  }

  void _startTimer() {
    _callDurationTimer?.cancel();
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      add(const TickCallTimer());
    });
  }

  void _stopTimer() {
    _callDurationTimer?.cancel();
    _callDurationTimer = null;
  }

  @override
  Future<void> close() {
    _stopTimer();
    _offerSub?.cancel();
    _answerSub?.cancel();
    _iceCandidateSub?.cancel();
    _callEndSub?.cancel();
    _serviceStateSub?.cancel();
    _remoteStreamSub?.cancel();
    return super.close();
  }
}
