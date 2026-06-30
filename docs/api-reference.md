# API リファレンス

調査時点（バージョン 0.4）のコードから抽出した、実装ベースのAPI一覧です。
公式マニュアル（`sshcomm.man` 等）は現状ほぼ雛形のみのため、本書がより網羅的です。

## 1. トップレベル API（`::sshcomm`）

| コマンド | 定義 | 説明 |
|---|---|---|
| `sshcomm::comm host ?args?` | `sshcomm.tcl:30` | プール経由で接続を確立し、`comm` を1本作って comm id を返す。最短経路。 |
| `sshcomm::ssh host ?args?` | `sshcomm.tcl:33` | `connection` オブジェクトを新規生成（`-plugins [list-plugins]` 込み）。複数 comm を作る設定可能スタイル向け。 |
| `sshcomm::connection %AUTO% -host host ?...?` | `sshcomm.tcl:172` | 接続オブジェクトを直接生成（snit::type）。 |
| `sshcomm::configure ?-debuglevel n? ?-debugchan ch? ?-sshcmd cmd?` | `sshcomm.tcl:97` | グローバル設定。未知オプションはエラー。 |
| `sshcomm::register-plugin ?ns?` | `sshcomm.tcl:45` | **【実験的】** 名前空間をプラグインとして登録（省略時は呼び出し元の現在名前空間）。~10年未使用・テスト免除 |
| `sshcomm::list-plugins` | `sshcomm.tcl:53` | **【実験的】** 登録済みプラグイン名前空間のリスト。 |
| `sshcomm::list-connections` | `sshcomm.tcl:69` | プール内のホスト名一覧。 |
| `sshcomm::forget host` | `sshcomm.tcl:73` | プールから当該接続を破棄。 |
| `sshcomm::forget-all` | `sshcomm.tcl:81` | プール内全接続を破棄。 |

### 使い方の2スタイル

```tcl
# (1) 最短: プール経由
set cid [sshcomm::comm $host]
comm::comm send $cid {script...}
$cid command args...    ;# 糖衣構文。ただし args はローカルで評価される点に注意

# (2) 設定可能・多重 comm
set ssh [sshcomm::ssh $host]                       ;# = connection %AUTO% -host $host -plugins ...
set c1 [$ssh comm new]
set c2 [$ssh comm new]
comm::comm send -async $c1 {script...}
comm::comm send -async $c2 {script...}
```

## 2. `sshcomm::connection` のオプション

`sshcomm.tcl:172`〜。`option` 宣言から抽出（既定値つき）。

