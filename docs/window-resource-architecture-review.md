# azooKey-Desktopの不可視ウィンドウ保持に関する設計調査と改善提案

調査日：2026-10-30  
対象：`azooKey/azooKey-Desktop` 上流`main`（[6b3f309](https://github.com/azooKey/azooKey-Desktop/tree/6b3f309553f023996003444bb3f2528ed7a31031)）および`Amatubamem/azooKey-Desktop` の`diagnostics/window-lifecycle-348`  
方法：公開Web資料、Apple公式ドキュメント、公開ソースコード、既存Issueと[調査記録](window-lifecycle-investigation.md)の読解。新しい実機実験・負荷試験は実施していない。

## 要旨

azooKeyは、`IMKInputController`の生成ごとに**通常候補、予測候補、AI置換候補、AIプロンプト入力の4枚のウィンドウを即時確保**する。入力セッションの生成・寿命はInputMethodKit（IMK）と入力先アプリに左右されるが、**セッションごとに4枚を確保することはazooKeyの実装選択**である。初期状態で3枚が`400×1000`、残る1枚が概ね`360×310`として観測される理由をコードから説明できる。[S1][S2]

この方式は正常な入力セッションが多数存在するだけでも、多数の不可視ウィンドウを生む。上流[Issue #348][S3]には80枚・144枚の報告とWindowServerの高CPU使用率の報告がある。ただし、**ウィンドウ保持とCPU負荷の因果関係、および終了済みセッションからのリークは確立されていない**。診断ブランチではChromeの入力セッション終了後に4枚が解放される事例を確認しており、少なくとも全件が解放漏れであるという説明は成り立たない。[S3][S4]

最も費用対効果の高い第一段階は**利用時までAI置換候補とAIプロンプトのウィンドウを生成しない方式**への変更である。未使用時のウィンドウ数を理論上`4N`から`2N`へ減らせる。中長期的には**候補パネルをプロセス全体で共有する方式**を検討する。Rime/SquirrelとmacSKKに、IMKの各入力コントローラと表示パネルの寿命を分離した公開実装がある。[S5][S6]

## 1. 問題と証拠の確度

### 1.1 報告された現象

[上流Issue #348][S3]は、macOS 14.6.1・Apple SiliconでazooKey所有の不可視ウィンドウ80枚、WindowServerのアイドル時CPU使用率22〜36%、ウィンドウのドラッグ移動が間欠的にできない状態を報告する。アンインストール後はWindowServer CPUが約4%になったという。別ユーザーはmacOS 26.5.2、azooKey v0.1.4で不可視144枚（`400×1000`が108枚、`360×310`が36枚）とCPU使用率55〜60%を報告した。

この報告から断定できるのは、報告者の環境でウィンドウと高CPU負荷が**同時に観測された**ことである。アンインストールはIMEプロセスの終了や他の描画状態の変化も伴うため、80枚の不可視ウィンドウそのものがCPUの増加分を発生させたという対照実験にはならない。

同Issueの追記では、**Spaceの切替不能についてはcmuxが原因だった**と訂正されている。この訂正と、当初報告されたタイトルバーのドラッグ移動不能は別の現象であり、後者もazooKeyを原因とする機構は特定されていない。

### 1.2 ソースから確定すること・確定しないこと

| 論点 | 根拠・判定 |
| --- | --- |
| 入力セッションごとの`IMKInputController` | **Appleの公開仕様**。`IMKServer`がクライアントの各入力セッションに対してコントローラを作る。[S7] |
| 3枚の`400×1000`ウィンドウ | **ソースで確定**。異なる3用途で`makeCandidateWindow()`を呼ぶ。[S1] |
| 4枚目のプロンプトウィンドウ | **ソースで確定**。`PromptInputWindow()`を同じ初期化で呼ぶ。[S2] |
| 非表示後もウィンドウが残る | **AppKitの公開仕様と整合**。`orderOut`は表示一覧から外すがオブジェクトを解放しない。[S8] |
| 全ウィンドウがリークした | **未証明**。通常のセッション保持と、終了後の残留を区別する必要がある。[S3][S4] |
| 不可視ウィンドウがWindowServerの高CPUの原因 | **未証明**。現行ソースとIssueだけではCPUの因果効果を定量化できない。[S3] |
| Apple標準IMEも4枚／入力セッションか | **不明**。Apple標準IMEの内部`NSWindow`所有モデルは公開されていない。[S9] |

## 2. IMKとウィンドウの所有単位

### 2.1 InputMethodKitが決める範囲

InputMethodKitは、入力先アプリとの通信、入力イベント、変換前の文字列、候補表示に関するAPIを提供する。`IMKServer`がクライアント接続を管理し、セッションごとに`IMKInputController`が作られる。[S7]

この仕様で決まるのは**入力状態の分離単位**である。`IMKCandidates`は必要に応じて利用する任意の候補UIクラスであり、`IMKServer`に関連付けて作る。個々の`IMKInputController`に`NSWindow`を複数持たせる義務はない。[S10]

変換中の文字列は、入力先の`IMKTextInput`に渡すmarked textとして表示できる。通常のライブ変換表示に専用のポップアップが不可欠というわけではない。候補一覧はポップアップが必要になるが、**入力のたびに新規生成する必要も、セッション数だけ確保しておく必要もない**。

### 2.2 Apple標準日本語IMEとの比較限界

Appleの公開ヘルプは、ライブ変換を入力中の自動変換として説明し、通常候補と予測候補については双方が「候補ウィンドウ」に表示されると述べる。[S9] azooKey開発者の公開記事は、標準ローマ字IMEのアプリ・拡張機能が`/System/Library/Input Methods/JapaneseIM-RomajiTyping.app`以下にあると示す。[S11]

標準IMEはAppleのIMEインフラストラクチャとIMKに関連する拡張機能を利用しているとみられるが、非公開内部クラスとウィンドウの配置・共有・生成時期は検証できない。**表示上ひとつの「候補ウィンドウ」であることから、内部`NSWindow`オブジェクト数を推定しない。** また、標準IMEのウィンドウ数が少ないという測定値は本調査では得ていない。

## 3. azooKeyの生成・表示・解放経路

### 3.1 3枚＋1枚の生成位置

上流`main`でも以下の構成を確認した。[S1][S2]

| ウィンドウ | 生成処理 | 主な表示契機 |
| --- | --- | --- |
| `candidatesWindow` | `makeCandidateWindow(CandidatesViewController)` | 通常候補の`refreshCandidateWindow()` |
| `predictionWindow` | `makeCandidateWindow(PredictionCandidatesViewController)` | 予測候補の`refreshPredictionWindow()` |
| `replaceSuggestionWindow` | `makeCandidateWindow(ReplaceSuggestionsViewController)` | AIによる文章置換結果を受けたとき |
| `promptInputWindow` | `PromptInputWindow()` | 選択テキストに対するAIプロンプト入力 |

候補系の3枚には共通の`candidateWindowInitialSize = CGSize(width: 400, height: 1000)`を設定する。`level = .popUpMenu`とし、直後に`setIsVisible(false)`・`orderOut(nil)`を呼ぶ。既定の大きさは**待機中の初期枠**であり、最終的な候補表示の大きさではない。候補表示時にビューコントローラが文字幅・行数・カーソル位置を基に調整する。

`PromptInputWindow`は`NSWindow`のサブクラスで、`init`中にSwiftUIを内包する`NSHostingView`まで組み立てる。初期サイズのコードは`360×200`で、通常表示の`resizeWindowToContent`は`360×324`を算出する。Issueで観測した`360×310`との差は現時点では説明できないため、固定値と実測値を混同しない。[S2]

### 3.2 生成が早すぎる機能

AI置換候補とAIプロンプトは、利用しない入力セッションにも割り当てられる。AIバックエンドがオフの場合も、ウィンドウの生成を条件分岐していない。`PromptInputWindow`は作成時に`NSHostingView`と通知監視を構築するため、単なる`NSWindow`オブジェクト以上の初期化処理を含む。[S1][S2]

通常候補と予測候補は同時に表示し得る。特にライブ変換無効時、予測候補を通常候補の右側に配置する処理がある。**この2機能を1枚に統合するには、同時表示のUI仕様を変更するか、共有するパネルに複数表示領域を実装する必要がある。** 逆に、AI機能の2枚を遅延生成するだけなら通常入力の表示設計を維持できる。[S1]

### 3.3 非表示と寿命

`activateServer`・`deactivateServer`では、候補等のウィンドウを`orderOut(nil)`している。Appleは`orderOut`を「表示一覧から取り除くが解放しない」操作として定義する。非表示のウィンドウが`CGWindowListCopyWindowInfo`で列挙されても、それだけでリークではない。[S8]

現行`PromptInputWindow`は`isReleasedWhenClosed = false`を設定し、`close()`で表示を閉じつつインスタンスを再利用する。これは明示的な保持設計である。[S2] 同クラスの`close()`は完了コールバックへ`nil`を渡すが、送信・キャンセル経路から呼び出す前に完了コールバックを先に呼ぶ場所がある。**完了通知の多重呼出しを防ぐ必要性**は独立した保守上の懸念であり、ウィンドウリークの証拠ではない。

コントローラが消滅すれば、そのウィンドウを保持する参照も通常は解放対象となる。実際に診断ブランチの記録では、Chrome入力先を閉じると新規4枚のウィンドウIDが消え、`deinit`が記録された。[S4] 一方、特定条件で`IMKInputController`自体が長く残る可能性は否定できない。ウィンドウをコントローラ単位で所有する構成は、その寿命にリソースを結び付ける。

### 3.4 既存の共有・遅延生成の先例

azooKeyの`AppDelegate`は変換エンジン`kanaKanjiConverter`をプロセス単位で保持し、各`SegmentsManager`に渡している。また、設定画面・ユーザー辞書編集画面は初回表示時にウィンドウを作り、次回以降再利用している。[S12]

**変換状態のセッション分離と、共有資源・表示UIのプロセス寿命を分ける設計は、すでに同じコードベースに存在する。**

## 4. 他の公開IMEにおける表示資源の所有

### 4.1 Rime/Squirrel：共有候補パネル

RimeのmacOSフロントエンドSquirrelは`IMKInputController`を実装しながら、`SquirrelApplicationDelegate.applicationWillFinishLaunching`で**`SquirrelPanel`を1個生成**する。入力セッション固有のコントローラはそのパネルに自身を`inputController`として設定し、描画内容・位置を更新する。`deactivateServer`ではパネルを隠す。候補選択やページ移動は共有パネルから現在のコントローラへ通知される。[S5]

この実装は**IMK入力セッションと候補`NSPanel`の所有を分離できる**ことを実証している。ただし、azooKeyの通常候補・予測候補の同時表示やAIプロンプトまでSquirrelの方式で実現できることを意味しない。

### 4.2 macSKK：複数種のパネルをプロセス単位で共有

macSKKは`Global.shared`に`inputModePanel`、`candidatesPanel`、`completionPanel`を保持する。`InputController`は`IMKInputController`を継承し、描画や補完の更新時に`Global.candidatesPanel`・`Global.completionPanel`を利用する。[S6]

**用途別の複数パネルを保持しながら、入力セッションごとにそのセットを複製しない**構成であり、azooKeyの「通常候補＋予測候補」を残した共有案に直接参考になる。macSKKのパネルは`NSPanel`を使用し、生成時の設定やフォーカス管理はazooKeyとは異なるため、コードの単純移植はできない。

### 4.3 その他の参考例と適用範囲

Google日本語入力のオープンソース部分であるMozcは、`GoogleJapaneseInputController`で`IMKInputController`を継承し、候補描画用の`RendererClient`を持つ。[S13] これはIMKコントローラと候補表示経路の分離例だが、別のレンダラ構成を使うため、メモリ使用量の大小を比較する根拠にはならない。

| 実装 | IMK入力コントローラ | 表示資源の特徴 | azooKeyへの示唆 |
| --- | --- | --- | --- |
| azooKey（現行） | セッションごと | `NSWindow`等を4枚／コントローラ | 課題の直接原因 |
| Rime/Squirrel | セッションごと | 候補`SquirrelPanel`をアプリ全体で1個 | 表示パネル共有が成立 |
| macSKK | セッションごと | 通常候補・補完等を`Global`で保持 | 用途別パネルの共有が成立 |
| Mozc | セッションごと | 専用RendererClientを介する描画 | IMKから表示を分離可能 |
| Apple標準日本語IME | 内部不明 | ライブ変換・候補表示の仕様は公開 | 内部オブジェクト数は比較不能 |

## 5. 負荷の解釈と検証で避けるべき誤推論

### 5.1 ウィンドウ数が説明するのは資源数まで

現行の初期状態では、生存コントローラ数を`N`とすると、候補系`3N`枚＋プロンプト`N`枚で、**概ね`4N`枚のウィンドウが生成される**。実際の全ウィンドウ数には設定画面やサイズ変更後のウィンドウ等が入り、単純な割算で正確なセッション数を特定できるとは限らない。

ウィンドウが保持されることは、AppKit・CoreAnimation・IOSurface・WindowServerに関連する資源を維持する可能性を示す。しかし、`400×1000`という論理的なフレームと、ウィンドウの物理メモリ使用量は同義ではない。レイヤーの実装、Retina倍率、描画バッファ、キャッシュ、共有領域、圧縮・スワップ、画面への表示状態によって費用は変わる。`vmmap`のCoreAnimation領域やRSSをウィンドウ枚数で単純に割って**1枚当たりの確定費用**とみなすことはできない。

同様に、不可視ウィンドウが多数存在することから、WindowServerが毎フレームそれらを合成していると推定する根拠はない。CPU負荷に関するIssueの値は再現事例として重要だが、WindowServerはIME以外のすべてのウィンドウも扱う。負荷増分をazooKeyに帰属するには対照条件が必要となる。

### 5.2 GUIランナー診断から分かった限界

既存の[調査記録][S4]には、macOSセルフホストランナーから`CGWindowListCopyWindowInfo`が`nil`を返し、`CGPreflightScreenCaptureAccess() == false`、`AXIsProcessTrusted() == true`だった記録がある。

**この観測は画面収録権限不足だけを原因として確定しない。** Apple公式の`CGWindowListCopyWindowInfo`仕様は、GUIセキュリティセッションの外部から実行した場合にも`NULL`を返すと明記している。[S14] さらにAppleのWWDC説明は、画面収録権限がないときはウィンドウ名などの**特定メタデータが制限され得る**と説明しており、全ウィンドウ情報が必ず`nil`になるとは述べていない。[S15]

従って、先行文書で「`CGPreflightScreenCaptureAccess`が`false`だから`nil`の原因は画面収録権限不足」と断定した箇所は**推論が強すぎた**。GUIセッションの所属と権限の両方を調べない限り、根本原因は確定しない。本調査では追加GUI実験を行わない。

### 5.3 リークを判定する条件

診断時は、次を分けて記録する必要がある。

1. `IMKInputController.init`後に4枚が生存する――**現行設計どおり**。
2. 入力先を非アクティブにしただけで4枚が残る――**設計どおりに起こり得る**。非アクティブ化はセッション終了と同じではない。
3. `inputControllerWillClose`・`deinit`後も、そのコントローラの`windowNumber`が残る――**解放漏れ・外部保持を疑う具体的根拠**。
4. 同じ操作の繰り返しで、コントローラ数は戻るのにウィンドウ数だけ増える――**ウィンドウ管理側を疑う具体的根拠**。
5. コントローラ数も増え続ける――**IMKのセッション生成・保持と入力先アプリ側の寿命管理を含めて調べる**。azooKeyだけのリークと断定しない。

## 6. 修正方針の比較

### 6.1 選択肢と予想される効果

| 案 | 待機中のウィンドウ数（`N`セッション） | 変更範囲 | 主なリスク | 評価 |
| --- | --- | --- | --- | --- |
| A 現状維持 | `4N` | なし | 非使用機能まで先行確保 | 原因把握後の暫定ベース |
| B AIウィンドウだけ遅延生成 | **`2N`**（AI未使用時） | AI置換・プロンプトの生成経路 | 初回表示遅延、再入、`nil`分岐 | **第一段階として推奨** |
| C 予測候補も遅延生成 | **`N`**（予測・AI未使用時） | 予測候補の作成・更新処理 | 頻用機能の初回遅延、キャッシュの扱い | Bの次に検討 |
| D プロセス共通の候補・予測パネル | **概ね一定数** | 描画・所有・イベント配送の大幅変更 | セッション取り違え、非同期更新、フォーカス | **長期的な構造改善候補** |
| E 非アクティブ化で毎回閉じる | 活動状態に依存 | 全ウィンドウの再生成管理 | フォーカス切替ごとの再生成、ちらつき | 原則非推奨 |
| F `IMKCandidates`へ置換 | 実装次第 | UIを全面的に変更 | 現行デザイン・予測同時表示の再現性 | 本件だけを理由に採用しない |

ここでの`2N`・`N`は**作成条件から導く理論上の枚数**であり、実測したメモリ削減率ではない。プロセス全体の別ウィンドウは含まない。

### 6.2 第一段階：AI関連のウィンドウを遅延生成する

`azooKeyMacInputController`の`replaceSuggestionsViewController`、`replaceSuggestionWindow`、`promptInputWindow`を初期化時に必須の保持値から外す。最初のAI置換候補要求時に候補用ビューコントローラと`NSWindow`を組み立て、最初のプロンプト表示時に`PromptInputWindow`を生成する。作成済みのインスタンスはそのセッションで再利用する。

これは**通常の候補・予測候補の表示経路とUI配置を変えず**に、AIを使わないセッションで先行確保する2枚を削減できる。AIバックエンド設定がオフであるかだけを生成条件にする方式は、設定変更時にウィンドウを準備する必要があり、未使用のままオンにしているセッションでも資源を保持する。**実際に必要になった瞬間に生成する**方が効果を説明しやすい。

実装上の留意点は次のとおり。

- 最初の要求でのみ生成する専用アクセサ（例：`ensureReplaceSuggestionWindow()`、`ensurePromptInputWindow()`）に生成処理を集約する。ウィンドウとビューコントローラの対応、`delegate`設定、`@MainActor`上の操作を一緒に行う。
- `setIsVisible(false)`・`orderOut(nil)`・`makeKeyAndOrderFront(nil)`を呼ぶ全経路を見直す。未生成時の非表示処理は何もしない。`activateServer`・`deactivateServer`や異常終了経路も対象とする。
- `PromptInputWindow`の`close()`は既に`isReleasedWhenClosed = false`を設定しており、再利用前提である。遅延生成の導入を`close()`による毎回破棄にすり替えない。[S2][S16]
- AI非同期処理では古いコントローラ・古い入力先へ結果を表示しない。`inputState`・対象文字列・アクティブなセッションの照合を保持する。
- 初回表示の計算量・レイアウト生成費用を確認する。`PromptInputWindow`はSwiftUIビューを構築するため、初回表示で知覚できる遅延が生じる可能性がある。

**受入条件**は、AIを利用しない新規入力セッションで候補ウィンドウ2枚だけが生成されること、AI各機能の初回・再表示が従来どおり動くこと、セッション終了後に当該ウィンドウが解放されることである。

### 6.3 第二段階：通常候補・予測候補の共有を設計する

第一段階の削減が不足する場合、`AppDelegate`または専用の`CandidateWindowCoordinator`に`candidatesWindow`と`predictionWindow`を保持させ、個別`IMKInputController`には変換状態・候補値などの**セッション固有のデータ**を残す。共有パネル数は原則としてプロセス単位で一定になる。SquirrelとmacSKKに実例がある。[S5][S6]

共有する場合、**最後に処理したセッション**を無条件に表示対象にすると、フォーカス移動後の非同期完了が旧入力先の候補を表示する危険がある。UIコーディネータで少なくとも次を管理する。

- `activeController`は弱参照とし、`activateServer`で更新する。`deactivateServer`・`inputControllerWillClose`・`deinit`に相当する経路で、現在の所有者だった場合のみ解除・非表示にする。
- 表示要求ごとにアクティブなセッションIDまたは世代番号を検査する。古い要求が完了しても現在のUIを上書きさせない。
- ビューの候補選択デリゲートを表示開始時のコントローラへ明示的に結び直す。クリックで別セッションへ入力確定しない。
- 通常候補と予測候補の**同時表示**、ライブ変換オン・オフ、候補ウィンドウ位置、マルチディスプレイ、非アクティブアプリのUI非表示を維持する。
- AI置換・プロンプトは入力先への再フォーカスやテキスト選択範囲を扱う。共有化する場合は候補UIとは別に、セッションIDと処理中要求を厳密に管理する。

候補ビューを共有しても、`SegmentsManager`や変換エンジンのセッション状態まで共有すべきではない。**表示資源の共有と変換状態の共有を分離する**ことが設計の中核となる。

### 6.4 `IMKCandidates`への置換は独立した論点

`IMKCandidates`は、候補表示・選択・注釈の標準APIを提供する。[S10] ただしazooKeyには`NSTableView`、`NSVisualEffectView`、文字幅に応じた配置、通常候補と予測候補の横並びなど独自のUIがある。[S1][S17] この機能を標準候補UIで同等に再現できるかは未検証であり、**ウィンドウ数削減だけを目的とした全面置換は変更規模が大きい**。既存のAppKit UIを保ったまま共有化する方が、比較可能な設計案である。

## 7. 実装計画と検証の境界

### 7.1 実装を分割する

| 順序 | 変更内容 | ソース上で確認する基準 |
| --- | --- | --- |
| P0 | AI未使用時の4枚先行生成に関する根拠をテスト可能な形に整理 | 生成関数の呼出し箇所と寿命・所有の説明が一意になる |
| P1 | AI置換候補・プロンプトを利用時生成へ変更 | AI未使用セッションの候補系2枚、AI初回・再表示、終了時解放 |
| P2 | 予測候補の遅延生成の費用対効果を評価 | 予測表示・キャッシュの機能が維持される |
| P3 | P1/P2の効果が不足する場合にのみ共有コーディネータを実装 | セッション切替時の表示帰属、候補選択、非同期完了の誤配送がない |
| P4 | 負荷の帰属を必要に応じて検証 | コントローラ数とウィンドウ数を揃えた対照条件で増分を比較 |

P1から先に着手すると、通常の文字入力や候補表示の仕様を変更せずにウィンドウ総数を減らせる。P3は持続的な削減余地が最大だが、入力セッション間の表示帰属という新しい不変条件が増える。性能改善の実測がなくても、**不要機能の先行生成を避けることはコード上の資源管理改善として説明可能**である。一方、CPU改善の効果は測定まで断定しない。

### 7.2 コードから確認するテスト観点

CIではGUI権限が要求されるWindowServerの全ウィンドウ列挙を**必須テストにしない**。コーディネータや遅延生成の状態遷移は、ウィンドウ生成を注入できる小さな境界に分け、生成要求数、表示要求、所有セッションの切替、古い非同期完了の棄却などをロジックとして検証する。

実際のGUI試験が必要な場合でも、既存の動作確認機会とまとめ、**追加で何を明らかにするかを先に定義**する。ユーザーのMacのフォーカス、Chromeの状態、アクセシビリティ／画面収録権限、実行時間は無償の前提としない。

### 7.3 解決とみなす条件

本件は、次の2つを独立に評価して収束させる。

- **資源設計の改善**：通常利用のセッションに不要なウィンドウが確保されなくなり、表示機能と終了時の寿命管理を維持できた。
- **WindowServer高CPU報告の解明**：同じOS・負荷条件で高CPUを再現し、表示資源の管理変更に伴う差が確認された。再現できない場合は原因未確定と明記し、資源設計改善のみを完了扱いにする。

## 8. 総合判断

**第一候補は、AI置換候補ウィンドウとAIプロンプトウィンドウの利用時生成である。** 現行ソースは各入力セッションで未使用のAI用ウィンドウ2枚まで生成しているため、実装だけから削減対象を特定できる。通常候補・予測候補の同時表示と入力イベントの経路を維持でき、共有UIを全面的に導入する前の低リスクな改善になる。

**次の候補は、通常候補・予測候補のプロセス単位での共有である。** SquirrelとmacSKKの公開実装は、IMKセッションごとにUIを複製しない方式が成立することを示す。ただしazooKeyの候補・予測同時表示、AI非同期要求、フォーカス復元に対するイベント配送設計が必要であり、P1の後に改めて費用対効果を判断する。

**リーク修正と高CPU対策という名称で変更を急がない。** それらの発生機構はまだ確認できていない。本調査が確定した問題は、**入力セッション寿命に従って未使用の表示資源を4枚ずつ先行確保する設計**である。

---

## 出典

以下は調査に使用した公開資料。AppleのAPI仕様と公開ソースを主たる根拠とし、Issueの数値は投稿者の観測として区別した。コミット固定リンクを使える公開実装は可能な限り固定した。

- **[S1] azooKey上流**： [azooKeyMacInputController.swift](https://github.com/azooKey/azooKey-Desktop/blob/6b3f309553f023996003444bb3f2528ed7a31031/azooKeyMac/InputController/azooKeyMacInputController.swift)（生成、表示、アクティブ化・非アクティブ化）。
- **[S2] azooKey上流**： [PromptInputWindow.swift](https://github.com/azooKey/azooKey-Desktop/blob/6b3f309553f023996003444bb3f2528ed7a31031/azooKeyMac/Windows/PromptInput/PromptInputWindow.swift)（SwiftUI構築、再利用、close）。
- **[S3] azooKey上流**： [Issue #348（本文とコメント）](https://github.com/azooKey/azooKey-Desktop/issues/348)（80枚、144枚、高CPU、cmuxへの原因訂正）。
- **[S4] 調査ブランチ**： [window-lifecycle-investigation.md](https://github.com/Amatubamem/azooKey-Desktop/blob/c45d60cc31bb8902a6269d86a01ee9874879b97f/docs/window-lifecycle-investigation.md)（ウィンドウIDの増減とGUIランナーの診断）。
- **[S5] Rime/Squirrel**： [AppDelegate](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelApplicationDelegate.swift)、[InputController](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift)、[Panel](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelPanel.swift)、[アーキテクチャ文書](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/SKILL.md)。
- **[S6] macSKK**： [Global.swift](https://github.com/mtgto/macSKK/blob/539cce39a6a66ea6e6fd4b802b827008eed21cbf/macSKK/Global.swift)、[InputController.swift](https://github.com/mtgto/macSKK/blob/539cce39a6a66ea6e6fd4b802b827008eed21cbf/macSKK/InputController.swift)、[CandidatesPanel.swift](https://github.com/mtgto/macSKK/blob/539cce39a6a66ea6e6fd4b802b827008eed21cbf/macSKK/View/CandidatesPanel.swift)、[CompletionPanel.swift](https://github.com/mtgto/macSKK/blob/539cce39a6a66ea6e6fd4b802b827008eed21cbf/macSKK/View/CompletionPanel.swift)。
- **[S7] Apple**： [InputMethodKit](https://developer.apple.com/documentation/inputmethodkit)、[IMKInputController](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller)、[IMKServer](https://developer.apple.com/documentation/inputmethodkit/imkserver)。
- **[S8] Apple**： [NSWindow.orderOut](https://developer.apple.com/documentation/appkit/nswindow/orderout%28_%3A%29)。
- **[S9] Apple**： [標準日本語入力の設定](https://support.apple.com/en-ng/guide/japanese-input-method/jpim662a12b9/mac)、[候補ウィンドウ](https://support.apple.com/en-ie/guide/japanese-input-method/jpim10262/mac)。
- **[S10] Apple**： [IMKCandidates](https://developer.apple.com/documentation/inputmethodkit/imkcandidates)、[IMKCandidates.init(server:panelType:)](https://developer.apple.com/documentation/inputmethodkit/imkcandidates/init%28server%3Apaneltype%3A%29)。
- **[S11] azooKey開発者記事**： [InputMethodKit：azooKey on macOSの開発知見](https://zenn.dev/azookey/articles/d06b4ee8039ba9)。
- **[S12] azooKey上流**： [AppDelegate.swift](https://github.com/azooKey/azooKey-Desktop/blob/6b3f309553f023996003444bb3f2528ed7a31031/azooKeyMac/AppDelegate.swift)（変換エンジン共有、設定ウィンドウの初回生成）。
- **[S13] Mozc**： [GoogleJapaneseInputController.mm](https://chromium.googlesource.com/external/mozc/+/master/src/mac/GoogleJapaneseInputController.mm)。
- **[S14] Apple**： [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29)（GUIセキュリティセッション外ではNULLを返す）。
- **[S15] Apple**： [WWDC 2019 Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/)（画面収録権限とウィンドウ情報の一部制限）。
- **[S16] Apple**： [NSWindow.isReleasedWhenClosed](https://developer.apple.com/documentation/appkit/nswindow/isReleasedWhenClosed)、[NSWindow.close](https://developer.apple.com/documentation/appkit/nswindow/close%28%29)。
- **[S17] azooKey上流**： [BaseCandidateViewController.swift](https://github.com/azooKey/azooKey-Desktop/blob/6b3f309553f023996003444bb3f2528ed7a31031/azooKeyMac/InputController/CandidateWindow/BaseCandidateViewController.swift)（独自の候補UI）。

