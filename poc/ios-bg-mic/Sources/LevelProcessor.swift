import AVFoundation

/// オーディオスレッドで呼ばれる軽量処理: RMS(dB) 計算と、エネルギー閾値ベースの簡易 VAD。
/// 状態はロックで保護し、メインスレッドからは snapshot() で読む。
final class LevelProcessor {
    struct Snapshot {
        let bufferCount: Int
        let lastDB: Float
        let inSpeech: Bool
    }

    /// 1 発話ぶんの音量統計（文字起こしの確定結果と対応づけて話者判別の材料にする）
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

    /// 直近の (時刻, dB, 長さ) を保持するリングバッファ。発話区間の統計をさかのぼって計算するため
    private struct LevelSample {
        let time: TimeInterval
        let db: Float
        let duration: Double
    }
    private var history: [LevelSample] = []
    private let historyWindow: TimeInterval = 120
    private var utteranceStart: TimeInterval?

    func setBufferSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        onBuffer = sink
        lock.unlock()
    }

    /// 発話の開始を記録する（文字起こしの最初の途中結果が出たとき）。
    /// 途中結果は話し始めより遅れて出るので、preRoll 秒さかのぼる。
    func markUtteranceStart(preRoll: TimeInterval = 2.0) {
        lock.lock()
        if utteranceStart == nil {
            utteranceStart = ProcessInfo.processInfo.systemUptime - preRoll
        }
        lock.unlock()
    }

    /// 発話開始（markUtteranceStart）から現在までの統計を返し、開始時刻をリセットする。
    /// 開始が記録されていなければ直近 fallback 秒を使う。
    func takeUtteranceStats(fallback: TimeInterval = 5.0) -> SegmentStats {
        lock.lock()
        defer {
            utteranceStart = nil
            lock.unlock()
        }
        let now = ProcessInfo.processInfo.systemUptime
        let from = utteranceStart ?? (now - fallback)
        var peak: Float = -160
        var loudSum: Float = 0
        var loudCount = 0
        var loudSec = 0.0
        var totalSec = 0.0
        for sample in history where sample.time >= from {
            peak = max(peak, sample.db)
            totalSec += sample.duration
            if sample.db > thresholdDB {
                loudSum += sample.db
                loudCount += 1
                loudSec += sample.duration
            }
        }
        return SegmentStats(
            peakDB: peak,
            meanLoudDB: loudCount > 0 ? loudSum / Float(loudCount) : nil,
            loudSec: loudSec,
            totalSec: totalSec
        )
    }

    func clearHistory() {
        lock.lock()
        history.removeAll()
        utteranceStart = nil
        lock.unlock()
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
        history.append(LevelSample(time: now, db: db, duration: duration))
        if let first = history.first, now - first.time > historyWindow + 10 {
            history.removeAll { now - $0.time > historyWindow }
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
