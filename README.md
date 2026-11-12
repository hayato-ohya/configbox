# ConfigBox

[English](#english) · [日本語](#日本語)

# 日本語

BetterTouchTool・Karabiner-Elements・AltTab の「普段使う部分」を 1 つにまとめた、依存ライブラリゼロのネイティブ macOS アプリです。
サードパーティ製バイナリを 3 つ常駐させる代わりに、手元でビルドした約 5 MB の実行ファイル 1 つだけを動かします。

| 元のアプリ | ConfigBox での実装 |
|---|---|
| BetterTouchTool | トラックパッドの N 本指タップ / ダブルタップ / クリック / ダブルクリック / スワイプ（四隅・端・半分などの位置や、別の指を押さえながらの条件も指定可）、マウス（ボタンクリック・修飾キー + スクロール・ボタン押下ジェスチャ）、キーボードショートカットをトリガーに、ウィンドウ整列・アプリ起動・メディアキー・ドラッグ・シェル / AppleScript などを実行。押し込みを離しても指が触れている間ドラッグを続ける設定もあり |
| Karabiner-Elements | 単純なキー置換は macOS 標準の `hidutil`（常駐コストゼロ、デバイス別指定可）、Mod-Tap キー（タップで Esc / ホールドで ⌃ など、デバイス別指定可）、同時押し（simultaneous: J + K → 任意のアクション）、キーマクロ（1 キー → 複数キー / テキスト入力 / 機能の連続実行、デバイス別指定可）は CGEventTap で処理 |
| AltTab | ⌥Tab でウィンドウ単位のスイッチャー。サムネイル表示（ScreenCaptureKit）、最小化 / 非表示ウィンドウも対象、W / M / H / Q でウィンドウ操作 |
| BTT ウィンドウスナップ | ウィンドウを画面の端・角へドラッグすると半透明プレビューを表示、離すと左右半分 / 4 隅 / 最大化に整列。隣接ディスプレイとの境界は無視、修飾キー押下時のみ有効にも設定可 |
| BTT スナップエリア（高度な機能） | BTT と同じ「作成 / 編集 / 管理 / 説明を表示 / 設定を表示」構成。作成すると色付きのエリアウィンドウが現れ、普通のウィンドウとして動かす・伸縮するだけで定義完了。編集モードでは全エリアがウィンドウとして表示され、エリア内の Settings… で名前・色・修飾キー・アプリ条件を設定。**Attach Window…** で任意のウィンドウを好きな位置・大きさに置いて Attach を押すと、その枠がドロップ後のウィンドウ枠として紐付く（BTT の「ウィンドウを紐付け」相当）。管理ウィンドウで一覧・複製・削除・数値編集。透明度・名前表示・表示遅延・枠線の全般設定 |
| マウスユーティリティ（LinearMouse / Mos / Scroll Reverser 相当） | Mouse › Settings: マウスホイールだけの上下 / 左右反転（トラックパッドは影響なし）、スクロール速度、スムーズスクロール、Shift + ホイールで横スクロール、ポインタ感度（HID 解像度 = DPI 相当）、加速のオフ / カスタム、ボタン 4 / 5 を戻る / 進むに |
| Karabiner-EventViewer | 「Event Viewer」ウィンドウ: キーイベント（コード・名称・修飾キー・どの機能が処理したか）、最前面アプリの Bundle ID / ウィンドウタイトル、HID デバイス一覧、トラックパッドの指位置をライブ表示 |
| Karabiner-VirtualHIDDevice-Manager | 「HID Device Manager」ウィンドウ: HID レベルのリマップ層の有効化 / 無効化、システムに実際に入っているマッピングの確認（キーボードごと）、他ツールのマッピングも含めた全消去、ログイン時に自動適用する LaunchAgent の管理 |

UI は BetterTouchTool を踏襲しています（左: アプリ一覧、中央: トリガー一覧、右: アクション設定、上部でカテゴリ切替）。

その他の機能:

- **日本語 / 英語の UI:** 「設定 › 一般 › 言語」で切り替えます（初期値はシステムの言語）。
- **設定の保存 / 復元:** 「設定 › 設定ファイル」から JSON ファイルに書き出し、復元できます。
- **JIS キーボードを ANSI として入力:** 「設定 › 一般」でオンにすると、JIS キーボードで US 配列の文字を入力できます。
- **Windows キーボード対応:** 無変換 / 変換を 英数 / かな に割り当てられます（キーリマップのプリセット）。

## ビルドと起動

```sh
./scripts/build-app.sh          # build/ConfigBox.app を生成（release, -Osize）
open build/ConfigBox.app
```

要件: macOS 14 以降、Xcode 15 以降（Swift 5.9+）。外部パッケージはありません。ビルドしたマシンのアーキテクチャ用のアプリができます。

単体テストは `swift test` で実行します（設定の読み込みと検証、スムーズスクロールの計算、ウィンドウ整列の座標など、入力や画面に触れない部分が対象です）。

### 署名について（重要）

Accessibility / 画面収録の許可はコード署名に紐づきます。ad-hoc 署名だとビルドのたびに許可をやり直すことになるため、
ビルドスクリプトはキーチェーンにある最初の有効なコード署名 ID（自己署名で可）を自動で使います。
明示したい場合は `CODESIGN_IDENTITY="証明書名" ./scripts/build-app.sh` としてください。
自己署名のビルドは公証されていないので、他の Mac に配布すると Gatekeeper にブロックされます。

### 必要な権限

- **アクセシビリティ**（必須）: キーのリマップ、ショートカット、ウィンドウスイッチャーに使用
- **画面収録**（任意）: スイッチャーのサムネイル表示のみ。未許可の場合はアプリアイコンを表示
- **入力監視**（任意）: キーボードを見分けるためだけに使用。キーボードを限定した同時押しルールと、予備キーが足りなくなったときのキーボード限定のキー → アクション

設定画面の「設定」タブから付与できます。付与後に反応しない場合は一度アプリを再起動してください。

## 設定ファイル

`~/Library/Application Support/ConfigBox/config.json`。UI の変更は自動保存されます。
テキストエディタで編集した場合はメニューバーの「設定ファイルを再読み込み」で再読込します。

読めない項目（手作業での編集ミスや、新しい版で追加された種類のルールなど）があっても、その項目だけを飛ばして残りを読み込みます。飛ばした項目は次の保存でファイルから消えるため、読み込み時点のファイルを同じフォルダに `config.json.partial-<日時>` として残し、内容を `~/Library/Logs/ConfigBox.log` に記録します。JSON として壊れている場合はサンプル設定を表示し、元のファイルを `config.json.broken-<日時>` として残します。

「設定 › 設定ファイル」の「設定を保存…」「設定を復元…」でバックアップできます。

- 復元の直前に、現在の設定を同じフォルダの `config.before-restore.json` にコピーします（最新の 1 回分のみ）。
- ConfigBox の設定ファイルでないものは拒否します。シェルや AppleScript のアクションを含むファイルは確認画面で警告します。
- 言語とログイン時の起動は macOS 側の設定に保存されるため、含まれません。

## 設計方針（軽量化のために）

- **常駐するのは CGEventTap 1 本と（ジェスチャ使用時のみ）マルチタッチのリスナーだけ。** 設定ウィンドウは閉じると SwiftUI 階層ごと解放されます。
- **単純なキー置換は hidutil に委譲。** システム設定の修飾キー変更と同じ経路で、ConfigBox が落ちても動き続け、処理コストがありません。終了時に自動で解除します。
- **スイッチャーのサムネイルは表示中だけ保持。** 閉じた瞬間に解放します。
- **常駐中はポーリングなし。** イベント駆動で動きます。定期更新は設定ウィンドウなどの表示中と、アクセシビリティ未許可時の再試行だけです。
- 実測（Apple Silicon, ウィンドウを閉じた状態）: メモリ（phys_footprint）約 13 MB、RSS 約 64 MB、CPU 0%。

## 構成

```
Sources/CBridge/                 MultitouchSupport（dlopen）と _AXUIElementGetWindow の C ブリッジ
Sources/ConfigBox/
  App/                           エントリポイント、メニューバー、権限、ウィンドウ管理
  Config/                        設定モデル（Codable JSON）、キーコード表、言語設定、設定の検証
  Engines/Keyboard/              EventTap, InputRouter, KeyRemapper（二役キー）, HIDUtil, KeySynth
  Engines/Trackpad/              マルチタッチフレーム → タップ / クリック / スワイプ認識、押し込み後のドラッグ継続
  Engines/Switcher/              ウィンドウ列挙、スイッチャー制御、オーバーレイ UI
  Engines/Windows/               ドラッグによるウィンドウスナップとプレビュー
  Engines/Viewer/                Event Viewer 用のイベント記録（ビューア表示中のみ動作）
  Actions/                       アクション実行、AX によるウィンドウ整列、システム操作
  UI/                            BTT 風の設定画面
Resources/                       Info.plist、アイコン、翻訳（ja.lproj）
```

## Karabiner の仮想 HID デバイスについて

Karabiner-Elements は DriverKit 製の仮想キーボード（Karabiner-VirtualHIDDevice）を使いますが、これは Apple が個別に発行する DriverKit エンタイトルメントと公証済みシステム機能拡張が必要で、手元のビルドでは再現できません。
ConfigBox はカーネル寄りのコードを入れない方針で、単純置換は Apple 標準の HID リマップ（`hidutil` の `UserKeyMapping`。システム設定の修飾キー変更と同じ経路）、ロジックが要るもの（二役キー・ショートカット）はユーザー空間のイベントタップで処理します。
HID Device Manager はこの層の「有効化 / 無効化 / 状態確認 / デバイス別適用 / 永続化」を担当し、VirtualHIDDevice-Manager の役割に相当します。

## 制限事項・注意

- macOS 自身が処理するジェスチャ（3 本指 / 4 本指スワイプ、2 本指タップなど）はそのまま動きます。ConfigBox 側で同じジェスチャを使う場合は「システム設定 › トラックパッド」で該当ジェスチャをオフにしてください。
- キーボードを限定したキー → アクションと Mod-Tap、および Caps Lock や無変換 / 変換を入力元にするルールは、HID レベルで予備キーに割り当ててから処理します（Karabiner の定石と同じ）。予備キーは F13〜F20、Keypad =、Keypad , の 10 個で、足りないルールは動作せず画面に警告が出ます。
- 使用中の予備キーを別のキーボードで押すと、そのルールが動きます。予備キーを別の用途で使っている場合は衝突します。F21〜F24 は macOS がキーイベントを届けないので使えません。
- 「JIS キーボードを ANSI として入力」は ConfigBox の起動中だけ有効で、種類が JIS のキーボードすべてが対象です。ANSI では ¥ と ろ に文字が割り当てられていないため、キーリマップのプリセットで補えます。
- 単純置換で修飾キー自体（例: 左 ⌃ 単押しで Esc）を二役にする場合、長押し時は本来の修飾キーとして動きます。
- 別のスペースにあるウィンドウへの切替は「システム設定 › デスクトップと Dock › アプリケーションの切り替え時に、開いているウィンドウがあるスペースに移動」が有効なときに動作します。
- HID レベルの単純置換はセキュア入力欄（パスワード欄）でも効きますが、イベントタップで処理する二役キーやショートカットはセキュア入力中は届きません。
- ウィンドウスナップは「ドラッグ開始後にウィンドウ位置が実際に動いたか」で判定するため、テキスト選択やスクロールバーのドラッグでは発動しません。大きさが変わるドラッグ（ウィンドウのリサイズ）でも発動しません。
- macOS 15 以降の「システム設定 › デスクトップと Dock › ウインドウ」にある「ウインドウを画面の左端または右端にドラッグしてタイル表示」「ウインドウをメニューバーにドラッグしてフルスクリーン表示」がオンだと、同じドロップに macOS も反応し、次にそのウィンドウをドラッグしたときに元の大きさへ戻されます。スナップを使う場合はオフにしてください（オンのときは「スナップ」タブに警告と設定を開くボタンが出ます）。
- Finder など多くのアプリは、マウスの戻る / 進むボタン（ボタン 4 / 5）に反応しません。「マウス › 設定 › ボタン」の一覧にあるアプリ（初期値は Finder）が最前面のときは、ボタン 4 / 5 と「マウスの戻る」「マウスの進む」アクションが、クリックの代わりに ⌘[ / ⌘] を送ります。
- 動かないショートカット（修飾キー単体など）や、同じキーを取り合うルールは、一覧に警告マークが付き、編集欄に理由が表示されます。保存や実行は止めません。
- MultitouchSupport は Apple の非公開フレームワークです（BTT 等も同じものを使用）。将来の macOS で利用できなくなった場合はトラックパッド機能のみ無効になります。

## デバッグ用起動オプション

```sh
build/ConfigBox.app/Contents/MacOS/ConfigBox --section trackpad|mouse|keyboard|remap|snapping|switcher|settings [--select-first]
build/ConfigBox.app/Contents/MacOS/ConfigBox --window eventViewer|hidManager
```

---

# English

ConfigBox is a native macOS app with no third-party dependencies that combines the everyday parts of BetterTouchTool, Karabiner-Elements and AltTab.
Instead of keeping three third-party binaries running, you run a single executable of about 5 MB that you build yourself.

| Replaces | How ConfigBox does it |
|---|---|
| BetterTouchTool | N-finger trackpad taps, double taps, clicks, double clicks and swipes (optionally limited to a corner, edge or half of the pad, or done while another finger rests elsewhere), mouse triggers (button clicks, modifier + scroll, button gestures) and keyboard shortcuts run actions such as window tiling, launching apps, media keys, dragging, and shell or AppleScript scripts. An optional setting keeps a drag going after the press is released, while a finger stays on the trackpad |
| Karabiner-Elements | Simple key remaps use macOS's own `hidutil` (no resident cost, per device if you like). Mod-Tap keys (tap for Esc, hold for ⌃, per device if you like), simultaneous keys (J + K → any action) and key macros (one key → several keys, text or actions, per device if you like) are handled in a CGEventTap |
| AltTab | A per-window switcher on ⌥Tab, with thumbnails (ScreenCaptureKit), minimized and hidden windows, and W / M / H / Q to act on windows |
| BTT window snapping | Drag a window to a screen edge or corner to see a translucent preview, then release to tile it to a half, a quarter or full size. Edges shared with another display can be ignored, and snapping can require a modifier |
| BTT snap areas (advanced) | Create, edit, manage, description and settings views like BTT's. A new area appears as a colored window that you simply move and resize. In edit mode every area is shown as such a window, and Settings… inside it sets the name, color, modifier and app condition. **Attach Window…** links a window frame to the area: place any window where you want it, press Attach, and windows dropped on the area take that frame. The manage window lists, duplicates, deletes and numerically edits areas. General settings cover opacity, name display, show delay and border width |
| Mouse utilities (like LinearMouse, Mos, Scroll Reverser) | Mouse › Settings: reverse the mouse wheel alone, vertically or horizontally (trackpads are unaffected), scroll speed, smooth scrolling, Shift + wheel for horizontal scrolling, pointer sensitivity (HID resolution, equivalent to DPI), acceleration off or custom, and buttons 4 / 5 as back / forward |
| Karabiner-EventViewer | The Event Viewer window shows, live, key events (code, name, modifiers and which feature handled them), the frontmost app's bundle ID and window title, HID devices and trackpad finger positions |
| Karabiner-VirtualHIDDevice-Manager | The HID Device Manager window activates or deactivates the HID-level remapping layer, shows the mappings actually installed in the system for each keyboard, removes all mappings including other tools', and manages a LaunchAgent that applies them at login |

The UI follows BetterTouchTool: app list on the left, trigger list in the middle, action settings on the right, and category tabs at the top.

Other features:

- **Japanese and English UI:** switch in Settings › General › Language (the system language by default).
- **Save and restore settings:** export to a JSON file and restore from it in Settings › Configuration File.
- **Type on JIS keyboards as ANSI:** turn this on in Settings › General to type US layout characters on a JIS keyboard.
- **Windows keyboards:** map 無変換 / 変換 to 英数 / かな with a Key Remapping preset.

## Build and run

```sh
./scripts/build-app.sh          # creates build/ConfigBox.app (release, -Osize)
open build/ConfigBox.app
```

Requires macOS 14 or later and Xcode 15 or later (Swift 5.9+). There are no external packages. The app is built for the architecture of the machine that builds it.

Run the unit tests with `swift test`. They cover the parts that touch neither input nor the screen: loading and validating the configuration, the smooth scrolling arithmetic, window tiling geometry and the like.

### Code signing (important)

Accessibility and Screen Recording grants are tied to the code signature. With ad-hoc signing you would have to grant them again after every build, so the build script uses the first valid code signing identity in your keychain (self-signed is fine).
To choose one, run `CODESIGN_IDENTITY="Certificate Name" ./scripts/build-app.sh`.
A self-signed build is not notarized, so Gatekeeper blocks it if you distribute it to other Macs.

### Permissions

- **Accessibility** (required): key remapping, shortcuts and the window switcher
- **Screen Recording** (optional): only for thumbnails in the switcher. App icons are shown without it
- **Input Monitoring** (optional): only to tell keyboards apart, for Simultaneous Keys rules limited to one keyboard and for keyboard-limited Key → Actions rules once the spare keys run out

You can grant these from the Settings tab. If something does not respond after granting, relaunch the app once.

## Configuration file

`~/Library/Application Support/ConfigBox/config.json`. Changes in the UI are saved automatically.
After editing it in a text editor, choose Reload Config File in the menu bar.

An entry that cannot be read (a hand edit gone wrong, or a kind of rule added by a newer version) is skipped and the rest is loaded. Skipped entries disappear from the file at the next save, so the file as it was is kept in the same folder as `config.json.partial-<timestamp>` and the details go to `~/Library/Logs/ConfigBox.log`. If the file is not valid JSON at all, the sample configuration is shown and the original is kept as `config.json.broken-<timestamp>`.

Use Save Settings… and Restore Settings… in Settings › Configuration File for backups.

- Just before restoring, the current settings are copied to `config.before-restore.json` in the same folder (latest restore only).
- Files that are not ConfigBox settings are rejected. Files containing shell or AppleScript actions trigger a warning in the confirmation dialog.
- The language and Launch at login are not included, because macOS stores them separately.

## Design principles (staying lightweight)

- **Only one CGEventTap stays resident, plus the multitouch listener when gestures are in use.** The settings window releases its whole SwiftUI hierarchy when closed.
- **Simple remaps are delegated to hidutil.** This is the same path as the modifier key settings in System Settings. They keep working if ConfigBox crashes, have no processing cost, and are removed automatically when ConfigBox quits.
- **Switcher thumbnails are kept only while it is showing.** They are released the moment it closes.
- **No polling while resident.** ConfigBox is event driven. Periodic updates only happen while a window such as Settings is open, and to retry while Accessibility is not granted.
- Measured on Apple silicon with the window closed: about 13 MB of memory (phys_footprint), about 64 MB RSS, 0% CPU.

## Project layout

```
Sources/CBridge/                 C bridge for MultitouchSupport (dlopen) and _AXUIElementGetWindow
Sources/ConfigBox/
  App/                           Entry point, menu bar, permissions, window management
  Config/                        Settings model (Codable JSON), key code table, language setting, validation
  Engines/Keyboard/              EventTap, InputRouter, KeyRemapper (dual-role keys), HIDUtil, KeySynth
  Engines/Trackpad/              Multitouch frames → tap, click and swipe recognition; keeping a drag after the press
  Engines/Switcher/              Window enumeration, switcher control, overlay UI
  Engines/Windows/               Window snapping by dragging, and its preview
  Engines/Viewer/                Event recording for Event Viewer (only while it is open)
  Actions/                       Action execution, window tiling through AX, system operations
  UI/                            BTT-style settings UI
Resources/                       Info.plist, icons, translations (ja.lproj)
```

## About Karabiner's virtual HID device

Karabiner-Elements uses a DriverKit virtual keyboard (Karabiner-VirtualHIDDevice). It needs a DriverKit entitlement issued individually by Apple and a notarized system extension, so it cannot be reproduced in a local build.
ConfigBox deliberately avoids kernel-adjacent code. Simple remaps use Apple's own HID remapping (`hidutil`'s `UserKeyMapping`, the same path as the modifier key settings in System Settings), and anything that needs logic (dual-role keys, shortcuts) runs in a user-space event tap.
HID Device Manager activates, deactivates, inspects, applies per device and persists this layer, which is the role VirtualHIDDevice-Manager plays.

