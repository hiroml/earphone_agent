import AVFoundation

#if compiler(>=6.2)
import Speech

/// iOS 26 の SpeechAnalyzer / SpeechTranscriber による端末内ストリーミング文字起こし。
/// - prepare() でロケール確認・モデルのダウンロード・解析開始
/// - append() はオーディオスレッドから呼ぶ（フォーマット変換して AsyncStream に流す）
/// - 結果は onResult（任意のスレッド）で通知
@available(iOS 26.0, *)
final class LiveTranscriber {
    struct Result {
        let text: String
        let isFinal: Bool
    }

    var onResult: ((Result) -> Void)?
    var onLog: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    // append() から参照（オーディオスレッド）。prepare 完了までは nil → バッファは捨てる
    private let lock = NSLock()
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var droppedBeforeReady = 0

    func prepare(localeIdentifier: String = "ja-JP") async throws -> String {
        let requested = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        onLog?("locale=\(locale.identifier(.bcp47)) installed=\(isInstalled)")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onLog?("model download start")
            try await request.downloadAndInstall()
            onLog?("model download done")
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.inputBuilder = builder

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.onResult?(Result(text: text, isFinal: result.isFinal))
                }
            } catch {
                self?.onLog?("results error: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)

        lock.lock()
        analyzerFormat = format
        let dropped = droppedBeforeReady
        lock.unlock()
        onLog?("ready format=\(Int(format.sampleRate))Hz ch=\(format.channelCount) common=\(format.commonFormat.rawValue) droppedBeforeReady=\(dropped)")
        return locale.identifier(.bcp47)
    }

    /// オーディオスレッドから呼ばれる。軽い処理（変換と yield）だけにする。
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let format = analyzerFormat, let builder = inputBuilder else {
            droppedBeforeReady += 1
            lock.unlock()
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        let converter = self.converter
        lock.unlock()

        guard let converter, let converted = Self.convert(buffer, with: converter, to: format) else { return }
        builder.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        inputBuilder?.finish()
        inputBuilder = nil
        lock.lock()
        analyzerFormat = nil
        lock.unlock()
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        self.analyzer = nil
        self.resultsTask = nil
        Task { [onLog = self.onLog] in
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                onLog?("finalize error: \(error)")
            }
            resultsTask?.cancel()
        }
    }

    /// 毎回コピーする（tap のバッファを AsyncStream に溜めないため）
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || output.frameLength == 0 { return nil }
        return output
    }
}

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(id): return "SpeechTranscriber が \(id) に対応していません"
        case .noAudioFormat: return "SpeechAnalyzer の音声フォーマットを取得できません"
        }
    }
}
#endif
