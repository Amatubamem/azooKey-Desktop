// インストールしたIMEを入力ソースとして登録し、日本語入力モードを選択する。
// 登録しないと、アプリを入れ替えた後にメニューバーやCtrl+Spaceの候補に現れないことがある。
// 使い方: swift Tools/register_input_source.swift "/Library/Input Methods/azooKeyMac.app"
import Carbon

guard CommandLine.arguments.count == 2,
      let bundleID = Bundle(path: CommandLine.arguments[1])?.bundleIdentifier else {
    print("使い方: swift register_input_source.swift <IMEの.appのパス>")
    exit(1)
}
let status = TISRegisterInputSource(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL)
guard status == noErr else {
    print("入力ソースを登録できません（OSStatus \(status)）")
    exit(1)
}
let modeID = "\(bundleID).Japanese"
let query = [kTISPropertyInputSourceID as String: modeID] as CFDictionary
guard let source = (TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource])?.first else {
    print("入力ソースが見つかりません: \(modeID)")
    exit(1)
}
TISEnableInputSource(source)
TISSelectInputSource(source)
print("入力ソースを登録し、選択しました: \(modeID)")
