import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: AudioMonitor
    @EnvironmentObject private var logger: EventLogger
    @State private var marker = ""

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                controlSection
                settingsSection
                markerSection
                logSection
            }
            .navigationTitle("BgMic PoC")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: logger.fileURL) {
                        Label("ログ出力", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    // MARK: 状態

    private var statusSection: some View {
        Section("状態") {
            LabeledContent("リスニング") {
                Text(monitor.isRunning ? "● 取得中" : (monitor.wantsListening ? "⚠︎ 停止（再開待ち）" : "停止"))
                    .foregroundStyle(monitor.isRunning ? .green : (monitor.wantsListening ? .orange : .secondary))
            }
            if let start = monitor.sessionStart {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("経過", value: AudioMonitor.formatDuration(context.date.timeIntervalSince(start)))
                }
            }
            LabeledContent("レベル", value: String(format: "%.1f dB", monitor.currentLevelDB))
            ProgressView(value: Double(max(0, min(1, (monitor.currentLevelDB + 80) / 80))))
                .tint(monitor.currentLevelDB > monitor.vadThresholdDB ? .green : .gray)
            LabeledContent("発話区間", value: "\(monitor.speechSegments)")
            LabeledContent("STALL / 再開失敗", value: "\(monitor.stallCount) / \(monitor.restartFailures)")
            LabeledContent("ミュート", value: monitor.isInputMuted ? "ON" : "OFF")
            VStack(alignment: .leading, spacing: 2) {
                Text("入力: \(monitor.inputDescription)")
                Text("出力: \(monitor.outputDescription)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 操作

    private var controlSection: some View {
        Section {
            if monitor.wantsListening {
                Button(role: .destructive) { monitor.userStop() } label: {
                    Label("リスニング停止", systemImage: "stop.circle.fill")
                }
            } else {
                Button { monitor.userStart() } label: {
                    Label("リスニング開始", systemImage: "mic.circle.fill")
                }
            }
            Toggle("入力ミュート（AVAudioApplication）", isOn: Binding(
                get: { monitor.isInputMuted },
                set: { monitor.setInputMuted($0) }
            ))
        } footer: {
            Text("開始後に画面ロック・他アプリへ切替して検証します。音声そのものは保存せず、音量などのメタ情報のみ記録します。")
        }
    }

    // MARK: 設定

    private var settingsSection: some View {
        Section("設定（停止中のみ変更可）") {
            Toggle("BT 高品質録音（iOS 26+ / H2 AirPods）", isOn: $monitor.useHighQualityBluetooth)
            Toggle("他アプリの音と混ぜる（mixWithOthers）", isOn: $monitor.mixWithOthers)
            Toggle("voiceChat モード（エコーキャンセル）", isOn: $monitor.useVoiceChatMode)
            Toggle("イヤホンのタップ操作を受信（要 mixWithOthers OFF）", isOn: $monitor.receiveRemoteCommands)
            VStack(alignment: .leading) {
                Text(String(format: "VAD 閾値: %.0f dB", monitor.vadThresholdDB))
                Slider(value: $monitor.vadThresholdDB, in: -70 ... -20, step: 1)
            }
        }
        .disabled(monitor.wantsListening)
    }

    // MARK: マーカー（試験の区切りをログに残す）

    private var markerSection: some View {
        Section("マーカー") {
            HStack {
                TextField("例: T3 着信テスト開始", text: $marker)
                Button("記録") {
                    monitor.logMarker(marker.isEmpty ? "(marker)" : marker)
                    marker = ""
                }
            }
        }
    }

    // MARK: ログ

    private var logSection: some View {
        Section("ログ（新しい順・最大 500 件）") {
            ForEach(logger.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.category).font(.caption.bold()).foregroundStyle(color(for: entry.category))
                        Spacer()
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message).font(.caption2.monospaced())
                }
            }
        }
    }

    private func color(for category: String) -> Color {
        switch category {
        case "STALL", "INTERRUPT": return .red
        case "START", "STOP": return .blue
        case "ROUTE", "ENGINE": return .purple
        case "MUTE", "REMOTE": return .orange
        case "VAD": return .green
        default: return .primary
        }
    }
}
