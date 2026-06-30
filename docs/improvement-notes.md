# 改良のための覚書

今後 `sshcomm` に改良を加えるにあたっての、調査で見つかった論点・技術的負債・改善候補の
一覧です。優先度は調査者の見立てに加え **作者の意向を反映** しています。

> **作者の方針メモ（2026-06 時点）**
> - **最優先テーマ**: 制御チャネルを SSH の stdin/stdout パイプから専用ソケットへ分離する（次節）。
> - `hostsetup.tcl`（`::host-setup`）は近年使っておらず **非推奨**。
> - `git-ssh-proxy.tcl` も数年使っておらず **ほぼ非推奨**（将来復活の可能性は残す）。
>   → 非推奨モジュールの位置づけは
>   [plugins-and-hostsetup.md](plugins-and-hostsetup.md) を参照。本書では §3「パッケージング」と
>   §9「優先順位」に影響する。

## 0. 最優先テーマ: 制御チャネルを専用ソケットへ分離する

> このテーマは作者が最も取り組みたい改良であり、同時に §1 の `remote redefine`×keepalive 競合
> （`sshcomm.tcl:368`）や §8 の `remote eval`/`lread` 混線を **根本から解消する基盤改善** でもある。

### 0.1 目的

リモート `tclsh` の **stdout/stderr をアプリケーションに開放する** こと。
リモートで実行したスクリプトの `puts` / `puts stderr` の出力を、
ローカルのアプリが自由に受け取れるようにしたい。

### 0.2 現状の制約 — なぜ今はできないか

制御チャネル `mySSH` は `open [list | ssh ... tclsh] w+`（`sshcomm.tcl:298`）で開いた
**SSH プロセスの stdin/stdout パイプ＝リモート `tclsh` の stdin/stdout そのもの** である。
この1本の上に、制御プロトコルが多重に乗っている。

- リモート側: `fileevent stdin readable [list ... control stdin]`（`:766`）で **stdin を制御コマンド受口** に占有。
- リモート側: `keepalive`（`:864`）が **stdout** へ `pid/時刻` を定期出力。
- ローカル側: `remote eval` の同期応答を **stdout** から `remote lread`（`:348`）で読む。

したがってリモートアプリが stdout/stderr を使うと、keepalive 行や `remote eval` 応答と**混線**する。
これは「制御プロトコルの伝送路」として stdin/stdout が **占有されている** ことの直接の帰結であり、
§1 の keepalive 競合・§8 の混線と同根の問題である。

### 0.3 提案 — 制御チャネルを `forward new raw` 由来の専用ソケットに移す

`forward new raw`（`:417`）＋ `accept__raw`（`:814`）は、Cookie 認証された **双方向の生 TCP ソケット**
を SSH フォワード上に確立する仕組みで、rchan 機能のために既に実装済みである。
これを制御チャネルとして使えば、stdin/stdout を解放できる。

- **制御チャネル＝専用 raw ソケット**（双方向の対話: コマンド送信＋応答受信）。
- **SSH の stdin/stdout パイプ＝アプリ用に開放**（リモート `tclsh` の素の標準入出力）。

> `rchan` 機能でも実現は可能だが、`rchan open` は read 専用・`rchan` は基本的にチャネルコピー向きで
> 片方向寄り。制御チャネルは双方向の往復が必要なため、**`forward new raw` の双方向ソケットが素直**。

### 0.4 ブートストラップの鶏卵問題と解法

`forward new` の Cookie 登録は「確立済みの制御チャネル」経由（`remote eval [cookie-add ...]`）で行う。
制御チャネル自体を raw ソケットにしたい場合、最初の Cookie 登録をどう行うかが問題になる。

→ **ブートストラップは従来どおり SSH パイプで行い、setup 完了後に制御チャネルだけを移す**段階設計で解ける。

1. SSH パイプを開き、`definition` を流し込んで `remote setup` まで完了（ここは現状のまま）。
2. SSH パイプ経由で `cookie-add $cookie control` を1回だけ登録し、`forward new` 相当で
   raw ソケットを1本張る（**ブートストラップ最後のステップ**）。
3. リモート側に制御用 accept ハンドラ（例: `accept__control`）を新設し、来たソケットへ
   `control` の `fileevent` を張る。`keepalive` の出力先もこのソケットへ切り替える。
4. リモートの **stdin `fileevent` を解除**。SSH パイプの stdin/stdout を以降アプリへ。
5. 以降の `comm new` / `forward new` の Cookie 登録は **制御ソケット経由** に切り替える。

### 0.5 既存資産による足がかり（朗報）

