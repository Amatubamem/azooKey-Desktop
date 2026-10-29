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

4. 衝突を解消する。個人用の署名設定、App Group、入力ソースのIDを維持する。
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

## 不可視ウィンドウ蓄積の検証（#348、一時的な診断）

検証ブランチ `diagnostics/window-lifecycle-348` では、`azooKeyMacInputController` の初期化（`init`）・入力セッションの終了通知（`willClose`）・破棄（`deinit`）の際に `[WindowLifecycle]` のログを出力する。初期化時はコントローラIDと候補・予測・置換候補・プロンプトの各ウィンドウ番号を記録する。入力文字列や入力先アプリの情報は記録しない。診断用変更であり、製品版へ取り込むものではない。

1. ブランチをチェックアウトし、必要なら `./update.sh` でビルド・インストールする。現在のプロセスは再起動されるため、PIDは更新後に取得する。
2. 以下で初期状態のウィンドウ数とウィンドウ番号を記録する。
3. テキストエディットやブラウザなど、複数アプリの入力欄を切り替えて同じ測定を繰り返す。
4. `init` / `willClose` / `deinit` のログとウィンドウ番号を比較し、入力セッションの終了通知とオブジェクト解放、ウィンドウ残留を区別する。`activate` / `deactivate` は頻繁に呼ばれるため記録しない。

```zsh
pid=$(pgrep -x azooKeyMac | head -n 1)
swift Tools/window-lifecycle-snapshot.swift "$pid"
swift Tools/window-lifecycle-snapshot.swift "$pid" --ids

# 別のターミナルで実行し、アプリを切り替えながら観察する。
log stream --style compact --predicate 'process == "azooKeyMac" AND eventMessage CONTAINS "[WindowLifecycle]"'
```

`400x1000 layer=101` が3枚ずつ増える場合は、候補・予測・置換候補の3ウィンドウを生成する入力コントローラの増加と整合する。アクティブ化のたびに既存コントローラが再利用されるか、別のコントローラが生成されるかをログで判別する。`willClose` が発生しない場合は入力セッションの終了通知自体が未到達である可能性、`willClose` が発生して `deinit` が遅れる場合は終了後の保持が続いている可能性を検討する。なお、`deinit` がすぐに発生しないことだけではリークと断定できない。IMKitやAppKitの正常な保持・再利用との切り分けが必要である。

## 動作確認

| 確認項目 | 方法 | 期待する結果 |
|---|---|---|
| Zenzaiの読込 | 日本語を1回変換してから`lsof -Fn -p $(pgrep -x azooKeyMac) \| grep gguf`を実行する | ggufのパスが表示される |
| 権限の確認ダイアログ | IMEを起動した後に`/usr/bin/log show --last 5m --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "AUTHREQ_PROMPTING" AND eventMessage CONTAINS "azooKey"'`を実行する | 何も表示されない |

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
