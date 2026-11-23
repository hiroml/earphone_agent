import AVFoundation
import UIKit
import UserNotifications

/// バックグラウンドでの BT イヤホンマイク継続取得を検証する本体。
/// - フォアグラウンドで start() → AVAudioEngine の入力 tap で音量を取り続ける
/// - 中断 / 経路変更 / エンジン設定変更 / ライフサイクル / AirPods ミュート操作 をすべてログに残す
/// - 30 秒ごとのハートビートで「その間にバッファが届いたか」を記録し、停止（STALL）を検出する
/// 音声データそのものは保存しない。
/// すべてメインスレッドで扱う（オーディオスレッドからは DispatchQueue.main で戻す）。
final class AudioMonitor: ObservableObject {
    // MARK: 状態（UI 表示用）
    @Published private(set) var isRunning = false
    @Published private(set) var wantsListening = false
    @Published private(set) var sessionStart: Date?
    @Published private(set) var currentLevelDB: Float = -160
    @Published private(set) var inSpeech = false
    @Published private(set) var speechSegments = 0
    @Published private(set) var inputDescription = "-"
    @Published private(set) var outputDescription = "-"
    @Published private(set) var isInputMuted = false
    @Published private(set) var restartFailures = 0
    @Published private(set) var stallCount = 0
    // 文字起こし
    @Published private(set) var volatileText = ""
    @Published private(set) var finalTexts: [String] = []
    @Published private(set) var transcriberStatus = "未起動"

    // MARK: 設定（停止中のみ変更可）
    @Published var useHighQualityBluetooth = true
    @Published var mixWithOthers = true
    @Published var useVoiceChatMode = false
    /// イヤホンのタップ操作（AVRCP）受信テスト。mixWithOthers が OFF のときのみ有効に働く。
    @Published var receiveRemoteCommands = false
    /// 端末内文字起こし（iOS 26 SpeechAnalyzer）
    @Published var enableTranscription = true
    /// iPhone 本体マイクを使う（イヤホンは出力のみ A2DP）。周囲の声の拾いやすさ比較用
    @Published var preferBuiltInMic = false
    /// 正解ラベル（いま話しているのは誰か）。開始後も変更可
    @Published var speakerLabel: SpeakerLabel = .selfVoice {
        didSet { if speakerLabel != oldValue { logger.log("LABEL", speakerLabel.rawValue) } }
    }
    @Published var vadThresholdDB: Float = -45 {
        didSet { processor.setThreshold(vadThresholdDB) }
    }

    let logger: EventLogger
    private let remoteProbe: RemoteCommandProbe

    private var engine = AVAudioEngine()
    private let processor = LevelProcessor()
    private var heartbeatTimer: Timer?
    private var uiTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var engineConfigObserver: NSObjectProtocol?
    private var lastHeartbeatBufferCount = 0
    private var notificationAuthRequested = false
    /// LiveTranscriber（iOS 26 専用型のため Any で保持）
    private var transcriberBox: AnyObject?

    static let heartbeatInterval: TimeInterval = 30

    init(logger: EventLogger) {
        self.logger = logger
        self.remoteProbe = RemoteCommandProbe(logger: logger)
        UIDevice.current.isBatteryMonitoringEnabled = true
        processor.onSpeechChange = { [weak self] isStart, db, duration in
            DispatchQueue.main.async { self?.handleSpeechChange(isStart: isStart, db: db, duration: duration) }
        }
        registerObservers()
        logger.log("APP", "launch iOS=\(UIDevice.current.systemVersion) model=\(Self.deviceModel()) battery=\(Self.batteryString())")
        refreshRouteDescription()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let o = engineConfigObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - 開始 / 停止

    func userStart() {
        requestNotificationAuthIfNeeded()
        wantsListening = true
        restartFailures = 0
        stallCount = 0
        speechSegments = 0
        sessionStart = Date()
        logger.log("CONFIG", "hqBluetooth=\(useHighQualityBluetooth) mixWithOthers=\(mixWithOthers) voiceChatMode=\(useVoiceChatMode) remoteCommands=\(receiveRemoteCommands) vadThreshold=\(vadThresholdDB) stt=\(enableTranscription) builtInMic=\(preferBuiltInMic) label=\(speakerLabel.rawValue)")
        if receiveRemoteCommands && mixWithOthers {
            logger.log("CONFIG", "WARNING: mixWithOthers=ON のためリモコンコマンドは届かない見込み")
        }
        if enableTranscription { startTranscriber() }
        start(trigger: "user")
        if receiveRemoteCommands { remoteProbe.enable() }
        startTimers()
    }

    func userStop() {
        wantsListening = false
        remoteProbe.disable()
        stopEngine()
        stopTranscriber()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.log("STOP", "setActive(false) failed \(Self.describe(error))")
        }
        stopTimers()
        let elapsed = sessionStart.map { Self.formatDuration(Date().timeIntervalSince($0)) } ?? "-"
        logger.log("STOP", "user elapsed=\(elapsed) segments=\(speechSegments) stalls=\(stallCount) restartFailures=\(restartFailures) battery=\(Self.batteryString())")
        sessionStart = nil
    }

