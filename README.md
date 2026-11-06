# ConfigBox

BetterTouchTool・Karabiner-Elements・AltTab の「普段使う部分」を 1 つにまとめた、依存ライブラリゼロのネイティブ macOS アプリです。
サードパーティ製バイナリを 3 つ常駐させる代わりに、手元でビルドした 1.7 MB の実行ファイル 1 つだけを動かします。

| 元のアプリ | ConfigBox での実装 |
|---|---|
| BetterTouchTool | トラックパッドの N 本指タップ / スワイプ、マウス（ボタンクリック・修飾キー + スクロール・ボタン押下ジェスチャ）、キーボードショートカットをトリガーに、ウィンドウ整列・アプリ起動・メディアキー・シェル / AppleScript などを実行 |
| Karabiner-Elements | 単純なキー置換は macOS 標準の `hidutil`（常駐コストゼロ、デバイス別指定可）、Mod-Tap キー（タップで Esc / ホールドで ⌃ など、デバイス別指定可）、同時押し（simultaneous: J + K → 任意のアクション）、キーマクロ（1 キー → 複数キー / テキスト入力 / 機能の連続実行、デバイス別指定可）は CGEventTap で処理 |
| AltTab | ⌥Tab でウィンドウ単位のスイッチャー。サムネイル表示（ScreenCaptureKit）、最小化 / 非表示ウィンドウも対象、W / M / H / Q でウィンドウ操作 |
| BTT ウィンドウスナップ | ウィンドウを画面の端・角へドラッグすると半透明プレビューを表示、離すと左右半分 / 4 隅 / 最大化に整列。隣接ディスプレイとの境界は無視、修飾キー押下時のみ有効にも設定可 |
| BTT スナップエリア（高度な機能） | BTT と同じ「作成 / 編集 / 管理 / 説明を表示 / 設定を表示」構成。作成すると色付きのエリアウィンドウが現れ、普通のウィンドウとして動かす・伸縮するだけで定義完了。編集モードでは全エリアがウィンドウとして表示され、エリア内の Settings… で名前・色・修飾キー・アプリ条件を設定。**Attach Window…** で任意のウィンドウを好きな位置・大きさに置いて Attach を押すと、その枠がドロップ後のウィンドウ枠として紐付く（BTT の「ウィンドウを紐付け」相当）。管理ウィンドウで一覧・複製・削除・数値編集。透明度・名前表示・表示遅延・枠線の全般設定 |
| マウスユーティリティ（LinearMouse / Mos / Scroll Reverser 相当） | Mouse › Settings: マウスホイールだけの上下 / 左右反転（トラックパッドは影響なし）、スクロール速度、スムーズスクロール、Shift + ホイールで横スクロール、ポインタ感度（HID 解像度 = DPI 相当）、加速のオフ / カスタム、ボタン 4 / 5 を戻る / 進むに |
| Karabiner-EventViewer | 「Event Viewer」ウィンドウ: キーイベント（コード・名称・修飾キー・どの機能が処理したか）、最前面アプリの Bundle ID / ウィンドウタイトル、HID デバイス一覧、トラックパッドの指位置をライブ表示 |
| Karabiner-VirtualHIDDevice-Manager | 「HID Device Manager」ウィンドウ: HID レベルのリマップ層の有効化 / 無効化、システムに実際に入っているマッピングの確認（キーボードごと）、他ツールのマッピングも含めた全消去、ログイン時に自動適用する LaunchAgent の管理 |

UI は BetterTouchTool を踏襲しています（左: アプリ一覧、中央: トリガー一覧、右: アクション設定、上部でカテゴリ切替）。

## ビルドと起動

```sh
./scripts/build-app.sh          # build/ConfigBox.app を生成（release, -Osize）
open build/ConfigBox.app
```

要件: macOS 14 以降、Xcode 15 以降（Swift 5.9+）。外部パッケージはありません。

### 署名について（重要）

Accessibility / 画面収録の許可はコード署名に紐づきます。ad-hoc 署名だとビルドのたびに許可をやり直すことになるため、
ビルドスクリプトはキーチェーンにある最初の有効なコード署名 ID（自己署名で可）を自動で使います。
明示したい場合は `CODESIGN_IDENTITY="証明書名" ./scripts/build-app.sh` としてください。

### 必要な権限

- **アクセシビリティ**（必須）: キーのリマップ、ショートカット、ウィンドウスイッチャーに使用
- **画面収録**（任意）: スイッチャーのサムネイル表示のみ。未許可の場合はアプリアイコンを表示