- **`remote::control` は既に汎用**: `control fh args`（`:869`）は任意チャネル `fh` から完全な
  コマンドを読んで評価する実装で、`control stdin` として呼ばれているだけ。`control $controlSock`
  に差し替えるだけで再利用できる。**設計が既に分離しやすい形**になっている。
- **`forward new raw` / `accept__raw` が既存**: 制御ソケットの土台がそのまま使える。
- **`comm init`（`:448`）の「既存ソケットにプロトコルを手で被せる」技法**が、制御ソケットへ
  `fileevent` ベースの制御プロトコルを組むときの参考になる。

### 0.6 ローカル側の変更点

- `mySSH` の `readable` ハンドラ（`remote readable`、`:484`）を、制御プロトコル解釈から
  **アプリ出力のパススルー／コールバック** へ変更（例: リモート stdout を読むチャネル/コールバックAPIを提供）。
- **stderr の開放**: 現状は `-ssh-verbose` 時のみ `2>@ stderr`（`:294`）。アプリに stderr を渡すなら、
  常時 Tcl チャネルへ向ける（`open` 時のリダイレクト設計を見直す）必要がある。
- **死活監視**: 現在は SSH パイプの `eof`（`:488`）で検出。keepalive を制御ソケットへ移すと、
  SSH パイプとは別に **制御ソケットの生存監視** が要る。
- **終了シーケンス**: destructor は `puts $mySSH "exit"`（`:222`）で SSH パイプ経由にリモートを落とす。
  制御を別ソケットに移したら、exit をどのチャネルから送るか整理する。

### 0.7 副次効果（既存課題の同時解消）

- §1 `sshcomm.tcl:368` の `remote redefine`×keepalive 競合 → 解消。
- §8 の `remote eval`/`lread` の stdout 混線 → 解消。
- accept の非ブロッキング read・Cookie 長さ制限は **地ならし(b) で先行解決済み**（`read-cookie`）。
  Phase 2 の `control` 非ブロッキング化はこれとは別物（socket 越しの部分行対策）。

### 0.8 課題・リスク

- ブートストラップ順序が複雑化する。段階移行のため、当面は **`-control-channel pipe|socket` のような
  切替オプション** を設けて両モードを並存させると安全。
- 制御ソケットの確立失敗・切断時のフォールバックとエラー処理。
- セキュリティ面はむしろ向上: 制御チャネルは `uplevel #0` で任意コードを実行するので、Cookie 認証＋
  localhost 限定（`:777`）が効く専用ソケットに乗せるのは妥当（§2 とも整合）。

## 1. コード中に明示された既知の課題（`XXX` / `BUG` コメント）

実装者自身が残したマーカー。改良の起点として最も信頼できる。

| 箇所 | 内容 | コメント原文の要旨 |
|---|---|---|
| `sshcomm.tcl:62` | プールは host のみをキーにし、2回目以降の `args` を無視 | `XXX: $args are ignored for the second call. Is this ok?` |
| `sshcomm.tcl:255` | ポート探索後の待機がブロッキング `after` | `XXX: event loop` |
| `sshcomm.tcl:302` | sudo askpass プロンプト待ちでブロックしうる | `XXX: This can block` |
| `sshcomm.tcl:368` | keepalive 稼働中は `remote redefine` が機能しない可能性 | `XXX:BUG This may not work when ... keepalive is active.` |
| `sshcomm.tcl:407` | リモート pid を記録すべき | `XXX: Should record remote pid` |
| `sshcomm.tcl:456` | comm チャネル選択が決め打ち | `set chan ::comm::comm; # XXX: ok??` |
| `sshcomm.tcl:443` | comm id ごとに proc を生やすのは過剰か | `# Too much?` |
| ~~`accept` の Cookie 読みが非ブロッキングでない~~ | **✅ 解決済み**（地ならし(b)） | 旧 `XXX: Should use non blocking read`。`read-cookie`（イベント駆動）に置換 |
| ~~Cookie 行の長さ制限がない~~ | **✅ 解決済み**（地ならし(b)） | 旧 `XXX: Should limit read length`。`read-cookie` で上限＋タイムアウト |

### 特に注意すべきもの

- **`remote redefine` × keepalive の競合（`:368`）**: 制御チャネルは keepalive が定期的に
  stdout へ書き込むため、`remote eval` の同期 read（`remote lread`、`:348`）が keepalive 行と
  混線するおそれ。コメントは「代わりに `comm::comm send $cid [sshcomm::definition $ns]` を使え」と示唆。
  → **§0 の制御チャネル専用ソケット化で根本解消できる**（最優先テーマ）。
- **ブロッキング `after`（`:255`）と sudo 待ち（`:302`）**: イベントループと噛み合っておらず、
  GUI/非同期アプリに組み込むと固まる。非同期化が望ましい。

## 2. セキュリティ上の論点

