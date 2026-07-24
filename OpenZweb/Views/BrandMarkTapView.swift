import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// Shared brand mark with 9-tap easter egg.
struct BrandMarkTapView: View {
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12
    @EnvironmentObject private var eggs: EasterEggController

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { eggs.registerTap() }
    }
}

@MainActor
final class EasterEggController: ObservableObject {
    @Published var showPlayer = false
    private var taps = 0
    private var lastTap = Date.distantPast

    func registerTap() {
        let now = Date()
        if now.timeIntervalSince(lastTap) > 2.5 {
            taps = 0
        }
        lastTap = now
        taps += 1
        if taps >= 9 {
            taps = 0
            showPlayer = true
        }
    }
}

struct EasterEggPlayerSheet: View {
    @EnvironmentObject private var eggs: EasterEggController
    @State private var player: AVPlayer?
    @State private var soundOn = false
    @State private var statusText: String?
    @State private var endObserver: NSObjectProtocol?
    @State private var failObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L10n.t("egg.title"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle(isOn: $soundOn) {
                    Text(L10n.t("egg.unmute"))
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .frame(width: 120)
                .disabled(player == nil)
                Button(L10n.t("egg.close")) {
                    stop()
                    eggs.showPlayer = false
                }
                .keyboardShortcut(.cancelAction)
            }

            ZStack {
                Color.black.opacity(0.92)
                if let player {
                    // Use AppKit AVPlayerView — more stable than SwiftUI VideoPlayer on macOS sheets.
                    EasterEggAVPlayerView(player: player)
                } else if let statusText {
                    Text(statusText)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .frame(minWidth: 520, minHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { start() }
        .onDisappear { stop() }
        .onChange(of: soundOn) { _, on in
            player?.isMuted = !on
        }
    }

    private func start() {
        stop()
        guard let url = Self.videoURL() else {
            statusText = L10n.t("egg.missing")
            return
        }
        statusText = nil

        // Avoid App Nap / audio session issues when muted by default.
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        soundOn = false
        player = p

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                statusText = L10n.t("egg.play_error")
            }
        }

        // Observe item status for immediate load failures.
        Task { @MainActor in
            for _ in 0..<40 {
                switch item.status {
                case .readyToPlay:
                    p.play()
                    return
                case .failed:
                    statusText = item.error?.localizedDescription ?? L10n.t("egg.play_error")
                    return
                case .unknown:
                    try? await Task.sleep(nanoseconds: 50_000_000)
                @unknown default:
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            // Still unknown — try play anyway.
            p.play()
        }
    }

    private func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
    }

    private static func videoURL() -> URL? {
        if let u = Bundle.main.url(forResource: "easteregg", withExtension: "mp4") {
            return u
        }
        // Dev fallback when running from Xcode without copy phase.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Views
            .deletingLastPathComponent() // OpenZweb
            .deletingLastPathComponent() // root
            .appendingPathComponent("easteregg.mp4")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }
}

/// AppKit-backed player to avoid SwiftUI VideoPlayer sheet crashes.
private struct EasterEggAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
