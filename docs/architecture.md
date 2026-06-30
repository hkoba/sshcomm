# アーキテクチャ

## 1. 設計目標と中心アイデア

`sshcomm` が解こうとしている課題は、

- `comm`（tcllib）の便利な「Tcl→Tcl のリモートスクリプティング」を使いたい
- しかし `comm` の素の TCP 接続は **平文・無認証** で、インターネット越しには使えない
- リモートホストに **エージェントを事前インストールしたくない**（`tclsh` だけ前提にしたい）

という3点です。これを次の3つの仕掛けで実現しています。

1. **SSH ポートフォワードによるトンネリング**
   `ssh -L lport:localhost:rport` でローカルの `lport` をリモートの `rport` に転送し、
   `comm` の TCP 通信をこのトンネルに通す。暗号化・認証は SSH に委譲する。

2. **コード転送（code shipping）によるブートストラップ**
   ローカル側が自分の名前空間（proc/ 変数 / ensemble）を Tcl ソースへシリアライズし
   （`::sshcomm::definition`）、SSH の stdin 経由でリモート `tclsh` に流し込んで再構築する。
   リモートに `comm` が無ければ `comm` 本体も同じ方法で送り込む。

3. **Cookie による接続認証**
   フォワードされた `rport` には、リモート上の他プロセスも接続できてしまう。
   そこで、確立済みの SSH 制御チャネル経由でワンタイム Cookie を事前登録し、
   フォワードソケットを開いた直後にその Cookie を送って初めて接続が受理される。

## 2. 名前空間構成

```
::sshcomm                     本体 API・接続プール・設定・ロギング・ユーティリティ
  ::sshcomm::connection       (snit::type) ローカル側の接続オブジェクト
  ::sshcomm::remote           リモート側で動くサーバコード（definition で転送される）
  ::sshcomm::client           非推奨 API（create）
  ::sshcomm::utils            汎用ユーティリティ（utils.tcl・プラグイン）【現役】
  ::sshcomm::git-ssh-proxy    GIT_SSH プロキシ生成（git-ssh-proxy.tcl・プラグイン）【ほぼ非推奨】
::host-setup                  宣言的構成管理 DSL（hostsetup.tcl・プラグイン）【非推奨】
```

> `git-ssh-proxy`（ほぼ非推奨）と `host-setup`（非推奨）の位置づけは
> [plugins-and-hostsetup.md](plugins-and-hostsetup.md) を参照。

`::sshcomm::remote` は **ローカルプロセス内にも定義として存在** しますが、実際に「サーバ」として
動くのはリモート `tclsh` 内に転送・再構築されたコピーです。ここが本ライブラリの理解の要点です。

## 3. 2チャネルモデル

1接続あたり、性質の異なる2種類のチャネルが存在します。

### (a) 制御チャネル — `mySSH`
- 実体は `open [list | ssh ... tclsh] w+` で開いた **SSH プロセスの stdin/stdout パイプ**
  （`sshcomm.tcl:298`）。
- 用途:
  - 初期ハンドシェイクの「貧者のRPC」（`remote eval`、`sshcomm.tcl:321`）
  - コード転送（`remote redefine` / `remote setup`）
  - Cookie 登録（`forward new` から `remote eval [cookie-add ...]`）
  - keepalive 行とリモート出力の受信（`remote readable`、`sshcomm.tcl:484`）
- リモート側では `::sshcomm::remote::control`（`sshcomm.tcl:869`）が stdin を `fileevent` で監視し、
  受信した完全な Tcl コマンドを `uplevel #0` で評価する。

### (b) comm チャネル — フォワードされた TCP ソケット
- `ssh -L` で張ったトンネル上に作る、実際の `comm` 接続。
- `comm new` のたびに新しいソケットを開く（複数の `comm` を1本のSSH上に多重化可能）。
- ここを `comm::comm send` のトラフィックが流れる。

> 制御チャネル＝「メタな指示と認証」、comm チャネル＝「実際のRPCペイロード」という分業。

