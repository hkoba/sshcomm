# 改良のための覚書

今後 `sshcomm` に改良を加えるにあたっての、調査で見つかった論点・技術的負債・改善候補の
一覧です。優先度は付与していますが、あくまで調査者の見立てであり、最終判断は作者に委ねます。

## 1. コード中に明示された既知の課題（`XXX` / `BUG` コメント）

実装者自身が残したマーカー。改良の起点として最も信頼できる。

| 箇所 | 内容 | コメント原文の要旨 |
|---|---|---|
| `sshcomm.tcl:57` | プールは host のみをキーにし、2回目以降の `args` を無視 | `XXX: $args are ignored for the second call. Is this ok?` |
| `sshcomm.tcl:250` | ポート探索後の待機がブロッキング `after` | `XXX: event loop` |
| `sshcomm.tcl:297` | sudo askpass プロンプト待ちでブロックしうる | `XXX: This can block` |
| `sshcomm.tcl:363` | keepalive 稼働中は `remote redefine` が機能しない可能性 | `XXX:BUG This may not work when ... keepalive is active.` |
| `sshcomm.tcl:402` | リモート pid を記録すべき | `XXX: Should record remote pid` |
| `sshcomm.tcl:451` | comm チャネル選択が決め打ち | `set chan ::comm::comm; # XXX: ok??` |
| `sshcomm.tcl:438` | comm id ごとに proc を生やすのは過剰か | `# Too much?` |
| `sshcomm.tcl:776` | accept のソケット読み取りが非ブロッキングでない | `XXX: Should use non blocking read` |
| `sshcomm.tcl:777` | Cookie 行の長さ制限がない（極端に長い行で問題） | `XXX: Should limit read length` |

### 特に注意すべきもの

- **`remote redefine` × keepalive の競合（`:363`）**: 制御チャネルは keepalive が定期的に
  stdout へ書き込むため、`remote eval` の同期 read（`remote lread`、`:343`）が keepalive 行と
  混線するおそれ。コメントは「代わりに `comm::comm send $cid [sshcomm::definition $ns]` を使え」と示唆。
  → 制御チャネルの同期RPCと非同期keepaliveの分離設計を見直す価値あり。
- **ブロッキング `after`（`:250`）と sudo 待ち（`:297`）**: イベントループと噛み合っておらず、
  GUI/非同期アプリに組み込むと固まる。非同期化が望ましい。

## 2. セキュリティ上の論点

- **Cookie の乱数品質（`sshcomm.tcl:413`）**: `[clock seconds].[expr {int(1e8*rand())}]`。
  `rand()` は暗号論的に安全でない。ローカルポートは SSH 越しなので攻撃面は限定的だが、
  リモート上の他ユーザに対する防御を厳密にするなら CSPRNG（例: `/dev/urandom`）を検討。
- **attackers の計上のみ（`sshcomm.tcl:769`,`784`）**: 非 localhost / 不正 Cookie の接続を
  カウントするだけで、能動的なブロックやレート制限・通知はない。観測用に留まっている。
- **`remote::control` の任意コード実行（`sshcomm.tcl:879`）**: 制御チャネルから受けた文字列を
  `uplevel #0` で評価する。これは設計上の前提（SSH で守られた信頼チャネル）だが、
  ドキュメントで信頼境界を明示しておくと安全。
- **`shell-quote-string`（`utils.tcl:162`）に自信のないコメント**: `# XXX: Is this enough for
  /bin/sh's "...string..." quoting?`。シェル経由パスがあるなら見直し対象。

## 3. パッケージング / ロード周り

- **`pkgIndex.tcl` が `sshcomm.tcl` しかロードしない**:
  `utils.tcl` / `hostsetup.tcl` / `git-ssh-proxy.tcl` は `package require sshcomm` で読み込まれない。
  - `sshcomm.tcl:148` の `askpass-helper` は `::sshcomm::utils::askpass` に依存しており、
    utils 未ロードだと実行時エラーになる **暗黙依存**。
  - 改善案: (a) `sshcomm.tcl` 冒頭で `utils.tcl` を `source` する / (b) `pkgIndex.tcl` を
    `pkg_mkIndex` で再生成し各ファイルを別パッケージとして登録 / (c) 依存を明文化。
- **バージョン管理**: `pkgIndex.tcl`・`package provide`・man（`vset VERSION`）に `0.4` が散在。
  単一の出所（single source of truth）にまとめると保守が楽。
- **`.cvsignore` の残存**: CVS 由来の名残。git 移行済みなら整理候補。

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
  - `windows`/`gcloud` sshcmd の文字列生成テストが無い（`unix` のみ）。同様のテーブル駆動テストを追加。
  - 並列接続時の xauth/接続エラーが未処理である旨がテスト末尾コメント（`:286`〜）に残っている。
    競合の根本原因調査は積み残し。

## 6. API の一貫性・命名

ssh 引数を注入する経路が **3つ** あり、挿入位置と意味が異なる。利用者が混乱しやすい。

| オプション | 挿入位置 | 想定用途 |
|---|---|---|
| `-ssh-options`（`:528`） | `ssh`/`gcloud` の直後（オプション群の先頭） | `-v` など ssh のグローバルオプション |
| `-ssh-args`（`:174`、本ブランチで追加） | フォワーダとホストの間（コマンド末尾寄り） | ホスト直前に置きたい追加引数 |
| `-sshcmd-platform-options`（`:524`） | プラットフォームコマンド自体の引数 | `gcloud compute ssh --tunnel-through-iap` 等 |

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

- **`::sshcomm::remote` の snit 化**: `sshcomm.tcl:729` に
  `# XXX: This should be snit too, but remote migration of snit::type is not yet...` とあり、
  リモート側コードを snit にできていない。`definition` が snit::type を転送できるよう拡張できれば、
  ローカル/リモートのコード対称性が上がる。
- **`comm init`（`:443`）が comm 内部に密結合**: `commNewConn`/`offerVers`/`defVers` 等、
  `comm` の内部APIに依存。`comm` のバージョン差異に弱い。バージョン互換層を設けると堅牢。
- **ロギング（`dlog`、`:105`）**: `-debugchan` が空のときは `debugLog` に溜め込むだけで、
  後から取り出す導線が無い（読み出しAPIが無い）。回収手段を用意するか整理。

## 9. 着手しやすい順（参考）

1. ドキュメント整備（man の肉付け、`-ssh-*` 3兄弟の使い分け明記）— 低リスク・高効果。
2. `pkgIndex` / utils 暗黙依存の解消 — 利用者のつまずきを直接減らせる。
3. 接続不要テストの分離＋CI 化、`windows`/`gcloud` sshcmd テスト追加。
4. Cookie 長さ制限・非ブロッキング read（`:776`-`777`）など、明示済みの小修正。
5. ブロッキング `after` / sudo 待ちの非同期化（イベントループ整合）。
6. `remote redefine` × keepalive 競合の根本対処、`remote` の snit 化（設計変更を伴う大物）。
