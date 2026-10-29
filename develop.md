# 開発メモ：正式版との差分と更新手順

本書は、正式版（azooKey/azooKey-Desktop）との差分と、独自版のビルド・更新手順を記録する。`README.md`は正式版の説明を保ち、独自実装の仕様と検証記録は本書に集約する。

## 基準となる版

| 項目 | 値 |
|---|---|
| 正式版のリポジトリ | https://github.com/azooKey/azooKey-Desktop |
| 作業ブランチ | `develop` |
| 取り込み済みの正式版 | `dd74a6e`（`upstream/main`、2026-10-21） |
| 署名 | Personal Team（Team ID：`UAWNATHM2X`） |

## 正式版との差分

識別子・署名の設定と、ソース・ビルドの変更を別のコミットとして管理する。正式版の更新は、個人用の設定を保ちながら`develop`へマージする。

| コミットの分類 | 内容 | 取り込み時の扱い |
|---|---|---|
| `chore(local)` | Personal Team向けの署名と識別子を変更する | 独自版の署名・バンドルID・App Group・設定キーを維持する |
| `build(local)` | 独自版のビルドとインストールを整える | 個人用の設定を維持し、正式版で修正済みの対処は取り除く |
| `feat(memory)` | 学習データの閲覧・編集と、TSVの書き出しを追加する | データを保全し、並べ替え時の選択を維持する |

### Zenzaiのモデルのパス

`Bundle.main.resourceURL`は相対URLのため、変換エンジンが`path(percentEncoded:)`で開くと相対パスになり、IMEがZenzaiのモデルを読み込めなかった。正式版のコミット`7ab7821`（#335）で混入した。

モデルパスの修正を除き、`resourcesDirectoryURLResolvesRelativeBundleResourceURL`を実行する。正式版で修正済みなら、独自版のモデルパスの修正を取り除ける。

### Personal Team向けの設定

正式版のバンドルID`dev.ensan.inputmethod.azooKeyMac`を、`dev.kasano.inputmethod.azooKeyMac`に置換した。`azooKeyMac.xcodeproj/project.pbxproj`の開発チームも、`UAWNATHM2X`に変えた。識別子と設定キーは、以下のファイルで変更した。

- 設定キー：`Core/Sources/Core/Configs/`、`azooKeyMac/Configs/SecureConfigItem.swift`
- 入力モードID：`azooKeyMac/Info.plist`、`azooKeyMac/InputController/azooKeyMacInputController.swift`
- パッケージID：`distribution.xml`、`pkgbuild.sh`
- 変換器の削除用ツール：`Tools/remove_converter_server_launch_agent.sh`

正式版で設定キーやファイルが増えた場合は、新しい箇所に`dev.ensan`が残る。取り込んだ後に、「正式版を取り込む手順」の5で置換漏れを確かめる。

`azooKeyMac/Info.plist`はXcodeが書き直したため、差分が大きい。衝突した場合は正式版の内容を採用し、`TISInputSourceID`などに含まれる`dev.ensan`を`dev.kasano`に置換する。

### App Groupの識別子

Personal Teamのプロビジョニングプロファイルは、`group.`で始まるApp Groupを認可しない。macOS 15は認可されていないApp Groupのコンテナを他のアプリのデータとして保護し、IMEが起動するたびに確認ダイアログを表示する。Team IDで始まる識別子`UAWNATHM2X.dev.kasano.inputmethod.azooKeyMac`は、署名だけで認可される。

識別子を変えると、学習データと設定の保存場所も変わる。変更したファイルは、以下のとおりである。

- `Core/Sources/Core/Configs/AppGroup.swift`
- `azooKeyMac/azooKeyMac.entitlements`
- `Core/Tests/CoreTests/ConfigsTests/AppGroupTests.swift`

### 学習データの編集画面

設定画面の「学習」にある「履歴学習データ」の「編集」から、学習データを検索し、選択した項目を削除できる。IMEの変換器`KanaKanjiConverter`で直接削除するため、IMEを再起動せずに直後の変換から反映される。`learning-memory-editor dump`は、学習データをタブ区切りのTSVに書き出す。

追加・変更したファイルは、以下のとおりである。