| オプション | 既定 | 用途 |
|---|---|---|
| `-host` | `""` | 接続先。`host` または `host:port`。**リスト指定可**（最後の要素がホスト、手前は追加 ssh 引数として扱われる）|
| `-lport` | `""` | ローカル転送ポート（空/0なら自動探索）|
| `-rport` | `""` | リモート転送ポート（空なら自動探索）|
| `-localhost` | `127.0.0.1` | フォワード先ローカルアドレス（IPv6 回避のため IPv4 既定）|
| `-sshcmd` | `""` | ssh コマンドを明示指定（指定時はプラットフォーム分岐をスキップ）|
| `-ssh-args` | `""` | フォワーダとホストの間に挿入する追加引数（ブランチ `15-ssh-args` で追加）|
| `-ssh-verbose` | `no` | `ssh -v`（および `2>@ stderr`）|
| `-autoconnect` | `yes` | コンストラクタで自動 `connect` するか |
| `-tclsh` | `tclsh` | リモートで起動する tclsh のコマンド名 |
| `-sudo` | `no` | リモートで `sudo` を介して tclsh を起動 |
| `-sudo-askpass-path` | `""` | 外部 askpass ヘルパのパス（→ `SUDO_ASKPASS` + `sudo -A`）|
| `-sudo-askpass-command` | `""` | パスワードを返す Tcl コールバック（→ `sudo -S`）|
| `-env-lang` | `""` | リモートの `LANG` 環境変数 |
| `-debug` | `no` | 全デバッグ機能を有効化（後述）|
| `-remote-config` | `{}` | リモート `remote::setup` へ渡す設定（例: `-verbose yes`）|
| `-plugins` | `{}` | **【実験的】** リモートへ転送する追加プラグイン名前空間（~10年未使用・テスト免除）|
| `-wait-after-probe` | `150` | ポート探索後の待機（ms）|
| `-sshcmd-platform` | `""` | `unix`/`windows`/`gcloud` を明示（既定は `tcl_platform`）|
| `-sshcmd-platform-options` | `""` | **【実験的】** プラットフォームコマンド自体への引数（例: gcloud の `--tunnel-through-iap`）。`gcloud sshcmd` 用・テスト免除 |
| `-strict-host-key-checking` | `yes` | `-o StrictHostKeyChecking=...` |
| `-forwardx11` | `yes` | `$DISPLAY` 有時 `-Y`（gcloud は `-X`）、無効時 `-x` |
| `-prefer-git-ssh` | `yes` | `$::env(GIT_SSH)` があれば優先利用 |
| `-ssh-options` | `""` | ssh/gcloud 直後に挿入する追加オプション |
| `-control-channel` | `pipe` | `socket` で制御チャネルを専用ソケットへハンドオフし、リモート stdout をアプリへ開放（[architecture.md](architecture.md) §3）|
| `-on-remote-output` | `""` | リモート stdout の各行を渡すコールバック（コマンドプレフィックス）。`-control-channel socket` 必須 |
| `-remote-stderr` | `local` | リモート stderr の扱い。現状 `local` のみ実装（`merge`/`channel` は未実装・指定するとエラー）|

### `-debug` の副作用（`sshcomm.tcl:196`）

`-debug` を真にすると:
- `-ssh-verbose yes`
- `-remote-config` に `-verbose yes` を追加
- `sshcomm::configure -debuglevel 3 -debugchan stderr`
- `-debug` が整数で `>= 3` のとき `::comm::comm(debug)` を 1 に

## 3. `connection` の主なメソッド（snit ensemble）

| メソッド | 定義 | 説明 |
|---|---|---|
| `connect ?args?` | `:238` | `remote open`→`remote prereq`→`remote setup` の一括実行 |
| `comm new` | `:437` | comm チャネルを1本作り comm id を返す |
| `comm init sock` | `:448` | 既存ソケットを comm に手動接続 |
| `comm forget cid` | `:467` | comm を shutdown して後始末 |
| `comm list` | `:478` | 生成済み comm id 一覧 |
| `forward new spec` | `:417` | Cookie 認証付きフォワード接続を確立（`spec`=`comm`/`raw`）|
| `forwarder` | `:496` | `-L lport:localhost:rport` を返す |
| `sshcmd ?args?` | `:514` | ssh コマンド行を組み立て（プラットフォーム分岐）|
| `unix sshcmd` | `:534` | 現役。`ssh` 用コマンド生成 |
| `windows sshcmd` | `:561` | **現役（重要）**。`plink` 用。テスト未整備→追加推奨 |
| `gcloud sshcmd` | `:574` | **【実験的】** `gcloud compute ssh` 用。ほぼ未使用・テスト免除 |
| `probe-remote-port host` | `:500` | リモートの空きポート探索 |
| `remote open/prereq/setup/...` | `:248`〜 | 接続確立の各段（内部）|
| `remote eval command` | `:321` | 制御チャネル経由の同期 RPC（貧者のRPC）|
| `rchan open cid fileName` | `:618` | **【実験的】** リモートファイルをローカルへストリーム（`r` のみ）|
| `rchan socketpair` | `:649` | **【実験的】** 生ソケット対を作る |

## 4. コード転送 API

| コマンド | 定義 | 説明 |
|---|---|---|
| `sshcomm::definition ?ns? ?args?` | `sshcomm.tcl:674` | 名前空間ツリーを再評価可能な Tcl ソースへシリアライズ |
| `sshcomm::definition-of-proc proc` | `sshcomm.tcl:662` | 単一 proc 定義の再構成 |
| `sshcomm::namespace-ancestry ns` | `sshcomm.tcl:723` | 祖先名前空間の列挙 |