    /// セッション構成 → エンジン起動。失敗したらログと（背面なら）再開を促す通知。
    @discardableResult
    private func start(trigger: String) -> Bool {
        do {
            try configureSession()
            try startEngine()
            isRunning = true
            logger.log("START", "ok trigger=\(trigger) appState=\(Self.appState())")
            logRoute(context: "start")
            return true
        } catch {
            isRunning = false
            restartFailures += 1
            logger.log("START", "FAILED trigger=\(trigger) appState=\(Self.appState()) error=\(Self.describe(error))")
            if UIApplication.shared.applicationState != .active {
                notifyResumeNeeded(reason: trigger)
            }
            return false
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if mixWithOthers { options.insert(.mixWithOthers) }
        if preferBuiltInMic { options.insert(.allowBluetoothA2DP) }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), useHighQualityBluetooth {
            options.insert(.bluetoothHighQualityRecording)
        }
        #endif
        try session.setCategory(.playAndRecord, mode: useVoiceChatMode ? .voiceChat : .default, options: options)
        try session.setActive(true)

        // BT マイクがあれば明示的に優先する
        if let inputs = session.availableInputs {
            logger.log("ROUTE", "availableInputs=" + inputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", "))
            let preferred: AVAudioSessionPortDescription?
            if preferBuiltInMic {
                preferred = inputs.first(where: { $0.portType == .builtInMic })
            } else {
                preferred = inputs.first(where: { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE })
            }
            if let preferred {
                do {
                    try session.setPreferredInput(preferred)
                } catch {
                    logger.log("ROUTE", "setPreferredInput failed \(Self.describe(error))")
                }
            }
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PoCError.invalidInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        input.removeTap(onBus: 0)
        processor.reset(thresholdDB: vadThresholdDB)
        let processor = self.processor
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            processor.process(buffer)
        }
        observeEngineConfigChange()
        engine.prepare()
        try engine.start()
        logger.log("ENGINE", "started format=\(Int(format.sampleRate))Hz ch=\(format.channelCount)")
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isRunning = false
        inSpeech = false
    }

    // MARK: - 文字起こし

    private func startTranscriber() {
        finalTexts = []
        volatileText = ""
        _ = processor.takeSegmentStats()
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let transcriber = LiveTranscriber()
            transcriber.onLog = { [weak self] msg in
                DispatchQueue.main.async { self?.logger.log("STT", msg) }
            }
            transcriber.onResult = { [weak self] result in
                DispatchQueue.main.async { self?.handleTranscript(text: result.text, isFinal: result.isFinal) }
            }
            transcriberBox = transcriber
            processor.setBufferSink { buffer in transcriber.append(buffer) }
            transcriberStatus = "準備中"
            Task { [weak self] in
                do {
                    let locale = try await transcriber.prepare()
                    DispatchQueue.main.async {
                        self?.transcriberStatus = "動作中 (\(locale))"
                        self?.logger.log("STT", "started locale=\(locale)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.transcriberStatus = "失敗"
                        self?.logger.log("STT", "start FAILED \(Self.describe(error))")
                    }
                }
            }
            return
        }
        #endif
        transcriberStatus = "非対応（iOS 26 / Xcode 26 が必要）"
        logger.log("STT", "unavailable on this build/OS")
    }

    private func stopTranscriber() {
        processor.setBufferSink(nil)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let transcriber = transcriberBox as? LiveTranscriber {
            transcriber.stop()
        }
        #endif
        transcriberBox = nil
        transcriberStatus = "停止"
        logger.log("STT", "stopped finals=\(finalTexts.count)")
    }

    /// 確定結果ごとに、その間の音量統計と正解ラベルを記録する（話者判別の分析用）
    private func handleTranscript(text: String, isFinal: Bool) {
        guard isFinal else {
            volatileText = text
            return
        }
        volatileText = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stats = processor.takeSegmentStats()
        guard !trimmed.isEmpty else { return }
        finalTexts.append(trimmed)
        if finalTexts.count > 50 { finalTexts.removeFirst(finalTexts.count - 50) }
        let mean = stats.meanLoudDB.map { String(format: "%.1f", $0) } ?? "nil"
        let msg = String(format: "final label=%@ peak=%.1f meanLoud=%@ loud=%.1fs span=%.1fs input=%@ chars=%d text=%@",
                         speakerLabel.rawValue, stats.peakDB, mean, stats.loudSec, stats.totalSec,
                         inputDescription, trimmed.count, trimmed)
        logger.log("STT", msg)
    }

    private func restart(trigger: String) {
        guard wantsListening else { return }
        stopEngine()
        start(trigger: trigger)
    }

    // MARK: - 通知ハンドラ

    private func registerObservers() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            self?.handleMediaServicesReset()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            self?.logger.log("HINT", "silenceSecondaryAudio type=\(raw.map { "\($0)" } ?? "nil") (1=begin, 0=end)")
        })

        // AirPods の軸押しミュート（iOS 17+）
        observers.append(nc.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main) { [weak self] note in
            let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue
            self?.handleMuteGesture(muted: muted)
        })

        // ライフサイクル（画面ロックは protectedData で検出）
        let lifecycle: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.willTerminateNotification, "willTerminate"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "screenLocked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "screenUnlocked"),
            (UIApplication.didReceiveMemoryWarningNotification, "memoryWarning"),
        ]
        for (name, label) in lifecycle {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleLifecycle(label)
            })
        }

        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logger.log("DEVICE", "thermalState=\(Self.thermalString())")
        })
    }

    private func observeEngineConfigChange() {
        if let o = engineConfigObserver { NotificationCenter.default.removeObserver(o) }
        engineConfigObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.logger.log("ENGINE", "configurationChange isRunning=\(self.engine.isRunning) appState=\(Self.appState())")
            self.logRoute(context: "configChange")
            self.restart(trigger: "engineConfigChange")
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).map { "\($0)" } ?? "nil"
            isRunning = false
            inSpeech = false
            logger.log("INTERRUPT", "began reason=\(reason) appState=\(Self.appState()) engineRunning=\(engine.isRunning)")
        case .ended:
            let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            logger.log("INTERRUPT", "ended shouldResume=\(shouldResume) appState=\(Self.appState())")
            // shouldResume が false でも再開を試みる（背面で通るかを見るのが検証目的）
            restart(trigger: "interruptionEnded")
        @unknown default:
            logger.log("INTERRUPT", "unknown type=\(typeRaw)")
        }
    }

    private func handleRouteChange(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 999
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map(Self.routeChangeReasonString) ?? "unknown(\(raw))"
        logger.log("ROUTE", "change reason=\(reason) appState=\(Self.appState())")
        logRoute(context: "routeChange")
    }

    private func handleMediaServicesReset() {
        logger.log("ENGINE", "mediaServicesWereReset appState=\(Self.appState())")
        stopEngine()
        engine = AVAudioEngine()
        restart(trigger: "mediaServicesReset")
    }

    private func handleMuteGesture(muted: Bool?) {
        if let muted { isInputMuted = muted }
        logger.log("MUTE", "inputMuteStateChange muted=\(muted.map { "\($0)" } ?? "nil") appState=\(Self.appState()) running=\(isRunning)")
    }

    private func handleLifecycle(_ label: String) {
        logger.log("LIFECYCLE", "\(label) running=\(isRunning)")
        if label == "didBecomeActive", wantsListening, !isRunning {
            // 前面復帰時は自動再開（通知タップでの復帰を想定）
            restart(trigger: "foregroundResume")
        }
    }

    private func handleSpeechChange(isStart: Bool, db: Float, duration: TimeInterval) {
        inSpeech = isStart
        if isStart {
            logger.log("VAD", String(format: "speechStart db=%.1f appState=%@ muted=%@", db, Self.appState(), String(isInputMuted)))
        } else {
            speechSegments += 1
            logger.log("VAD", String(format: "speechEnd duration=%.1fs", duration))
        }
    }

    // MARK: - UI 操作

    func setInputMuted(_ muted: Bool) {
        do {
            try AVAudioApplication.shared.setInputMuted(muted)
            isInputMuted = muted
            logger.log("MUTE", "setInputMuted(\(muted)) from UI")
        } catch {
            logger.log("MUTE", "setInputMuted failed \(Self.describe(error))")
        }
    }

    func logMarker(_ text: String) {
        logger.log("MARK", text)
    }

    // MARK: - タイマー

    private func startTimers() {
        stopTimers()
        lastHeartbeatBufferCount = processor.snapshot().bufferCount
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, UIApplication.shared.applicationState == .active else { return }
            self.currentLevelDB = self.processor.snapshot().lastDB
        }
    }

    private func stopTimers() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        uiTimer?.invalidate()
        uiTimer = nil
    }

    private func heartbeat() {
        let snap = processor.snapshot()
        let delta = snap.bufferCount - lastHeartbeatBufferCount
        lastHeartbeatBufferCount = snap.bufferCount
        let elapsed = sessionStart.map { Self.formatDuration(Date().timeIntervalSince($0)) } ?? "-"
        let msg = String(format: "elapsed=%@ buffers=%d running=%@ engine=%@ appState=%@ db=%.1f battery=%@ thermal=%@ in=%@",
                         elapsed, delta, String(isRunning), String(engine.isRunning), Self.appState(), snap.lastDB,
                         Self.batteryString(), Self.thermalString(), inputDescription)
        logger.log("HEARTBEAT", msg)
        if wantsListening && delta == 0 {
            stallCount += 1
            logger.log("STALL", "no audio buffers in last \(Int(Self.heartbeatInterval))s appState=\(Self.appState())")
        }
    }

    // MARK: - 通知（再開を促す）

    private func requestNotificationAuthIfNeeded() {
        guard !notificationAuthRequested else { return }
        notificationAuthRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.logger.log("NOTIFY", "authorization granted=\(granted)") }
        }
    }

    private func notifyResumeNeeded(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "リスニングが停止しました"
        content.body = "タップしてアプリを開くと再開します（原因: \(reason)）"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "resume-needed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            DispatchQueue.main.async {
                self?.logger.log("NOTIFY", "resumeNeeded posted error=\(error.map { Self.describe($0) } ?? "nil")")
            }
        }
    }

    // MARK: - 経路・端末情報

    private func refreshRouteDescription() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputDescription = route.inputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ",")
        outputDescription = route.outputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ",")
        if inputDescription.isEmpty { inputDescription = "-" }
        if outputDescription.isEmpty { outputDescription = "-" }
    }

    private func logRoute(context: String) {
        refreshRouteDescription()
        let session = AVAudioSession.sharedInstance()
        logger.log("ROUTE", "\(context) in=\(inputDescription) out=\(outputDescription) sampleRate=\(Int(session.sampleRate)) ioBuffer=\(String(format: "%.3f", session.ioBufferDuration))s")
    }

    static func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    static func batteryString() -> String {
        let level = UIDevice.current.batteryLevel
        let pct = level < 0 ? "?" : String(Int((level * 100).rounded()))
        let state: String
        switch UIDevice.current.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        return "\(pct)%(\(state))"
    }

    static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func routeChangeReasonString(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "other(\(r.rawValue))"
        }
    }

    /// OSStatus を four-char code 付きで表示（例: 561145187 = '!rec' = CannotStartRecording）
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var fourCC = ""
        let code = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            fourCC = " '" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return "\(ns.domain)#\(ns.code)\(fourCC) \(ns.localizedDescription)"
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

enum PoCError: LocalizedError {
    case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)

    var errorDescription: String? {
        switch self {
        case let .invalidInputFormat(sr, ch):
            return "入力フォーマットが無効です (sampleRate=\(sr), channels=\(ch))。マイク権限や経路を確認してください。"
        }
    }
}

/// 話者の正解ラベル（検証用に手動で切り替える）
enum SpeakerLabel: String, CaseIterable, Identifiable {
    case selfVoice = "self"
    case other = "other"
    case tv = "tv"
    case mixed = "mixed"
    case silence = "silence"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selfVoice: return "自分"
        case .other: return "他人"
        case .tv: return "TV等"
        case .mixed: return "混在"
        case .silence: return "無音"
        }
    }
}
