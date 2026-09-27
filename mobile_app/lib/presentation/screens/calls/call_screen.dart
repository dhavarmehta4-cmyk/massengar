import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_webrtc/flutter_webrtc.dart";
import "../../../core/theme/app_theme.dart";
import "../../../domain/usecases/calls/webrtc_service.dart";
import "../../blocs/calls/call_bloc.dart";

class CallScreen extends StatelessWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CallBloc, CallBlocState>(
      listener: (context, state) {
        if (state is CallEnded) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                state.reason != null
                    ? "Call ended: ${state.reason}"
                    : "Call ended",
              ),
              duration: const Duration(seconds: 1),
            ),
          );
          final navigator = Navigator.of(context);
          Future.delayed(const Duration(milliseconds: 600), () {
            if (navigator.canPop()) {
              navigator.pop();
            }
          });
        }
      },
      builder: (context, state) {
        if (state is CallIncoming) {
          return _buildIncomingCallView(context, state);
        } else if (state is CallActive) {
          return _buildActiveCallView(context, state);
        } else if (state is CallEnded) {
          return _buildCallEndedView(context, state);
        }
        return const Scaffold(
          backgroundColor: AppTheme.background,
          body: Center(
            child: CircularProgressIndicator(color: AppTheme.primary),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------
  // Incoming Call View
  // ------------------------------------------------------------------

  Widget _buildIncomingCallView(BuildContext context, CallIncoming state) {
    final isVideo = state.callType == CallType.video;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                children: [
                  const SizedBox(height: 20),
                  Text(
                    isVideo ? "Incoming Video Call" : "Incoming Voice Call",
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 16,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    state.callerName ?? "User",
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppTheme.primaryGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.35),
                      blurRadius: 36,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    (state.callerName ?? "U").substring(0, 1).toUpperCase(),
                    style: const TextStyle(
                      fontSize: 54,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Reject Button
                  _buildCircleAction(
                    icon: Icons.call_end,
                    color: AppTheme.error,
                    label: "Decline",
                    onTap: () {
                      context.read<CallBloc>().add(const RejectCall());
                    },
                  ),
                  // Accept Button
                  _buildCircleAction(
                    icon: isVideo ? Icons.videocam : Icons.call,
                    color: Colors.greenAccent.shade700,
                    label: "Accept",
                    onTap: () {
                      context.read<CallBloc>().add(const AcceptCall());
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Active Call View
  // ------------------------------------------------------------------

  Widget _buildActiveCallView(BuildContext context, CallActive state) {
    final isVideo = state.callType == CallType.video;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          // Background: Video or Audio Avatar
          if (isVideo)
            Positioned.fill(
              child: state.connectionState == CallState.connected
                  ? RTCVideoView(
                      state.remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : _buildAudioPlaceholder(state),
            )
          else
            Positioned.fill(
              child: _buildAudioPlaceholder(state),
            ),

          // Picture-in-picture Local Video (if video call)
          if (isVideo && !state.isVideoOff)
            Positioned(
              top: 50,
              right: 16,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  color: Colors.black54,
                  child: RTCVideoView(
                    state.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),

          // Top Info Bar
          Positioned(
            top: 50,
            left: 20,
            right: isVideo ? 140 : 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.peerName ?? "User",
                  style: const TextStyle(
                    color: AppTheme.textMain,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatCallStatus(state),
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),

          // Bottom Controls Panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Mute Mic
                  _buildControlBtn(
                    icon: state.isAudioMuted ? Icons.mic_off : Icons.mic,
                    active: state.isAudioMuted,
                    onTap: () {
                      context.read<CallBloc>().add(const MuteAudio());
                    },
                  ),
                  // Speakerphone
                  _buildControlBtn(
                    icon: state.isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                    active: state.isSpeakerOn,
                    onTap: () {
                      context.read<CallBloc>().add(const ToggleSpeaker());
                    },
                  ),
                  // Video toggle (if video call)
                  if (isVideo) ...[
                    _buildControlBtn(
                      icon: state.isVideoOff ? Icons.videocam_off : Icons.videocam,
                      active: state.isVideoOff,
                      onTap: () {
                        context.read<CallBloc>().add(const ToggleVideo());
                      },
                    ),
                    _buildControlBtn(
                      icon: Icons.cameraswitch,
                      active: false,
                      onTap: () {
                        context.read<CallBloc>().add(const SwitchCamera());
                      },
                    ),
                  ],
                  // End Call Button
                  _buildCircleAction(
                    icon: Icons.call_end,
                    color: AppTheme.error,
                    label: "End",
                    onTap: () {
                      context.read<CallBloc>().add(const EndCall());
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Call Ended View
  // ------------------------------------------------------------------

  Widget _buildCallEndedView(BuildContext context, CallEnded state) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.surface.withValues(alpha: 0.8),
              ),
              child: const Icon(Icons.call_end, color: AppTheme.error, size: 36),
            ),
            const SizedBox(height: 20),
            Text(
              state.reason ?? "Call Ended",
              style: const TextStyle(
                color: AppTheme.textMain,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Duration: ${_formatDuration(state.durationSeconds)}",
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Helper Widgets & Formatting
  // ------------------------------------------------------------------

  Widget _buildAudioPlaceholder(CallActive state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppTheme.primaryGradient,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.3),
                  blurRadius: 32,
                  spreadRadius: 6,
                ),
              ],
            ),
            child: Center(
              child: Text(
                (state.peerName ?? "U").substring(0, 1).toUpperCase(),
                style: const TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? Colors.white
              : AppTheme.surface.withValues(alpha: 0.9),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        child: Icon(
          icon,
          color: active ? Colors.black : Colors.white,
          size: 24,
        ),
      ),
    );
  }

  Widget _buildCircleAction({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  String _formatCallStatus(CallActive state) {
    switch (state.connectionState) {
      case CallState.outgoing:
        return "Ringing...";
      case CallState.connecting:
        return "Connecting...";
      case CallState.connected:
        return _formatDuration(state.durationSeconds);
      default:
        return "";
    }
  }

  String _formatDuration(int seconds) {
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return "${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}";
  }
}