> **制御チャネルのソケット化（実装済み・opt-in）**: 既定の `pipe` モードでは制御チャネルが SSH の
> stdin/stdout パイプを占有するため、リモートの stdout/stderr をアプリが自由に使えない。
> `-control-channel socket` を指定すると、`connect` 完了直後に制御チャネルを Cookie 認証付きの専用
> 転送ソケット（`accept__control`）へ**ハンドオフ**し、stdin を切り離してパイプをアプリの stdout に
> 開放する。以降の制御 RPC は per-seq `vwait`＋demux（`control-readable`）で送受信する。
> 設計の詳細・残課題は [improvement-notes.md](improvement-notes.md) §0。

## 4. 接続確立シーケンス

`connection connect`（`sshcomm.tcl:238`）は次の3段からなります。

### 4.1 `remote open`（`sshcomm.tcl:248`）

1. **リモート空きポート探索**: `rport` 未指定なら、`probe-remote-port`（`sshcomm.tcl:500`）が
   `ssh ... tclsh` を1回起動し、リモート上で `socket -server ... 0` を使った空きポート検出
   （`probe-port`、`sshcomm.tcl:130`）を実行して `rport` を得る。
   その後 `-wait-after-probe`（既定150ms）だけ `after` で待つ（`XXX: event loop`）。
2. **ローカル空きポート探索**: `lport` 未指定／0 なら `::sshcomm::probe-port` で取得。
3. **ssh コマンド組み立て**:
   ```
   set cmd [$self sshcmd {*}[$self forwarder] {*}$options(-ssh-args) {*}$host]
   ```
   - `forwarder`（`sshcomm.tcl:496`）= `-L lport:localhost:rport`
   - `-ssh-args` はフォワーダとホストの間に挿入（このブランチ `15-ssh-args` で追加）
   - `-ssh-verbose` 時は `ssh` 直後に `-v` を挿入
4. **環境・sudo の付与**: `-env-lang` で `env LANG=...`、`-sudo` 時は
   `-sudo-askpass-path`（外部ヘルパ→`sudo -A`）または `-sudo-askpass-command`（Tclコールバック→`sudo -S`）。
5. **パイプを開く**: `set mySSH [open [list | {*}$cmd] w+]`、行バッファに設定。
6. sudo を `-S`（askpass-command）で使う場合、`[sudo]` プロンプトを `remote expect` で待ち、
   パスワードを送る（`XXX: This can block`）。

### 4.2 `remote prereq`（`sshcomm.tcl:383`）

1. `remote eval {list ok}` が `"ok"` を返すか健全性チェック。
2. リモートで `package require comm` を試す。
   - 成功 → `myRemoteHasOwnComm = yes`
   - 失敗 → `comm` 本体を `::sshcomm::definition ::comm` で送り込み、`package provide` してから
     `package require comm` を再実行（`myRemoteHasOwnComm = no`）。

### 4.3 `remote setup`（`sshcomm.tcl:397`）

1. リモートの stdout/stderr を行バッファに設定。
2. `remote redefine` → `current-definition`（`sshcomm.tcl:375`）で
   `::sshcomm` ＋プラグイン名前空間の定義を生成し、`remote eval` で転送。
3. リモートで `::sshcomm::remote::setup $rport ...` を起動（後述）。
4. 戻り値が `"OK port $rport"` であることを確認。
5. ローカル側で `fileevent $mySSH readable [list $self remote readable]` を設定し、
   制御チャネルを非同期受信モードへ。

## 5. リモート側サーバの構造（`::sshcomm::remote`）

転送先のリモート `tclsh` 内で動くサーバ部分。

- **`setup port args`**（`sshcomm.tcl:752`）:
  `comm::comm` を destroy して作り直し、`socket -server accept $port` でサーバ起動、
  30秒ごとの `keepalive`、stdin の `control` fileevent を登録、`"OK port $port"` を出力、
  最後に `vwait forever` で **stdin から直接 read してしまわないよう** イベントループに入る。
