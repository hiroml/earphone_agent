import AVFoundation

/// オーディオスレッドで呼ばれる軽量処理: RMS(dB) 計算と、エネルギー閾値ベースの簡易 VAD。
/// 状態はロックで保護し、メインスレッドからは snapshot() で読む。
final class LevelProcessor {
    struct Snapshot {
        let bufferCount: Int
        let lastDB: Float
        let inSpeech: Bool
    }

    /// (isSpeechStart, dB, 発話区間の長さ[秒]（終了時のみ）)
    var onSpeechChange: ((Bool, Float, TimeInterval) -> Void)?

    private let lock = NSLock()
    private var bufferCount = 0
    private var lastDB: Float = -160
    private var thresholdDB: Float = -45
    private var inSpeech = false
    private var speechStart: TimeInterval = 0
    private var lastLoud: TimeInterval = 0
    private let hangover: TimeInterval = 0.8

    func reset(thresholdDB: Float) {
        lock.lock()
        self.thresholdDB = thresholdDB
        inSpeech = false
        lock.unlock()
    }

    func setThreshold(_ db: Float) {
        lock.lock()
        thresholdDB = db
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(bufferCount: bufferCount, lastDB: lastDB, inSpeech: inSpeech)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let samples = channels[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        let rms = (sum / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-8))
        let now = ProcessInfo.processInfo.systemUptime

        var event: (Bool, Float, TimeInterval)?
        lock.lock()
        bufferCount += 1
        lastDB = db
        if db > thresholdDB {
            lastLoud = now
            if !inSpeech {
                inSpeech = true
                speechStart = now
                event = (true, db, 0)
            }
        } else if inSpeech && now - lastLoud > hangover {
            inSpeech = false
            event = (false, db, lastLoud - speechStart)
        }
        let callback = onSpeechChange
        lock.unlock()

        if let e = event {
            callback?(e.0, e.1, e.2)
        }
    }
}