## Limitations and notes

- Gestures macOS handles itself (three- and four-finger swipes, two-finger tap and so on) keep working. To use the same gesture in ConfigBox, turn it off in System Settings › Trackpad.
- Key → Actions and Mod-Tap rules limited to one keyboard, and rules whose source is Caps Lock or 無変換 / 変換, first map the key to a spare key at the HID level (the usual Karabiner technique). The spare keys are the 10 keys F13–F20, Keypad = and Keypad ,. Rules that do not get one do not work, and a warning appears in the UI.
- Pressing a spare key that is in use on another keyboard runs its rule, and it conflicts with any other use of that key. F21–F24 cannot be used because macOS delivers no key events for them.
- Type on JIS keyboards as ANSI only works while ConfigBox is running, and applies to every keyboard of JIS type. The ANSI layout has no characters on ¥ and ろ, which a Key Remapping preset can make up for.
- When a modifier itself is made dual-role (for example left ⌃ alone for Esc), it acts as the normal modifier when held.
- Switching to a window in another Space works when System Settings › Desktop & Dock › "When switching to an application, switch to a Space with open windows for the application" is on.
- HID-level simple remaps work in secure input fields (password fields), but dual-role keys and shortcuts handled in the event tap do not reach them during secure input.
- Window snapping checks whether the window actually moved after the drag started, so selecting text or dragging a scroll bar does not trigger it. Neither does a drag that changes the window's size (resizing it).
- On macOS 15 and later, with "Drag windows to left or right edge of screen to tile" or "Drag windows to menu bar to fill screen" on in System Settings › Desktop & Dock › Windows, macOS acts on the same drop too and puts the window back to its previous size the next time you drag it. Turn them off when you use snapping (while one is on, the Snapping tab shows a warning with a button that opens those settings).
- Finder and many other apps ignore a mouse's back / forward buttons (buttons 4 / 5). While an app in the list under Mouse › Settings › Buttons (Finder by default) is frontmost, buttons 4 / 5 and the Mouse Back / Mouse Forward actions send ⌘[ / ⌘] instead of a click.
- Shortcuts that cannot fire (such as a modifier key on its own) and rules that compete for the same key get a warning mark in the list and an explanation in the editor. Nothing is blocked from being saved or run.
- MultitouchSupport is a private Apple framework (BTT and others use it too). If a future macOS removes it, only the trackpad features are disabled.

## Debug launch options

```sh
build/ConfigBox.app/Contents/MacOS/ConfigBox --section trackpad|mouse|keyboard|remap|snapping|switcher|settings [--select-first]
build/ConfigBox.app/Contents/MacOS/ConfigBox --window eventViewer|hidManager
```
