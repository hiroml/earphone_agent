import AVFoundation

/// オーディオスレッドで呼ばれる軽量処理: RMS(dB) 計算と、エネルギー閾値ベースの簡易 VAD。
/// 状態はロックで保護し、メインスレッドからは snapshot() で読む。
final class LevelProcessor {
    struct Snapshot {
        let bufferCount: Int
        let lastDB: Float
        let inSpeech: Bool
    }

    /// 前回 takeSegmentStats() 以降の音量統計（文字起こしの確定結果と対応づけて話者判別の材料にする）
    struct SegmentStats {
        let peakDB: Float
        let meanLoudDB: Float?   // 閾値を超えたバッファの平均 dB（なければ nil）
        let loudSec: Double      // 閾値を超えていた時間
        let totalSec: Double     // 集計期間
    }

    /// (isSpeechStart, dB, 発話区間の長さ[秒]（終了時のみ）)
    var onSpeechChange: ((Bool, Float, TimeInterval) -> Void)?

    /// 生バッファの受け渡し先（文字起こし用）。オーディオスレッドで呼ばれる。
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var accPeak: Float = -160
    private var accLoudSum: Float = 0
    private var accLoudCount = 0
    private var accLoudSec: Double = 0
    private var accTotalSec: Double = 0

    func setBufferSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        onBuffer = sink
        lock.unlock()
    }

    func takeSegmentStats() -> SegmentStats {
        lock.lock()
        defer {
            accPeak = -160
            accLoudSum = 0
            accLoudCount = 0
            accLoudSec = 0
            accTotalSec = 0
            lock.unlock()
        }
        return SegmentStats(
            peakDB: accPeak,
            meanLoudDB: accLoudCount > 0 ? accLoudSum / Float(accLoudCount) : nil,
            loudSec: accLoudSec,
            totalSec: accTotalSec
        )
    }

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

        let duration = Double(frames) / buffer.format.sampleRate

        var event: (Bool, Float, TimeInterval)?
        lock.lock()
        bufferCount += 1
        lastDB = db
        accPeak = max(accPeak, db)
        accTotalSec += duration
        if db > thresholdDB {
            accLoudSum += db
            accLoudCount += 1
            accLoudSec += duration
        }
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
        let bufferSink = onBuffer
        lock.unlock()

        bufferSink?(buffer)
        if let e = event {
            callback?(e.0, e.1, e.2)
        }
    }
}
