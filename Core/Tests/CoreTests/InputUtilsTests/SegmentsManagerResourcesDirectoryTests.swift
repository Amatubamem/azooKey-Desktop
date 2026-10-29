@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Bundle.main.resourceURLと同じ相対URLを与えても、Zenzaiのモデルを絶対パスで開けることを確認する。
@MainActor
@Test func resourcesDirectoryURLResolvesRelativeBundleResourceURL() throws {
    let bundleURL = URL(fileURLWithPath: "/Library/Input Methods/azooKeyMac.app", isDirectory: true)
    let relativeResourceURL = try #require(URL(string: "Contents/Resources/", relativeTo: bundleURL))
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        containerURL: nil,
        context: .init(useZenzai: true, resourcesDirectoryURL: relativeResourceURL)
    )
    let weightURL = manager.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false)
    #expect(weightURL.path(percentEncoded: false) == "/Library/Input Methods/azooKeyMac.app/Contents/Resources/ggml-model-Q5_K_M.gguf")
}