| ファイル | 役割 |
|---|---|
| `Core/Sources/Core/LearningMemory/LearningMemoryEditor.swift` | 学習データを読み込み、削除を計画して適用する |
| `azooKeyMac/Windows/LearningMemoryEditorWindow.swift` | 編集画面を構成する |
| `azooKeyMac/Windows/LearningMemoryTable.swift` | 表示中のセルを再描画する |
| `azooKeyMac/AppDelegate.swift` | `openLearningMemoryEditorWindow`で編集画面を開く |
| `azooKeyMac/Windows/ConfigWindow.swift` | 「編集」ボタンを配置する |
| `Core/Sources/learning-memory-editor/main.swift`、`Core/Package.swift` | 書き出し用のCLIを提供する |
| `Core/Tests/CoreTests/LearningMemoryTests/LearningMemoryEditorTests.swift` | 読み込み、削除、復元を検証する |
| `azooKeyMacTests/LearningMemoryTableTests.swift` | 並べ替え、選択、列幅、複数選択、Deleteキーを検証する |

読込では、学習データのファイル（`memory.memorymetadata`と`memoryN.loudstxt3`）を直接読み取る。書込では、`createSession`で生成した専用のセッションで、変換エンジンの公開APIを呼ぶ。`requestCandidates`で保存先と学習方式を指定し、`forgetMemory`で削除する。復元と保存には、`updateLearningData`と`commitUpdateLearningData`を呼ぶ。

削除には入力処理と同じ変換器を使う。削除の前後で学習データを保存し、削除の結果を確認する。画面を閉じる際には、削除結果のメッセージを消す。

削除する候補と表記が同じ候補は、再登録後に使用回数・最終使用日・最終更新日・順位スコアを元に戻す。復元時の保存では、エンジンと同じ `.2` ファイルと `.pause` による復旧手順を使う。

#### 一覧の並べ替え

約15,000件の学習データを「読み」または「表記」で並べ替えると、約10秒待つとの報告を受け、表示処理を変更した。変更前は、画面の再評価ごとに`shownEntries`が全件をソートしていた。件数表示とテーブルからの呼び出しが重複し、SwiftUIの行の移動処理にも時間を費やしていた。

ソートは読み込み時と条件の変更時に1回だけ行い、検索では並べ替え済みの配列を絞り込む。選択やメッセージの変更時にはソートしない。文字列の比較には`.localizedStandard`を使う。

テーブルには`NSTableView`を使い、表示中のセルを再描画する。選択には既存の項目IDを使う。再描画中には選択変更を通知せず、並べ替えた後に選択位置を復元する。テーブルを作り直さず、ユーザーが調整した列幅も保つ。

ソート結果を保存するだけではSwiftUIの行の移動処理が残るため、`NSTableView`を採用した。並べ替えに伴う変更は表示処理に限り、学習データの読み書きと保存形式は維持した。

2026-10-23の検証では、製品コードのテーブルを組み込んだ再現用の画面で15,329件の表記を並べ替えた。ソート本体は約0.416秒、画面更新を含む待ち時間は約0.468秒だった。項目のモデルは検証用に差し替え、学習データはCLIでメモリ上に読み取った。学習データの本文はログやファイルへ保存していない。

同日の記録では、`LearningMemoryTableTests`、macOS向けのReleaseビルドが成功した。変更したSwiftファイルのSwiftLint検査と`git diff --check`も成功した。計測は再現用の画面によるものであり、再インストール後のIMEの操作時間は確認していない。

#### 学習データ管理の検証

変換エンジンを更新した場合は、学習データ管理のテストを実行する。`dump`でも、ファイル形式とAPIが変わっていないことを確かめる。

```zsh
swift test --package-path Core --filter learningMemoryEditor
swift build --package-path Core -c release --product learning-memory-editor
Core/.build/release/learning-memory-editor dump > ~/Desktop/memory.tsv
```

並べ替えや選択の処理を変更した場合は、Xcodeで`LearningMemoryTableTests`も実行する。

### クリーンインストールと登録後の更新

`install.sh`はupstreamと同じ処理を使用する。`clean archive`でクリーンビルドし、インストール先のアプリを削除してから複製する。初回導入とクリーンインストールし直す場合に利用する。再ログインが必要になる場合がある。

`update.sh`は登録済みアプリを更新する。`build/DerivedData`のキャッシュを再利用してRelease構成で差分ビルドし、バンドルIDの一致を確認する。`rsync -rlpt --delete`でアプリのディレクトリを残して中身を更新し、`Tools/register_input_source.swift`で入力ソースを再登録する。`-l`でシンボリックリンクを維持する。

2026-10-21には同種の更新処理で、再ログインせずにIMEを選択できた。`update.sh`に分離した後の実機検証は実施していない。

### 独自版のビルドとインストール

依存ファイルの取得と開発環境の準備は、`README.md`の開発ガイドに従う。独自版をビルドするには、Xcodeで署名設定、Team、バンドルIDを確認する。

