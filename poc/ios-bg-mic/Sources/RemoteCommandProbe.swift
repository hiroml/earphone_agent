import MediaPlayer

/// イヤホンのタップ操作（AVRCP の再生/一時停止/曲送り等）がアプリに届くかを検証する。
/// AirPods 以外（例: Soundcore Liberty 5）では、AirPods のミュート操作の代わりの「話しかけトリガー」候補になる。
/// 注意: リモコンコマンドは「Now Playing アプリ」にしか届かない。mixWithOthers が ON だと Now Playing になれない。
/// また、マイク使用中（HFP）はタップが通話操作に置き換わる可能性がある（それ自体が検証対象）。
final class RemoteCommandProbe {
    private let logger: EventLogger
    private var targets: [(MPRemoteCommand, Any)] = []
    private(set) var isEnabled = false

    init(logger: EventLogger) {
        self.logger = logger
    }

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        let center = MPRemoteCommandCenter.shared()
        let commands: [(MPRemoteCommand, String)] = [
            (center.playCommand, "play"),
            (center.pauseCommand, "pause"),
            (center.togglePlayPauseCommand, "togglePlayPause"),
            (center.nextTrackCommand, "nextTrack"),
            (center.previousTrackCommand, "previousTrack"),
        ]
        for (command, name) in commands {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                self?.logger.log("REMOTE", "\(name) appState=\(AudioMonitor.appState())")
                return .success
            }
            targets.append((command, target))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "BgMic PoC リスニング中",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        logger.log("REMOTE", "enabled (Now Playing 登録)")
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        logger.log("REMOTE", "disabled")
    }
}
