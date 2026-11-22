import Foundation

/// 検証ログ。画面表示用のメモリ上リストと、Documents 配下のファイル（タブ区切り）の両方に書く。
/// 音声データそのものは記録しない（音量レベル等のメタ情報のみ）。
/// メインスレッドから呼ぶこと。
final class EventLogger: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    let fileURL: URL

    private let maxInMemory = 500
    private let fileQueue = DispatchQueue(label: "poc.bgmic.logger")
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.dateFormat = "yyyyMMdd-HHmmss"
        fileURL = docs.appendingPathComponent("bgmic-\(nameFormatter.string(from: Date())).tsv")
        FileManager.default.createFile(atPath: fileURL.path, contents: "time\tcategory\tmessage\n".data(using: .utf8))
    }

    func log(_ category: String, _ message: String) {
        let entry = Entry(date: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxInMemory {
            entries.removeFirst(entries.count - maxInMemory)
        }

        let line = "\(timestampFormatter.string(from: entry.date))\t\(category)\t\(message)\n"
        NSLog("[BgMicPoC] %@ %@", category, message) // Windows では idevicesyslog 等で確認可能
        let url = fileURL
        fileQueue.async {
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