リポジトリのルートで用途に応じて実行する。

```zsh
./install.sh  # 初回導入またはクリーンインストール
./update.sh   # 登録済みのアプリの更新
```

`update.sh`は`xcodebuild build`に`-configuration Release`、`-destination 'generic/platform=macOS'`、`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`を指定する。ビルド結果とキャッシュは`build/DerivedData`に保存し、`build/DerivedData/Build/Products/Release/azooKeyMac.app`を配置する。

更新用のビルドキャッシュを削除する場合は以下を実行する。

```zsh
xcodebuild -project azooKeyMac.xcodeproj -scheme azooKeyMac -derivedDataPath build/DerivedData clean
./update.sh
```

Git情報の生成処理はupstreamに合わせて戻した。生成する内容が変化しなくてもファイルを更新するため、更新のたびに関連部分が再コンパイルされる場合がある。

`update.sh`の`--dry-run`はビルド後に更新コマンドを表示し、`--ignore-lint`はSwiftLintの検査を省く。`--no-pkill`は既存のazooKeyMacプロセスを終了させない。`install.sh`のオプションはupstreamと同一である。

## 正式版を取り込む手順

1. 学習データをバックアップする。

   ```zsh
   cp -Rp "$HOME/Library/Group Containers/UAWNATHM2X.dev.kasano.inputmethod.azooKeyMac/Library/Application Support/azooKey/memory" ~/azookey-memory-backup-$(date +%Y%m%d)
   ```

2. `git status`で、作業ツリーに未コミットの変更がないことを確かめる。
3. 正式版を取得して、`develop`へマージする。

   ```zsh
   git fetch upstream --tags
   git switch develop
   git merge upstream/main
   ```

4. 衝突を解消する。個人用の署名設定、App Group、入力ソースのID、TSVの書き出しを維持する。
5. アプリと設定に含まれる識別子の置換漏れを確かめる。置換漏れがない場合、2つのコマンドの出力は空になる。

   ```zsh
   git grep -n "dev\.ensan" -- Core/Sources azooKeyMac Tools distribution.xml pkgbuild.sh
   git grep -n "group\.dev\." -- Core/Sources azooKeyMac
   ```

6. テストを実行し、SwiftLintでコードを検査する。プロジェクトを移動した後は、絶対パスを含む`Core/.build`を退避してから実行する。

   ```zsh
   swift test --package-path Core
   swiftlint lint --strict
   ```

7. `./update.sh`を`sudo`なしで実行し、登録済みのアプリを差分ビルドして更新する。
8. 「動作確認」の項目で動作を確かめる。
9. 本書の「基準となる版」と「正式版との差分」を更新する。

## 動作確認

| 確認項目 | 方法 | 期待する結果 |
|---|---|---|
| Zenzaiの読込 | 日本語を1回変換してから`lsof -Fn -p $(pgrep -x azooKeyMac) \| grep gguf`を実行する | ggufのパスが表示される |
| 権限の確認ダイアログ | IMEを起動した後に`/usr/bin/log show --last 5m --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "AUTHREQ_PROMPTING" AND eventMessage CONTAINS "azooKey"'`を実行する | 何も表示されない |
| 学習データの編集 | 設定画面の「履歴学習データ」の「編集」で項目を削除し、続けて削除した項目の読みを変換する | 削除した表記が候補に出ない |

## データの保存場所

| データ | 場所 |
|---|---|
| 学習データとユーザ辞書 | `~/Library/Group Containers/UAWNATHM2X.dev.kasano.inputmethod.azooKeyMac/Library/Application Support/azooKey/memory` |
| 設定 | `~/Library/Group Containers/UAWNATHM2X.dev.kasano.inputmethod.azooKeyMac/Library/Preferences/UAWNATHM2X.dev.kasano.inputmethod.azooKeyMac.plist` |
| カスタム入力表 | `~/Library/Containers/dev.kasano.inputmethod.azooKeyMac/Data/Library/Application Support/azooKeyMac/CustomInputTable/custom_input_table.tsv` |
| 旧App Groupのデータ（2026-10-21まで使用） | `~/Library/Group Containers/group.dev.kasano.inputmethod.azooKeyMac` |
| 正式版のデータ | `~/Library/Containers/dev.ensan.inputmethod.azooKeyMac` |

旧App Groupのデータと正式版のデータは、移行元として残してある。

## 注意事項

- 無料のPersonal Teamのプロビジョニングプロファイルは7日で失効する。失効後にIMEが起動しなくなった場合は、`./update.sh`で再ビルドする。