- **Cookie の乱数品質（`sshcomm.tcl:418`）**: `[clock seconds].[expr {int(1e8*rand())}]`。
  `rand()` は暗号論的に安全でない。ローカルポートは SSH 越しなので攻撃面は限定的だが、
  リモート上の他ユーザに対する防御を厳密にするなら CSPRNG（例: `/dev/urandom`）を検討。
- **attackers の計上のみ（`sshcomm.tcl:778`,`789`）**: 非 localhost / 不正 Cookie の接続を
  カウントするだけで、能動的なブロックやレート制限・通知はない。観測用に留まっている。
- **`remote::control` の任意コード実行（`sshcomm.tcl:886`）**: 制御チャネルから受けた文字列を
  `uplevel #0` で評価する。これは設計上の前提（SSH で守られた信頼チャネル）だが、
  ドキュメントで信頼境界を明示しておくと安全。
- **`shell-quote-string`（`utils.tcl:162`）に自信のないコメント**: `# XXX: Is this enough for
  /bin/sh's "...string..." quoting?`。シェル経由パスがあるなら見直し対象。

## 3. パッケージング / ロード周り

- **`pkgIndex.tcl` が `sshcomm.tcl` しかロードしない**:
  `utils.tcl` / `hostsetup.tcl` / `git-ssh-proxy.tcl` は `package require sshcomm` で読み込まれない。
  - `sshcomm.tcl:153` の `askpass-helper` は `::sshcomm::utils::askpass` に依存しており、
    utils 未ロードだと実行時エラーになる **暗黙依存**。
  - 改善案: (a) `sshcomm.tcl` 冒頭で `utils.tcl` を `source` する / (b) `pkgIndex.tcl` を
    `pkg_mkIndex` で再生成し各ファイルを別パッケージとして登録 / (c) 依存を明文化。
- **バージョン管理**: `pkgIndex.tcl`・`package provide`・man（`vset VERSION`）に `0.4` が散在。
  単一の出所（single source of truth）にまとめると保守が楽。
- **`.cvsignore` の残存**: CVS 由来の名残。git 移行済みなら整理候補。
- **非推奨モジュールの分離**: `hostsetup.tcl`（非推奨）・`git-ssh-proxy.tcl`（ほぼ非推奨）は
  現状でも `pkgIndex.tcl` でロードされず、利用側の明示 `source` 頼みになっている。
  非推奨化を機に、`deprecated/`（または `attic/`）等へ退避するか、ドキュメント・パッケージング上
  「現役（`sshcomm.tcl` / `utils.tcl`）」と明確に区別したい。
  `utils.tcl` は現役（本体が `askpass-helper` で依存）なので、非推奨組とは別扱いにすること。

## 4. Tcl 9 対応

- 宣言は `require Tcl 8.5` だが、調査環境は **Tcl 9.0.2 / snit 2.3.4 / comm 4.7.3** で動作。
- Tcl 9 では非互換変更が複数ある（エンコーディング既定、`chan`/`file` 周りの挙動、
  8進数リテラル `0NNN` の扱い等）。例えば `action/copy-uploaded-sysroot.tcl` の
  `040700` のような数値や、`git-ssh-proxy.tcl:84` の `00775` などパーミッション表記は要確認。
- 改善案: 8.5 と 9 の両対応を保つなら CI で両系列を回す。あるいは下限を 8.6/9 に引き上げて整理。

## 5. テスト

`sshcomm.test` の現状:

- **ユニット（接続不要）**: `remote::cget`、`cookie-add/del`、`unix sshcmd` の文字列生成。
  → これらは CI で常時実行できる。
- **統合（実 SSH 必須）**: `127.0.0.1` 等への実接続、comm 送受信、rchan、プール、並列接続。
  → `known_hosts` 登録と `StrictHostKeyChecking` の前提があり、CI で回しづらい。
- 改善案:
  - 接続不要テストと実接続テストを **明確に分離**（constraints やファイル分割）し、
    前者を GitHub Actions 等で常時グリーンに保つ。
  - **`windows sshcmd` の文字列生成テストを追加**（現状 `unix` のみ）。`windows` はテスト未整備だが
    長年利用の重要機能なので、`unix` 同様のテーブル駆動テストを整備したい。
  - **`gcloud sshcmd` / `-sshcmd-platform-options` / plugin 機構は【実験的】につきテスト免除**
    （[README.md](README.md) のステータス凡例参照）。将来 gcloud を常用に戻す際にテストを追加する。
  - 並列接続時の xauth/接続エラーが未処理である旨がテスト末尾コメント（`:291`〜）に残っている。
    競合の根本原因調査は積み残し。

### テスト免除の方針（experimental）

