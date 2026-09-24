import SwiftUI
import AVKit
import CuztomSignalCore

/// Incoming call screen (full-screen overlay)
struct IncomingCallView: View {
    @Environment(ChatViewModel.self) private var vm
    @ObservedObject var callController = CallController.shared

    let call: ActiveCall
    let onAnswer: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                // Caller info
                VStack(spacing: 8) {
                    Text("Incoming \(call.callRecord.mediaType.rawValue.capitalized) Call")
                        .font(.title2)
                        .foregroundStyle(.white)

                    Text(call.callRecord.remotePeer.phone ?? call.callRecord.remotePeer.uuidString ?? "Unknown")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.top, 100)

                Spacer()

                // Action buttons
                HStack(spacing: 80) {
                    // Decline
                    Button(action: onDecline) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.white)
                            .frame(width: 100, height: 100)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    // Answer
                    Button(action: onAnswer) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.white)
                            .frame(width: 100, height: 100)
                            .background(Color.green)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.bottom, 100)
            }
        }
        .onAppear {
            // Ring ring sound would go here
        }
    }
}

/// Active call screen (voice or video)
struct ActiveCallView: View {
    @Environment(ChatViewModel.self) private var vm
    @ObservedObject var callController = CallController.shared

    let call: ActiveCall

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if call.callRecord.mediaType == .video {
                // Video call layout
                VideoCallLayout(call: call)
            } else {
                // Voice call layout
                VoiceCallLayout(call: call)
            }

            // Call controls overlay
            VStack {
                Spacer()
                CallControlsBar(call: call)
                    .padding(.bottom, 50)
            }
        }
        .onDisappear {
            // Cleanup when view dismissed
        }
    }
}

struct VideoCallLayout: View {
    let call: ActiveCall

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Remote video (full screen when connected)
                if call.callRecord.state == .active, call.remoteVideoEnabled {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            Text("Remote Video")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                } else {
                    // Connecting state
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text(call.callRecord.state.rawValue.capitalized)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                // Local preview (picture-in-picture)
                if call.localVideoEnabled {
                    VStack {
                        HStack {
                            Spacer()
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 140, height: 200)
                                .overlay {
                                    Text("Local Preview")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .padding(20)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

struct VoiceCallLayout: View {
    let call: ActiveCall

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            // Contact avatar/name
            VStack(spacing: 16) {
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: 160, height: 160)
                    .overlay {
                        Text(String(call.callRecord.remotePeer.phone?.prefix(1) ?? "?"))
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(.white)
                    }

                Text(call.callRecord.remotePeer.phone ?? call.callRecord.remotePeer.uuidString ?? "Unknown")
                    .font(.title)
                    .foregroundStyle(.white)

                Text(call.callRecord.state.rawValue.capitalized)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))

                if let connectTime = call.callRecord.connectTime {
                    Text(formatDuration(Date().timeIntervalSince(connectTime)))
                        .font(.system(.title, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }

            Spacer()
        }
    }
}

struct CallControlsBar: View {
    @Environment(ChatViewModel.self) private var vm
    @ObservedObject var callController = CallController.shared

    let call: ActiveCall

    var body: some View {
        HStack(spacing: 40) {
            // Mute
            ControlButton(
                icon: call.muted ? "mic.slash.fill" : "mic.fill",
                label: call.muted ? "Unmute" : "Mute",
                isActive: call.muted,
                color: .white
            ) {
                callController.setMuted(!call.muted)
            }

            // Speaker
            ControlButton(
                icon: call.speakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                label: call.speakerOn ? "Speaker Off" : "Speaker On",
                isActive: call.speakerOn,
                color: .white
            ) {
                callController.setSpeakerOn(!call.speakerOn)
            }

            // Video toggle (video calls only)
            if call.callRecord.mediaType == .video {
                ControlButton(
                    icon: call.localVideoEnabled ? "video.fill" : "video.slash.fill",
                    label: call.localVideoEnabled ? "Stop Video" : "Start Video",
                    isActive: !call.localVideoEnabled, // highlighted when OFF
                    color: call.localVideoEnabled ? .white : .red
                ) {
                    callController.setLocalVideoEnabled(!call.localVideoEnabled)
                }
            }

            // End call
            ControlButton(
                icon: "phone.down.fill",
                label: "End",
                isActive: true,
                color: .red
            ) {
                Task {
                    try? await callController.endCall(call)
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

struct ControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(color)
                    .frame(width: 72, height: 72)
                    .background(isActive ? color.opacity(0.2) : Color.white.opacity(0.15))
                    .clipShape(Circle())

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Call history row
struct CallHistoryRow: View {
    let record: CallRecord

    var body: some View {
        HStack(spacing: 12) {
            // Call type icon
            Image(systemName: callTypeIcon)
                .font(.title2)
                .foregroundStyle(callTypeColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.remotePeer.phone ?? record.remotePeer.uuidString ?? "Unknown")
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(record.direction.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let duration = record.duration {
                        Text(formatDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(record.endReason?.rawValue.capitalized ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(formatDate(record.startTime ?? Date()))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var callTypeIcon: String {
        switch (record.mediaType, record.direction) {
        case (.voice, .outgoing): return "phone.arrow.up.right"
        case (.voice, .incoming): return "phone.arrow.down.left"
        case (.video, .outgoing): return "video.arrow.up.right"
        case (.video, .incoming): return "video.arrow.down.left"
        }
    }

    private var callTypeColor: Color {
        record.endReason == .missed || record.endReason == .declined ? .red : .primary
    }
}

/// Call history view
struct CallHistoryView: View {
    @ObservedObject var callController = CallController.shared

    var body: some View {
        List {
            ForEach(callController.callHistory.reversed()) { record in
                CallHistoryRow(record: record)
            }
        }
        .navigationTitle("Call History")
    }
}

// MARK: - Helpers

private func formatDuration(_ interval: TimeInterval) -> String {
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    let seconds = Int(interval) % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}