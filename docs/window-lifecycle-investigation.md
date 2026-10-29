# 入力セッションに伴う不可視ウィンドウの生成・資源管理調査

調査日：2026年10月29日  
関連Issue：[azooKey-Desktop #348](https://github.com/azooKey/azooKey-Desktop/issues/348)  
状態：**解放漏れを示す証拠は得られていない。正常なセッション保持に伴う資源増加を主因とする仮説を検証中。**

## 背景と調査方針

azooKey-Desktop #348では、不可視ウィンドウが80枚、別環境では144枚存在し、WindowServerのCPU使用率も高かったと報告された。144枚の内訳は、`400×1000`が108枚、`360×310`が36枚であり、4枚単位の増加と一致する。報告者は解放漏れを疑っているが、入力セッションの生成数や終了時のウィンドウIDは追跡していない。なお、元Issueに関連して疑われていたデスクトップ切替不能の症状は、後に別アプリの問題と訂正されている。

**現時点の見解は、入力セッションの粒度が細かく、通常の使用でも多数のウィンドウが確保されるというものである。** 今回の実測ではタブ終了後の正常な解放を確認した。このため、まず既存仕様の下での資源消費を調べ、負荷が問題となる場合に限り、azooKeyのUI生成・所有方式を変更する妥当性を評価する。

## 関連技術と責任分担

### InputMethodKitの仕組みとazooKeyへの接続

[InputMethodKit](https://developer.apple.com/documentation/inputmethodkit)（IMK）は、macOSで日本語入力などの入力メソッドを実装するためのフレームワークであり、OSのText Services Managerと連携する。入力先アプリとの接続、入力イベント、未確定文字列、候補選択などを扱うためのAPIを提供する。変換アルゴリズムや候補画面の具体的なUIは、入力メソッドの実装が選択できる。

[`IMKServer`](https://developer.apple.com/documentation/inputmethodkit/imkserver)は、入力メソッド側でクライアントとの接続を受け付ける。Appleの[`IMKInputController`](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller)の説明によれば、クライアントアプリが作る入力セッションには、`IMKServer`が生成する入力コントローラが1つ対応する。`IMKInputController`はその基底クラスであり、入力イベントと変換後の文字列を取り扱う。

azooKeyでは、[`AppDelegate.applicationDidFinishLaunching`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/AppDelegate.swift)が`IMKServer(name:bundleIdentifier:)`を生成する。[`azooKeyMac/Info.plist`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/Info.plist)の`InputMethodConnectionName`は接続名を、`InputMethodServerControllerClass`は`azooKeyMacInputController`を指定する。`IMKServer`はこの設定からコントローラのクラスを特定する（[Appleの初期化仕様](https://developer.apple.com/documentation/inputmethodkit/imkserver/init%28name%3Abundleidentifier%3A%29)）。

`azooKeyMacInputController: IMKInputController`という宣言は、**azooKeyのクラスがIMKの基底クラスを継承する**ことを意味する。OS側が要求する`init(server:delegate:client:)`、`activateServer`、`deactivateServer`などの契機に応じて、入力イベントを`SegmentsManager`に伝え、クライアントの未確定文字列や候補表示を更新する。入力セッションごとにこのクラスのインスタンスが増えるため、その中で生成するオブジェクトもセッション数に比例する。

```text
Chrome等の入力先アプリ（編集コンテキスト）
  → macOSのテキスト入力基盤
  → IMKServer（azooKeyプロセスで接続を管理）
  → azooKeyMacInputController : IMKInputController（セッションごと）
      ├─ SegmentsManager（未確定文字列・個別の変換状態）
      │   └─ KanaKanjiConverter（エンジン本体はプロセス内で共有）
      └─ NSWindow × 4（現在はコントローラごとに確保）
          └─ WindowServerが管理するウィンドウ
```

Chromeのタブ・ページ・編集欄のどれが新しい入力セッションに対応するかは、IMKの公開仕様だけでは確定できない。今回の`init`ログから、Chromeの操作によって複数のコントローラが生成されることが分かる。

入力処理には、入力先アプリケーション、macOSの入力基盤、azooKey、およびウィンドウ管理機構が関与する。

### 入力セッションの生成から表示まで

| 要素 | 主な責任 | 今回の現象との関係 |
| --- | --- | --- |
| Chromeなどの入力先アプリケーション | 入力欄・編集コンテキストを管理し、macOSのテキスト入力機構と接続する | ページ遷移やタブの操作に伴い、入力セッションの生成・終了が変化する。Chrome内部のコンテキスト生成規則は未調査 |
| InputMethodKit（IMK） | `IMKServer`がクライアント接続を扱い、入力セッションごとに`IMKInputController`を生成する | 入力セッション数に応じてコントローラ数が増える。セッションの寿命と生成頻度に関与する |
| azooKey-Desktop | `IMKInputController`を継承し、変換状態、候補表示、プロンプト機能と各ウィンドウの所有を実装する | **コントローラを1つ生成するたびに4枚の`NSWindow`を確保する** |
| AppKit | `NSWindow`や`NSViewController`の表示・非表示、オブジェクトの所有関係を提供する | `orderOut()`は非表示にするだけで解放しない。ウィンドウの寿命は所有元と解放処理によって決まる |
| WindowServer・CoreGraphics | macOSのウィンドウを管理し、列挙用APIで状態を取得できるようにする | 不可視ウィンドウも一覧に含まれる。枚数と描画負荷は別の指標であり、CPU使用率との因果関係は未確定 |
| KanaKanjiConverter・Zenzai | かな漢字変換と推論を担う | UIウィンドウの所有とは独立する。今回、GGUFモデルの重複マッピングは確認されていない |

Appleの[InputMethodKit公式説明](https://developer.apple.com/documentation/inputmethodkit)は、クライアントが作成した入力セッションごとに`IMKServer`が`IMKInputController`を生成すると明記する。したがって、**セッション数の増加自体はIMKの設計と整合する**。一方、Chromeがタブ・ページ・編集欄のどの粒度でセッションを維持するかは、同説明からは決まらない。今回のログは、Chrome上で複数のセッションが生成されることを示している。

AppKitの[`NSWindow.orderOut(_:)`](https://developer.apple.com/documentation/appkit/nswindow/orderout%28_%3A%29)は、ウィンドウを隠すが解放しない。これは非アクティブ化のたびにウィンドウを再作成しないための通常のAPI動作である。[`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29)はWindowServerが管理するウィンドウの情報を返すため、`onscreen=false`のウィンドウが存在することだけでは残留を証明できない。

### azooKey固有の所有方式

[`azooKeyMacInputController.swift`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/InputController/azooKeyMacInputController.swift)では、`init`の際に`CandidatesViewController`、`PredictionCandidatesViewController`、`ReplaceSuggestionsViewController`を生成し、それぞれの`NSWindow`を作る。`makeCandidateWindow()`が設定する初期サイズは`400×1000`である。

同じ`init`で[`PromptInputWindow`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/Windows/PromptInput/PromptInputWindow.swift)も生成する。こちらはSwiftUIの入力画面を含む独自の`NSWindow`であり、観測した`360×310`のウィンドウに対応する。候補ウィンドウの実装にはIMK標準の`IMKCandidates`を必須とせず、独自のAppKitビューを採用している。

コントローラが保有するウィンドウは、`activateServer()`や`deactivateServer()`で表示状態を切り替える。コントローラが生存する間は、表示していないウィンドウも保持される。この**セッション単位で4枚を先行確保する方式はazooKey側の設計判断**であり、IMKが4枚のウィンドウを要求しているわけではない。

なお、変換器は[`AppDelegate.swift`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/AppDelegate.swift)で共有され、[`SegmentsManager.swift`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/Core/Sources/Core/InputUtils/SegmentsManager.swift)が変換セッションを個別に作成・破棄する。**UIのウィンドウ4枚とZenzaiのモデル4個は対応しない。**

### 同じ初期サイズのウィンドウを3枚生成する理由

**3枚は、それぞれ独立した候補表示機能に対応する。** [`azooKeyMacInputController.init`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/InputController/azooKeyMacInputController.swift)で次の3組の`NSViewController`と`NSWindow`を、用途ごとに生成する。

| 保持プロパティ | 表示する内容 | 表示契機 |
| --- | --- | --- |
| `candidatesWindow` | 通常のかな漢字変換候補 | `refreshCandidateWindow()`。選択中または入力中に候補を表示するとき |
| `predictionWindow` | 入力中の予測・補完候補 | `refreshPredictionWindow()`。`.composing`状態で予測候補があるとき |
| `replaceSuggestionWindow` | AIによる文章置換の候補 | `requestReplaceSuggestion()`。AIバックエンドを利用し、置換候補が返ったとき |

`makeCandidateWindow()`は共通の`candidateWindowInitialSize = 400×1000`を設定し、レベルを`.popUpMenu`に変更した後、`setIsVisible(false)`と`orderOut(nil)`で隠す。**400×1000は生成直後の共通初期サイズであり、実際の候補表示領域や最大サイズを意味しない。** このため、機能の異なる3枚がWindowServerの一覧では同じサイズ・レイヤーで現れる。

予測候補は通常候補と独立した`NSWindow`であり、`positionPredictionWindowRightOfCandidateWindow()`が両者の横並び表示を扱う。したがって、通常候補と予測候補は同時表示し得る。一方、置換候補には専用の`InputState.replaceSuggestion`と非同期AI処理があり、通常の変換とは異なる経路から`makeKeyAndOrderFront(nil)`で表示される。**3枚を同時生成する設計は意図的だが、3枚の同時表示が必要なわけではない。**

さらに、[`PromptInputWindow`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/Windows/PromptInput/PromptInputWindow.swift)を4枚目として生成する。SwiftUIを内包するこの画面はプロンプト入力時に使うため、通常の候補表示とは別の機能に属する。生成された4枚のIDとの対応から、観測された`360×310`のウィンドウをこのプロンプト用と識別できる。一方、ソースにある初期サイズは`360×200`で、`resizeWindowToContent()`の通常表示時の計算値は`360×324`である。観測した`360×310`との差は未解明であり、ウィンドウの実際の寸法をソースの定数だけで断定しない。

この構成は**azooKeyの現行コードに照らして想定どおり**であり、IMKが3枚の候補ウィンドウを生成する仕様ではない。IMKは[`IMKCandidates`](https://developer.apple.com/documentation/inputmethodkit/imkcandidates)も提供するが、その利用は任意である。azooKeyは候補リストを独自のAppKitビューで構築している。

特に文章置換用ウィンドウは、AI機能を利用しない入力セッションでも`init`時に確保される。ここには遅延生成の余地がある。ただし、3枚の機能を1枚に統合する場合は通常候補と予測候補の同時表示を維持する必要があり、実装が単純になるとは限らない。

## 検証方法

環境はmacOS 15.8.1、Apple Silicon、個人用ビルド（Bundle ID：`dev.kasano.inputmethod.azooKeyMac`）とした。診断ブランチ[`diagnostics/window-lifecycle-348`](https://github.com/Amatubamem/azooKey-Desktop/tree/diagnostics/window-lifecycle-348)は、`29aae1ee6c1b0309f4f9f9bcc33d9124d6ae07c8`から作成した。

コントローラの`init`、`inputControllerWillClose`、`deinit`を記録し、初期化時にはコントローラIDと4枚のウィンドウ番号を出力する。頻発する`activate`・`deactivate`は記録しない。所有ウィンドウは[`Tools/window-lifecycle-snapshot.swift`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/Tools/window-lifecycle-snapshot.swift)で列挙する。

```zsh
pid=$(pgrep -x azooKeyMac | head -n 1)
swift Tools/window-lifecycle-snapshot.swift "$pid" --ids

# 別のターミナルでコントローラの寿命を監視する
log stream --style compact \
  --predicate 'process == "azooKeyMac" AND eventMessage CONTAINS "[WindowLifecycle]"'

# メモリ負荷を記録する
ps -o pid,rss,vsz,etime,command -p "$pid"
vmmap -summary "$pid"
```

## 観測結果

### 新規セッションの資源確保

Chromeで新しいサイトや編集コンテキストを有効にすると、コントローラの`init`が実行され、不可視ウィンドウが4枚増えた。内訳は`400×1000 / layer 101`の3枚と、`360×310 / layer 3`の1枚であり、コード上の生成数・用途と一致する。

長時間稼働した別プロセスでは、所有ウィンドウを155枚観測した。内訳のうち`400×1000 / layer 101`が108枚、`360×310 / layer 3`が38枚だった。残るウィンドウには表示に応じてサイズが変わったものも含まれるため、単純な総数だけから保持中のコントローラ数は確定できない。

### タブ終了時の解放

同じazooKeyプロセス（PID 14545）について、サイトを開く前後とタブ終了後を比較した。

| 状態 | 総ウィンドウ数 | 400×1000 | 360×310 |
| --- | ---: | ---: | ---: |
| 開く前 | 28 | 21 | 7 |
| 開いた後 | 32 | 24 | 8 |
| タブ終了後 | 28 | 21 | 7 |

開いた際に生成された`51910`、`51911`、`51912`、`51913`は、タブ終了後にすべて一覧から消えた。対応するコントローラの`deinit`も観測した。Chrome自体を終了した際にも`deinit`が発生した。

### メモリに関する観測範囲

別の長時間稼働プロセスでは、`vmmap`に表示されたGGUFモデルのマッピングは1件だった。Physical footprintは400.6 MB、稼働中のピークは579.8 MBだった。CoreAnimationやIOSurfaceの領域も存在するが、単一時点の測定ではセッション数に比例する実メモリ負荷や継続的な増加率を求められない。

## 考察と設計上の判断

### 現象は仕様に沿った資源増加と考えられる

**現段階では、セッションの粒度が細かいために正常な使用でも多数のウィンドウが作成される、という解釈を採る。** 入力セッションごとにコントローラを生成するIMKの仕様と、コントローラごとにウィンドウを4枚確保するazooKeyの設計が、観測した4枚単位の増減を説明する。実際にタブ終了時の`deinit`とウィンドウの解放を確認した。

上流Issue #348のウィンドウ数と4枚単位の内訳も、この説明と整合する。既存報告には終了済みセッションのIDと残留ウィンドウIDを照合した結果がなく、リークを示す証拠は得られていない。一方、WindowServerの高CPU使用率は実際に報告されており、その原因・資源消費の妥当性は独立して検証する必要がある。

**本件は、現状ではリーク修正よりも資源管理の設計上のトレードオフとして扱うのが妥当と考える。** セッションの粒度そのものは入力先アプリやIMKの管理に関わるため、azooKeyが直接統一できるものではない。ウィンドウ数を減らす場合は、azooKeyのウィンドウ生成時期や所有単位を変更することになる。

### 資源削減にはUIの設計変更が伴う

| 方針 | 資源の持ち方 | 利点と代償 |
| --- | --- | --- |
| 現行方式を維持 | 各コントローラの`init`時に4枚生成する | 表示時に既存ウィンドウを再利用できる。セッション数に比例して資源が増える |
| 遅延生成 | 候補・予測・プロンプトの各機能を初めて使用するときに生成する | 未使用機能のウィンドウを省ける。初回表示の応答、生成契機、破棄処理を再検証する必要がある |
| ウィンドウ共有 | IMEプロセス内で表示用ウィンドウを共有する | セッション数に比例した生成を減らせる。アクティブなコントローラへの表示内容・デリゲート・フォーカスの切替が必要になる |
| 非アクティブ時に破棄 | セッションを保持したまま表示用ウィンドウを解放・再生成する | 非使用時の保持量を減らせる。頻繁な切替時の生成コストとUI状態の復元が増える |

いずれの方法も、**アプリケーション内部の所有方式や表示時の振る舞いを変える**。ウィンドウの共有は、入力セッション間の状態分離や候補選択の帰属に影響する。遅延生成も初回表示時の遅延を生むおそれがある。削減できるメモリ量やWindowServer負荷が未測定の段階では、どの変更が妥当か判断できない。

### 比較対象としてのmacOS標準IME

標準IMEにも入力コンテキストに応じた状態の管理が必要だが、`IMKInputController`や`NSWindow`の利用方法、プロセス間の役割分担は確認していない。標準IMEでも同種の資源増加が起こり得る一方、具体的なウィンドウ枚数は実装方式に左右される。比較ではプロセス構成を先に調べ、ウィンドウ数だけでなく物理メモリ・CPU負荷を同一操作条件で測定する。

## WindowServerのCPU・メモリ負荷を調べる実験設計

### 目的と仮説

検証するのは、**入力セッション数に比例したウィンドウの保持が、WindowServerとazooKeyの負荷をどの程度増やすか**である。以下の仮説を分けて扱う。

1. **生成・解放の規則性**：同時に生存するコントローラが1個増えると、未使用の候補ウィンドウを含めて原則4枚増える。`deinit`後には4枚減る。
2. **保持時の負荷**：表示していないウィンドウが多いほど、WindowServerのCPU使用率やメモリ使用量が増える。増加しなければ、枚数だけでは対策の根拠にならない。
3. **IME固有の寄与**：同じChrome操作で、azooKeyと標準日本語入力を比べたときに負荷の増加量が異なる。

これらは独立に検証する。ウィンドウ数が増えたという観測から、CPU負荷やメモリ使用量も増えたとは推定しない。

### 比較条件と操作

Chromeの同一ローカルHTMLページに`textarea`を1個だけ設け、タブを複製する。**入力セッションの生成には、入力可能な要素へのフォーカスが必要である。** タブ作成のみでは`init`の発生を保証できないため、各タブを前面に表示し、画面中央を占める`textarea`を自動クリックする。クリック後のazooKeyウィンドウ数が増加したことを検証してから次のタブへ進む。追加が確認できない場合はクリックを再試行し、それでも増えなければ測定を中止する。各タブの表示はその後静止させ、**不可視ウィンドウを保持した状態の待機時負荷**を測る。

| 条件 | 比較対象 | 操作 |
| --- | --- | --- |
| A | azooKey | 基準状態からタブを段階的に追加する。追加数の目安を0、5、10、20とし、実際の`init`件数を記録する |
| B | Apple標準日本語入力 | Aと同じChromeのページ、タブ操作、待機時間を再現する |
| C | azooKey | Aで追加したタブを段階的に閉じ、`deinit`件数と負荷の回復を確認する |

AとBでは、Chrome自身のタブ・レンダラによる負荷も変わる。両者を同一条件で比較してIME固有の差を推定する。ただし標準IMEは内部のプロセス構成が異なる可能性があるため、所有ウィンドウ数の直接比較だけで評価しない。

各段階では、ページ表示と入力ソースの切替を終えてから**少なくとも60秒待機し、その後60秒程度を計測**する。macOSの`ps`が返す`%CPU`は直近約1分までの減衰平均を含むため、操作直後の負荷を次の待機時測定に持ち込まない。操作順序による影響を避けるため、AとBの実施順を入れ替えながら各条件を最低3回繰り返す。画面解像度、外部ディスプレイ、リフレッシュレート、前面のタブ、電源状態、起動中のアプリを固定し、動画・アニメーション・通知を避ける。

### 計測する指標と取得方法

| 指標 | 取得方法 | 解釈上の注意 |
| --- | --- | --- |
| azooKeyの所有ウィンドウ数、サイズ、ID | `window-lifecycle-snapshot.swift --ids` | 生存中のウィンドウ数を測る。CPU・物理メモリの代理指標とはしない |
| azooKeyコントローラの生成・破棄 | `[WindowLifecycle]`ログ | 実際のセッション数に対応付け、タブ数と混同しない |
| WindowServerのCPU使用率 | `ps -p <PID> -o %cpu`を継続記録 | 直近の使用率を表す近似値。単一時点でなく分布と中央値を比較する |
| WindowServerのRSS | `ps -p <PID> -o rss`、アクティビティモニタ | RSSは共有領域等を含む。GPU資源や正確な増分費用を単独では表さない |
| azooKeyのRSS・Physical footprint | `ps`、`vmmap -summary` | RSSとPhysical footprintを区別する。後者は各段階の前後で取得する |
| CoreAnimation・IOSurface | azooKeyに対する`vmmap -summary` | ウィンドウ数と領域の増減を併記する。領域の仮想サイズを物理消費量とみなさない |
| システム全体のメモリ状態 | アクティビティモニタのメモリプレッシャー・スワップ使用量 | WindowServer単体の負荷とシステム全体の状態を区別する |

実験用スクリプト[`Tools/windowserver-benchmark.sh`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/Tools/windowserver-benchmark.sh)は、Chromeの**専用ウィンドウだけ**をAppleScriptで操作する。画面中央を占める入力欄のあるローカルHTMLページを自動生成し、タブを段階的に追加する。各タブの入力欄を`System Events`から**明示的にクリック**し、実測したウィンドウ数の増加を確認する。操作後の待機・計測・ウィンドウ枚数の記録・タブの削除まで実行する。既存のChromeウィンドウは操作しない。作成した専用ウィンドウは正常終了時にも異常終了時にも可能な限り閉じる。

```zsh
git switch diagnostics/window-lifecycle-348
git pull --ff-only
bash Tools/windowserver-benchmark.sh

# 試運転用：待機・計測を各10秒に短縮する
SETTLE_SECONDS=10 DURATION_SECONDS=10 TAB_STEPS="2 4" \
  bash Tools/windowserver-benchmark.sh
```

既定の測定は`tabs_0`→`tabs_5`→`tabs_10`→`tabs_20`→`tabs_closed`の5段階で行う。各段階で60秒待機した後、約60秒間、2秒間隔でWindowServerとazooKeyの`%CPU`・RSSを記録する。生成される`metrics.csv`、`phases.csv`、各段階のウィンドウID一覧、`vmmap`は実行時に表示する専用の一時ディレクトリへ保存する。`phases.csv`に記録されるのは実測したウィンドウ数であり、タブ数とコントローラ数を同一視しない。

**実行前にmacOSの入力ソースをazooKeyへ切り替える。** 初回はターミナルからGoogle Chromeを操作する自動化権限と、`System Events`によるキー入力のアクセシビリティ権限が要求される場合がある。入力ソースの切替自体は自動化していない。クリックはChromeウィンドウの中央座標で実行するため、ブラウザが通常のサイズで前面に表示され、入力欄を覆うダイアログがないことを前提とする。クリック後のウィンドウ増加は`init`発生の間接的な指標であり、必要に応じてライフサイクルログで裏付ける。各タブで増加しなかった場合は実験を中断するため、タブ数をそのまま入力セッション数として扱わない。

`ps`の`%CPU`は厳密な2秒間平均ではないため、まず条件間の概略比較に使う。CPUの時間変化を詳しく検証する場合はmacOSの`top -l`による連続採取やInstrumentsを併用する。WindowServerは保護されたプロセスのため、`vmmap`による詳細取得が権限上できない場合がある。その場合はアクティビティモニタの表示値を併記し、推測で補わない。

### 判定と追加実験

各条件で安定待機時のCPU使用率の中央値、RSSの前後差、ウィンドウ枚数、`init−deinit`の累積差を対応付ける。WindowServerのCPUはOS全体の描画処理にも左右されるため、**同一IME内の増分と標準IMEとの差分**を併記する。増加・減少を繰り返した際の回復も、リークと一時的なキャッシュ・正常保持を区別する材料になる。

保持時に明確な負荷があれば、次に診断用ビルドで「同数の入力セッションを保持したまま、候補ウィンドウの生成方式だけを変える」対照実験を行う。これにより、ChromeのタブやIMKのセッションそのものによる負荷と、azooKeyが先行確保する`NSWindow`の負荷を切り分ける。UIを省略する検証ビルドは機能上の互換性を保証しないため、診断用途に限定する。

### macOSセルフホストランナーでの実行状況（2026-10-29）

[診断ブランチ上のmacOS専用Workflow](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/.github/workflows/windowserver-smoke.yml)を作成し、`azooKey-Desktop`リポジトリに登録された`asanoMBPro`（macOS 15.8.1、ユーザー`kasano`）で短時間のスモークテストを2回実行した。

- [初回実行](https://github.com/Amatubamem/azooKey-Desktop/actions/runs/40884828882)：ランナー接続、checkout、Bashの構文検査に成功した。入力欄をクリックしても計測用スクリプトがウィンドウの増加を検出できず、負荷測定前に停止した。
- [GUI環境の追加診断](https://github.com/Amatubamem/azooKey-Desktop/actions/runs/40885141263)：`azooKeyMac`（PID 17672）、WindowServer（PID 432）、Chromeのウィンドウ3枚、前面アプリChrome、選択中の入力ソース`dev.kasano.inputmethod.azooKeyMac.Japanese`を確認した。一方、同じランナーから`CGWindowListCopyWindowInfo(.optionAll, ...)`を呼ぶと**全アプリを合わせて0枚**だった。

**現状の障害は、ランナーからCoreGraphicsのウィンドウ一覧を取得できないことである。** 0枚は実際にウィンドウが存在しないことを意味しない。ランナーのLaunchAgentによるGUIセッションへのアクセス、画面収録に関するTCC権限、実行プロセスの権限を切り分ける必要がある。AppleScriptによるクリック自体はエラーを出していないが、入力欄へのフォーカスと新規`IMKInputController.init`の成立は未確認である。

現在のスモークテストは、実際のウィンドウ増加を検証できなければ中断する。そのため、有効な負荷比較結果はまだ得られていない。次は対話的なターミナルとLaunchAgentの双方から同じCoreGraphics列挙を行い、取得件数を比較する。実行環境の差異を解消してから、タブ追加による4枚単位の増減試験を再実施する。

## 次のタスク

- [ ] **標準IMEとの比較**：同じChrome操作で、日本語標準入力の関連プロセス・ウィンドウ数・Physical footprint・WindowServer負荷を調べる。
- [ ] **入力セッションの寿命を追跡**：タブ開閉、ページ遷移、複数アプリ間の移動で`init`・`willClose`・`deinit`を照合し、終了済みセッションに属するウィンドウの残留が再現するか確認する。
- [ ] **セッション数と負荷の関係を測定**：本書の条件A～Cを実行し、コントローラ数・ウィンドウ数に対するPhysical footprint、CoreAnimation・IOSurface、WindowServerのCPU・RSSの増分と回復を確認する。
- [ ] **仕様変更の要否を判断**：実測した負荷と初回表示性能を評価し、現行維持、遅延生成、共有、非アクティブ時破棄の費用対効果を比較する。
- [ ] **上流Issueへの共有**：再現条件と測定結果に基づき、[azooKey-Desktop #348](https://github.com/azooKey/azooKey-Desktop/issues/348)に現象の解釈と改善の必要性を報告する。

調査が進んだ場合は、本メモに測定条件、増分、解釈の変更理由を追記する。
