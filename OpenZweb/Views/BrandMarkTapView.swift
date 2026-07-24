import SwiftUI
import AVKit
import AVFoundation

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
    @State private var loopObserver: NSObjectProtocol?

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
                Button(L10n.t("egg.close")) {
                    stop()
                    eggs.showPlayer = false
                }
                .keyboardShortcut(.cancelAction)
            }

            ZStack {
                Color.black.opacity(0.92)
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
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
        guard let url = Self.videoURL() else { return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        soundOn = false
        player = p
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            p.seek(to: .zero)
            p.play()
        }
        p.play()
    }

    private func stop() {
        player?.pause()
        player = nil
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
    }

    private static func videoURL() -> URL? {
        if let u = Bundle.main.url(forResource: "easteregg", withExtension: "mp4") {
            return u
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Views
            .deletingLastPathComponent() // OpenZweb
            .deletingLastPathComponent() // root
            .appendingPathComponent("easteregg.mp4")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }
}
