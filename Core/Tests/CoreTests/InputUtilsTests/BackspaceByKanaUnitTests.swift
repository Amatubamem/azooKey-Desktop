@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private struct KanaDeletionScenario {
    let keys: String
    let style: InputStyle
    let before: String
    let after: String
}

@MainActor
@Test func backspaceDeletesLastKanaConversionUnit() {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let scenarios: [KanaDeletionScenario] = [
        .init(keys: "xp", style: .mapped(id: .defaultAZIK), before: "しょう", after: ""),
        .init(keys: "kz", style: .mapped(id: .defaultAZIK), before: "かん", after: ""),
        .init(keys: "ds", style: .mapped(id: .defaultAZIK), before: "です", after: ""),
        .init(keys: "kya", style: .mapped(id: .defaultAZIK), before: "きゃ", after: ""),
        .init(keys: "kaxp", style: .mapped(id: .defaultAZIK), before: "かしょう", after: "か"),
        .init(keys: "kaxpk", style: .mapped(id: .defaultAZIK), before: "かしょうk", after: "かしょう"),
        .init(keys: "shou", style: .roman2kana, before: "しょう", after: "しょ")
    ]

    for scenario in scenarios {
        let manager = SegmentsManager(
            kanaKanjiConverter: converter,
            applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            containerURL: nil,
            context: .init(useZenzai: false)
        )
        manager.insertAtCursorPosition(scenario.keys, inputStyle: scenario.style)
        #expect(manager.convertTarget == scenario.before,
                "入力: \(scenario.keys)")
        manager.deleteBackwardFromCursorPosition()
        #expect(manager.convertTarget == scenario.after,
                "Backspace後: \(scenario.keys)")
    }
}
