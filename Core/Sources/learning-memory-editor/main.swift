import Core
import Foundation

// 学習データの編集は、azooKeyの設定画面（学習 → 履歴学習データ → 編集）で行う。
let usage = """
使い方:
  learning-memory-editor dump [--memory <dir>] > memory.tsv
      学習データをTSVで標準出力に書き出す
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var memoryURL = AppGroup.memoryDirectoryURL()
if let index = arguments.firstIndex(of: "--memory") {
    guard index + 1 < arguments.count else {
        fail(usage)
    }
    memoryURL = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    arguments.removeSubrange(index ... index + 1)
}

guard arguments.first == "dump" else {
    fail(usage)
}
do {
    print(LearningMemoryEditor.tsv(try LearningMemoryEditor.load(directoryURL: memoryURL)), terminator: "")
} catch {
    fail("エラー: \(error)")
}