設定画面の「Settings」タブから付与できます。付与後に反応しない場合は一度アプリを再起動してください。

## 設定ファイル

`~/Library/Application Support/ConfigBox/config.json`。UI の変更は自動保存されます。
テキストエディタで編集した場合はメニューバーの「Reload Config File」で再読込します。

## 設計方針（軽量化のために）

- **常駐するのは CGEventTap 1 本と（ジェスチャ使用時のみ）マルチタッチのリスナーだけ。** 設定ウィンドウは閉じると SwiftUI 階層ごと解放されます。
- **単純なキー置換は hidutil に委譲。** システム設定の修飾キー変更と同じ経路で、ConfigBox が落ちても動き続け、処理コストがありません。終了時に自動で解除します。
- **スイッチャーのサムネイルは表示中だけ保持。** 閉じた瞬間に解放します。
- **ポーリングなし。** すべてイベント駆動です。
- 実測（Apple Silicon, ウィンドウを閉じた状態）: 物理メモリ使用量 約 33 MB、CPU 0%。

## 構成

```
Sources/CBridge/                 MultitouchSupport（dlopen）と _AXUIElementGetWindow の C ブリッジ
Sources/ConfigBox/
  App/                           エントリポイント、メニューバー、権限、ウィンドウ管理
  Config/                        設定モデル（Codable JSON）、キーコード表
  Engines/Keyboard/              EventTap, InputRouter, KeyRemapper（二役キー）, HIDUtil, KeySynth
  Engines/Trackpad/              マルチタッチフレーム → タップ / スワイプ認識
  Engines/Switcher/              ウィンドウ列挙、スイッチャー制御、オーバーレイ UI
  Engines/Windows/               ドラッグによるウィンドウスナップとプレビュー
  Engines/Viewer/                Event Viewer 用のイベント記録（ビューア表示中のみ動作）
  Actions/                       アクション実行、AX によるウィンドウ整列、システム操作
  UI/                            BTT 風の設定画面
```

## Karabiner の仮想 HID デバイスについて

Karabiner-Elements は DriverKit 製の仮想キーボード（Karabiner-VirtualHIDDevice）を使いますが、これは Apple が個別に発行する DriverKit エンタイトルメントと公証済みシステム機能拡張が必要で、手元のビルドでは再現できません。
ConfigBox はカーネル寄りのコードを入れない方針で、単純置換は Apple 標準の HID リマップ（`hidutil` の `UserKeyMapping`。システム設定の修飾キー変更と同じ経路）、ロジックが要るもの（二役キー・ショートカット）はユーザー空間のイベントタップで処理します。
HID Device Manager はこの層の「有効化 / 無効化 / 状態確認 / デバイス別適用 / 永続化」を担当し、VirtualHIDDevice-Manager の役割に相当します。

## 制限事項・注意

- macOS 自身が処理するジェスチャ（3 本指 / 4 本指スワイプ、2 本指タップなど）はそのまま動きます。ConfigBox 側で同じジェスチャを使う場合は「システム設定 › トラックパッド」で該当ジェスチャをオフにしてください。
- Caps Lock の Mod-Tapは内部で Caps Lock → F18 を HID レベルで割り当ててから処理します（Karabiner の定石と同じ）。F18 を別用途で使っている場合は衝突します。
- 単純置換で修飾キー自体（例: 左 ⌃ 単押しで Esc）を二役にする場合、長押し時は本来の修飾キーとして動きます。
- 別のスペースにあるウィンドウへの切替は「システム設定 › デスクトップと Dock › アプリケーションの切り替え時に、開いているウィンドウがあるスペースに移動」が有効なときに動作します。
- HID レベルの単純置換はセキュア入力欄（パスワード欄）でも効きますが、イベントタップで処理する二役キーやショートカットはセキュア入力中は届きません。
- ウィンドウスナップは「ドラッグ開始後にウィンドウ位置が実際に動いたか」で判定するため、テキスト選択やスクロールバーのドラッグでは発動しません。
- MultitouchSupport は Apple の非公開フレームワークです（BTT 等も同じものを使用）。将来の macOS で利用できなくなった場合はトラックパッド機能のみ無効になります。

## デバッグ用起動オプション

```sh
build/ConfigBox.app/Contents/MacOS/ConfigBox --section trackpad|keyboard|remap|snapping|switcher|settings [--select-first]
build/ConfigBox.app/Contents/MacOS/ConfigBox --window eventViewer|hidManager
```