- **`accept sock addr port`**（`sshcomm.tcl:773`）:
  接続元アドレスを検査し、`0.0.0.0`/`127.0.0.1` 以外は `attackers` に計上して即 close。
  1行目を Cookie として受信し、`cookie-del`（`sshcomm.tcl:834`）で検証・消費。
  Cookie の `kind` に応じて `accept__$kind` ハンドラへディスパッチ。
  - `accept__comm`（`sshcomm.tcl:819`）: `::comm::comm new $sock` ＋ `::comm::commIncoming` で
    既存ソケットを `comm` の機構に接続。
  - `accept__raw`（`sshcomm.tcl:814`）: ソケット識別子を返すだけ（`rchan` 用の生ソケット）。
- **`cookie-add` / `cookie-del`**（`sshcomm.tcl:828` / `827`）: ワンタイム Cookie の登録・検証・削除。
- **`keepalive msec`**（`sshcomm.tcl:864`）: 定期的に `pid/時刻` を stdout に出力（接続維持・死活）。
- **`control fh`**（`sshcomm.tcl:869`）: stdin から受け取った **完全な Tcl コマンドを** `uplevel #0` で評価。
  これが制御チャネル経由 RPC の受け口。

## 6. Cookie 認証の流れ（`forward new`）

`forward new spec`（`sshcomm.tcl:417`）が1本のフォワード接続を確立する手順:

1. **Cookie 生成**: `[clock seconds].[rand]`。
2. **登録**: 確立済み制御チャネル経由で `remote eval [cookie-add $cookie $spec]`。
   `spec` は接続種別（`comm` または `raw`）。
3. **フォワードソケットを開く**: `socket $localhost $lport`（→ リモート `rport` へ転送）。
4. **Cookie 送信**: ソケットの1行目として Cookie を送る。これが無いとリモートは接続を拒否。

リモート `accept` 側がこの Cookie を検証して、種別に応じたハンドラへ渡す（第5節参照）。

## 7. comm チャネルの生成（`comm new`）

`comm new`（`sshcomm.tcl:437`）:

1. `forward new comm` で Cookie 認証済みのフォワードソケットを得る。
2. `comm init sock`（`sshcomm.tcl:448`）で **`comm` の接続確立を手動で再現**:
   - `::comm::comm new $sock`
   - comm id を `[list $myLastCommID $host]` で採番
   - `::comm::commNewConn` を呼び、`offerVers`/`port`/`defVers` をソケットに書き込む
     （通常 `comm` が自前の connect/listen で行う handshake を、既に開いたトンネルソケットに対し代行）。
3. 利便のため `proc ::$cid args "comm::comm send [list $cid] \$args"` を定義
   （`$cid command args...` という糖衣構文。コード中に `# Too much?` のコメントあり）。

`comm forget`（`sshcomm.tcl:467`）は `comm shutdown` ＋ ソケット名衝突回避の後始末を行う。

## 8. コード転送（`::sshcomm::definition`）

ローカルの名前空間ツリーを **再評価可能な Tcl ソース** へシリアライズする中核機能。

- `definition-of-proc proc`（`sshcomm.tcl:662`）: `info args`/`info default`/`info body` から
  `proc` 定義を文字列再構成。
- `definition {ns args}`（`sshcomm.tcl:674`）: 指定名前空間（および追加名前空間）について
  - 祖先名前空間の `namespace eval ... {}`（`namespace-ancestry`、`sshcomm.tcl:723`）
  - 配下の全 `proc` 定義
  - 全変数（配列は `array set`、スカラは `set`）
  - `namespace export` パターン
  - `namespace ensemble`（存在すれば `namespace ensemble create` を再構成。`-parameters` は 8.5 非対応のため条件付きで除去）
  - 子名前空間を **再帰的に** 展開
  を1つの大きなスクリプトに連結して返す。

これにより `::sshcomm`（＋ `-plugins` で渡された名前空間、必要なら `::comm`）を
丸ごとリモートに再現できる。`current-definition`（`sshcomm.tcl:375`）が
`-plugins` を織り込んでこれを呼ぶ。