ほぼ使われていない機能は **「実験的(experimental)」** とし、テスト作成を免除する。
コードにも `# EXPERIMENTAL` を付し、本書・[README.md](README.md) の凡例と対応させる。

| 機能 | 区分 | テスト |
|---|---|---|
| `unix sshcmd` | 現役 | あり |
| `windows sshcmd` | 現役（重要） | 未整備 → **追加推奨** |
| `gcloud sshcmd` | 実験的 | **免除** |
| `-sshcmd-platform-options` | 実験的 | **免除** |
| plugin 機構（`register-plugin`/`-plugins`） | 実験的 | **免除** |
| `rchan`（`open`/`socketpair`） | 実験的 | 一部あり |

## 6. API の一貫性・命名

ssh 引数を注入する経路が **3つ** あり、挿入位置と意味が異なる。利用者が混乱しやすい。

| オプション | 挿入位置 | 想定用途 |
|---|---|---|
| `-ssh-options`（`:533`） | `ssh`/`gcloud` の直後（オプション群の先頭） | `-v` など ssh のグローバルオプション |
| `-ssh-args`（`:179`、本ブランチで追加） | フォワーダとホストの間（コマンド末尾寄り） | ホスト直前に置きたい追加引数 |
| `-sshcmd-platform-options`【実験的】（`:529`） | プラットフォームコマンド自体の引数 | `gcloud compute ssh --tunnel-through-iap` 等。`gcloud sshcmd` 用・テスト免除 |

- 改善案: 3者の役割をドキュメント（[architecture.md](architecture.md) §10 参照）で明示するか、
  将来的に整理・統合する。少なくとも README/man に使い分け例を載せたい。
- `-host` を **リスト** にして手前要素を ssh 引数にする隠し機能（`2982612` コミット）も、
  `-ssh-args` と機能が重複気味。意図と推奨用法を明文化したい。

## 7. ドキュメントの空洞

- **`sshcomm.man` / `.ja.man` / `.html` がほぼ雛形**。`description` が `[para]` 直後で途切れている。
  実体は README とコードにしかない。
- 本 `docs/` を一次情報として、doctools マニュアルを肉付けすると配布物として整う。
- README の「GitHub workflow でパッケージリリースを作る方法を知っていたら教えて」という
  募集コメント（`README.md:56`）は、リリース自動化の TODO として拾える。

## 8. リファクタ候補（設計レベル）

- **`::sshcomm::remote` の snit 化**: `sshcomm.tcl:736` に
  `# XXX: This should be snit too, but remote migration of snit::type is not yet...` とあり、
  リモート側コードを snit にできていない。`definition` が snit::type を転送できるよう拡張できれば、
  ローカル/リモートのコード対称性が上がる。
- **`comm init`（`:448`）が comm 内部に密結合**: `commNewConn`/`offerVers`/`defVers` 等、
  `comm` の内部APIに依存。`comm` のバージョン差異に弱い。バージョン互換層を設けると堅牢。
- **ロギング（`dlog`、`:110`）**: `-debugchan` が空のときは `debugLog` に溜め込むだけで、
  後から取り出す導線が無い（読み出しAPIが無い）。回収手段を用意するか整理。

## 9. 優先順位（作者の意向を反映）

「作者の最優先テーマ」と「着手しやすさ（リスクの低さ）」は別軸なので、両方を踏まえて並べる。

1. **【最優先】制御チャネルの専用ソケット化（§0）**。作者が最も取り組みたい大物であり、
   keepalive 競合・stdout 混線を一掃する基盤改善。設計変更を伴うため、下の 2〜3 を
   **地ならし**として先に済ませると、作り直し時の安全網になる。
2. **地ならし(a) テスト整備**: 接続不要テストの分離＋CI 化、`windows sshcmd` の
   文字列生成テスト追加（§5）。リグレッション検知の土台。`gcloud` は実験的につき免除。
3. **地ならし(b) 明示済みの小修正**: ✅ 完了。`accept` の Cookie 読みを `read-cookie`（非ブロッキング＋
   長さ上限＋タイムアウト）に置換し、接続不要ユニットテストを追加（§0.7）。
4. **低リスク・高効果のドキュメント整備**: man の肉付け、`-ssh-*` 3兄弟の使い分け明記、
   **非推奨（`hostsetup` / `git-ssh-proxy`）の明示**（§6・§7、[plugins-and-hostsetup.md](plugins-and-hostsetup.md)）。
5. **パッケージング整理**: `pkgIndex` / utils 暗黙依存の解消、非推奨モジュールの分離（§3）。
6. **積み残し**: ブロッキング `after` / sudo 待ちの非同期化（§1）、Tcl 9 対応（§4）、
   `remote` の snit 化・`comm` 内部依存の緩和（§8）。