README の例:
```tcl
namespace eval foo {proc x {} {list X}}
snit::type Dog { option -name "no name"; method bark {} {return "$options(-name) barks."} }
comm::comm send $cid [sshcomm::definition ::foo ::Dog]
$cid foo::x          ;# => X
$cid Dog d -name Hachi
$cid d bark          ;# => Hachi barks.
```

## 5. リモート側 API（`::sshcomm::remote`）

リモート `tclsh` 内で動く（転送される）サーバ。主に内部利用。

| コマンド | 定義 | 説明 |
|---|---|---|
| `remote::setup port args` | `sshcomm.tcl:752` | サーバソケット起動・keepalive・control 登録・`vwait` |
| `remote::accept sock addr port` | `:773` | 接続受理・アドレス検査・Cookie 検証・ハンドラ振り分け |
| `remote::accept__comm` / `__raw` | `:819` / `:814` | 種別別ハンドラ |
| `remote::cookie-add cookie ?spec?` | `:828` | Cookie 登録 |
| `remote::cookie-del cookie ?specVar?` | `:834` | Cookie 検証・消費（成功 1/失敗 0）|
| `remote::cget name default` | `:849` | リモート設定の取得 |
| `remote::keepalive msec` | `:864` | 定期 keepalive 出力 |
| `remote::control fh args` | `:869` | stdin から完全なコマンドを受け取り評価 |
| `remote::fread fn args` | `:894` | リモートファイル読み出し |
| `remote::dputs args` | `:859` | `-verbose` 時のみ stderr へログ |

## 6. ユーティリティ API（`::sshcomm::utils`、`utils.tcl`）

> 注意: `pkgIndex.tcl` は `sshcomm.tcl` のみをロードする。`utils.tcl` を使うには
> 別途 `source` が必要（`sshcomm.tcl` の `askpass-helper` は `::sshcomm::utils::askpass` に依存）。

代表的なもの（`utils.tcl`）:

- dict 系: `dict-default` / `dict-cut` / `dict-left-difference` / `dict-compare`
- リスト系: `lines-of` / `lgrep` / `lsearch-and-get`
- ファイル系: `read_file` / `read_file_lines` / `write_file` / `write_file_raw` /
  `write_file_lines` / `append_file` / `file-has` / `filelist-having` / `for-chan-line`
- その他: `scope_guard`（unset トレースで後始末）/ `shell-quote-string` /
  `catch-exec` / `catch-exec-noerror` / `default` / `is-empty` / `text-of-list-of-list`
- GUI: `askpass`（Tk のパスワード入力ダイアログ）
- sudo 連携: `create-echopass`（`SUDO_ASKPASS` 用の使い捨てスクリプト生成）

## 7. 非推奨 API（`sshcomm.tcl:906`〜）

| コマンド | 説明 |
|---|---|
| `sshcomm::client::create host` | `sshcomm::comm host` の旧名 |
| `sshcomm::sshcmd` | 引数なしの旧 sshcmd（`connection` のメソッド版に置換済み）|

## 8. テストの実行

```sh
# 既定では 127.0.0.1 を対象に統合テスト（事前に known_hosts へ登録が必要）
tclsh sshcomm.test
tclsh sshcomm.test -remote user@host -debuglevel 3 -para 4 -wait 3
```

- `-remote` はカンマ区切りで複数指定可。
- 接続不要のユニットテスト（`cget`/`cookie`/`unix sshcmd` の文字列生成）と、
  実 SSH を要する統合テストが混在している（[improvement-notes.md](improvement-notes.md) 参照）。
- **テスト方針**: 【実験的】機能（`gcloud sshcmd`・`-sshcmd-platform-options`・plugin 機構）は
  **テスト作成を免除**。一方 `windows sshcmd` は現役・重要のためテスト追加が望ましい
  （[README.md](README.md) のステータス凡例、improvement-notes §5 参照）。