> `definition` 機構そのもの（`::sshcomm` / `::comm` の転送）は中核で**現役**だが、
> **任意の追加プラグインを `-plugins` で転送する使い方は実験的**（~10年使用実績なし、テスト免除）。
> 詳細は [plugins-and-hostsetup.md](plugins-and-hostsetup.md) §1。

## 9. rchan（リモートチャネル）— 実験的機能

リモートのファイル／チャネルの内容をローカルへストリームする実験機能
（`sshcomm.tcl:618` 以降、`snit::method` で別定義）。

- **`rchan socketpair`**（`sshcomm.tcl:649`）: `forward new raw` で生ソケット対を作り、
  `(localSock, remoteSock)` を返す。
- **`rchan reader cid script`**（`sshcomm.tcl:628`）: リモートで `script` を実行してチャネルを得て、
  `chan copy` でソケット対へ流し込む。完了時に `::sshcomm::close-all` で後始末。
- **`rchan open cid fileName`**（`sshcomm.tcl:618`）: リモートファイルを開いて読み出し用に返す
  （現状 `access=r` のみ対応）。

## 10. sshcmd プラットフォーム抽象化

実際に起動する ssh コマンド行は `sshcmd`（`sshcomm.tcl:514`）が組み立て、
`-sshcmd` 明示指定が無ければ `-sshcmd-platform`（既定は `tcl_platform(platform)`）に応じて
プラットフォーム別メソッドへディスパッチします。

| メソッド | 区分 | 用途 | 生成例の骨子 |
|---|---|---|---|
| `unix sshcmd`（`:534`） | 現役 | 通常の `ssh` | `ssh [-ssh-options] -o StrictHostKeyChecking=... -T (-Y|-x) [-p port] {prefix} host` |
| `windows sshcmd`（`:561`） | **現役（重要）** | PuTTY `plink` | `plink [-P port] {prefix} host` |
| `gcloud sshcmd`（`:574`） | **実験的** | `gcloud compute ssh` | `gcloud compute ssh {platform-opts} host -- {opts}` |

> `windows sshcmd` はテスト未整備だが長年利用されており重要。`gcloud sshcmd` はほぼ未使用で
> **実験的（テスト免除）**。コードにも `# EXPERIMENTAL` を明記。[README.md](README.md) の凡例参照。

関連オプション:

- `-prefer-git-ssh`（既定 yes）: `$::env(GIT_SSH)` があればそれを `ssh`/`gcloud` の代わりに使う。
- `-strict-host-key-checking`（既定 yes）→ `-o StrictHostKeyChecking=...`
- `-forwardx11`（既定 yes）＋ `$DISPLAY` 有 → `-Y`（gcloud は `-X`）、無効時は `-x`
- `-ssh-options`: `ssh`／`gcloud` 直後に挿入される追加オプション（`ssh -v` 等）
- `-sshcmd-platform-options`【実験的】: プラットフォームコマンド自体への引数（例: `gcloud compute ssh --tunnel-through-iap`）。`gcloud sshcmd` 用に追加されたもので、ほぼ未使用・テスト免除
- `parse-host-port`（`sshcomm.tcl:609`）: `host:port` 形式を分解して `-p`/`-P` を付与

> `-ssh-args`・`-ssh-options`・`-sshcmd-platform-options` の3者は挿入位置が異なる。
> 詳細と整理案は [improvement-notes.md](improvement-notes.md) を参照。

## 11. 接続プール

ホスト名をキーにした接続の使い回し（`sshcomm.tcl:57`〜）:

- `pooled_ssh host args`: プールにあれば再利用（**2回目以降 `args` は無視される**、コード内に疑問コメント）。
- `sshcomm::comm host` はこのプールを使う。`sshcomm::ssh` は毎回新規。
- `list-connections` / `forget host` / `forget-all`。`connection` の destructor もプール entry を掃除する。
