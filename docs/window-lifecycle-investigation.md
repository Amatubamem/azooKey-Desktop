# 入力セッションに伴う不可視ウィンドウの生成・解放調査

調査日：2026年10月29日  
対象：[azooKey-Desktop #348](https://github.com/azooKey/azooKey-Desktop/issues/348)  
状態：原因調査中。確認したサイト開閉条件では解放漏れを再現していない。

## 背景と目的

azooKey-Desktopでは、長時間の使用後に不可視ウィンドウが多数残り、WindowServerの負荷が上がる現象が報告されている。入力セッションに応じた通常の資源確保と、終了後にも資源が残る不具合を区別する必要がある。

本調査では、入力コントローラの生成・破棄とウィンドウ番号の変化を対応付け、メモリ負荷を評価する。次にmacOS標準の日本語入力と比較し、azooKey側で資源管理を変更する必要があるか判断する。

## 検証条件と方法

macOS 15.8.1、Apple Silicon、個人用ビルド（Bundle ID：`dev.kasano.inputmethod.azooKeyMac`）で調査した。診断コードは`29aae1ee6c1b0309f4f9f9bcc33d9124d6ae07c8`を起点とする[`diagnostics/window-lifecycle-348`](https://github.com/Amatubamem/azooKey-Desktop/tree/diagnostics/window-lifecycle-348)に実装した。

`azooKeyMacInputController`の`init`、`inputControllerWillClose`、`deinit`をログに記録する。`init`時にはコントローラIDと4種類のウィンドウ番号も記録する。候補表示のたびに発生する`activate`と`deactivate`のログは省いた。

WindowServer上の所有ウィンドウは[`Tools/window-lifecycle-snapshot.swift`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/Tools/window-lifecycle-snapshot.swift)で列挙する。Chromeでサイトを開く前、開いた後、タブを閉じた後の枚数とウィンドウ番号を比較した。

```zsh
pid=$(pgrep -x azooKeyMac | head -n 1)
swift Tools/window-lifecycle-snapshot.swift "$pid" --ids

# 別のターミナルでライフサイクルを監視する
log stream --style compact \
  --predicate 'process == "azooKeyMac" AND eventMessage CONTAINS "[WindowLifecycle]"'
```

## 観測結果

### 入力コントローラの生成とウィンドウの確保

Chromeでは新しいサイトや入力コンテキストを有効にすると、入力コントローラの`init`が発生した。コントローラ1個の生成に対応して、不可視ウィンドウが4枚増加した。

| ウィンドウ | サイズ・レイヤー | 生成数 |
| --- | --- | ---: |
| 変換候補・予測候補・置換候補 | 400×1000、layer 101 | 3枚 |
| プロンプト入力 | 360×310、layer 3 | 1枚 |

3枚の候補ウィンドウは、[`makeCandidateWindow()`](https://github.com/Amatubamem/azooKey-Desktop/blob/diagnostics/window-lifecycle-348/azooKeyMac/InputController/azooKeyMacInputController.swift)の初期サイズと一致する。プロンプト入力用ウィンドウも同じ初期化処理で生成される。

長時間稼働した別のプロセスでは、不可視ウィンドウを計155枚観測した。内訳には`400×1000 / layer 101`が108枚、`360×310 / layer 3`が38枚含まれた。観測した枚数だけでは、入力セッションが存続していたのか、資源が解放されずに残っていたのか判断できない。

### Chromeのサイト開閉に伴う解放

同一のazooKeyプロセス（PID 14545）で、サイトの開閉前後を測定した。

| 状態 | 全ウィンドウ | 400×1000 | 360×310 |
| --- | ---: | ---: | ---: |
| サイトを開く前 | 28 | 21 | 7 |
| サイトを開いた後 | 32 | 24 | 8 |
| タブを閉じた後 | 28 | 21 | 7 |

サイトを開いたときに増えたウィンドウ番号は`51910`、`51911`、`51912`、`51913`であり、タブ終了後には4件とも消滅した。タブ終了時には、対応する入力コントローラの`deinit`も確認した。アプリケーション自体を終了した際にも`deinit`が発生する。

### Zenzaiとメモリ使用量

別の長時間稼働プロセスでは、`vmmap`に表示されたZenzaiのGGUFモデルのマッピングは1件だった。Physical footprintは400.6 MB、稼働中のピークは579.8 MBだった。この単一時点の測定では、継続的なメモリ増加の有無を判断できない。ウィンドウ数と物理メモリ負荷の関係も未測定である。

## 考察

**今回のサイト開閉条件では、入力コントローラと4枚のウィンドウが正常に解放された。** したがって、この操作は解放漏れの再現手順にはならない。

入力コンテキストに応じてコントローラが生成される一方、azooKeyは各コントローラの初期化時に表示用ウィンドウを4枚確保する。この組み合わせによって、同時に存在する入力セッションの数に応じてウィンドウが増加する。

InputMethodKit（IMK）やChromeが入力セッションを保持する条件、標準日本語入力での資源管理、[上流の報告](https://github.com/azooKey/azooKey-Desktop/issues/348)にあるWindowServer高負荷との因果関係は未確認である。現在の観測からは、入力コントローラ解放時の強制的なウィンドウ破棄や、プロセス全体でのウィンドウ共有を直ちに実装する根拠は得られていない。

## 次の検証

- [ ] **標準日本語入力との比較**：Apple標準の「日本語 - ローマ字入力」で同じChrome操作を繰り返し、関連プロセス、所有ウィンドウ数、物理メモリ負荷を記録する。標準IMEのUIが別プロセスに分かれている場合は、その構成を確認する。
- [ ] **セッションの寿命と残留条件の調査**：タブ終了、ページ遷移、タブ切替、Chrome終了について`init`・`willClose`・`deinit`とウィンドウIDの対応を記録する。終了済みコントローラのウィンドウが残る条件を探索する。
- [ ] **資源負荷の定量化**：セッション数を段階的に変え、azooKeyのPhysical footprint、CoreAnimation・IOSurfaceの領域、WindowServerのCPU・メモリ負荷を測定する。起動直後と一定時間経過後を区別する。
- [ ] **対策の要否を判断**：実測した負荷が問題となる場合に、ウィンドウの遅延生成と共有を比較する。メモリ削減効果、初回候補表示の遅延、セッション間の表示・デリゲートの切替を評価する。
- [ ] **上流への報告**：再現条件と定量的な比較結果が得られた段階で、[azooKey-Desktop #348](https://github.com/azooKey/azooKey-Desktop/issues/348)に追記する。

診断ブランチのログとスナップショットは継続して使用する。調査結果の確定に合わせて本ファイルを更新する。
