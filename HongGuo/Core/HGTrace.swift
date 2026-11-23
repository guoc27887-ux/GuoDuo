import Foundation
import QuartzCore

/// 播放切换计时（真机排查卡顿用）：写到 Documents/hg-trace.log，devicectl 拉回来看
enum HGTrace {
    private static let q = DispatchQueue(label: "hg.trace")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("hg-trace.log")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    static func log(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: url) }
        }
    }
}
