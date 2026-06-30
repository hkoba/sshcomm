# プラグイン機構と補助モジュール（host-setup ほか）

`sshcomm.tcl` 本体に加え、リポジトリには「リモートへ転送して使う」ことを前提とした
補助モジュール群があります。本書はそのプラグイン機構と、各補助モジュールを解説します。

> **現役 / 非推奨の区別（2026-06 時点・作者方針）**
>
> | モジュール | 状態 | 備考 |
> |---|---|---|
> | プラグイン機構（`register-plugin` / `-plugins` 転送、§1） | **実験的** | ~10年使用実績なし。テスト免除（`sshcomm.tcl` にも `# EXPERIMENTAL`）|
> | `utils.tcl` のユーティリティ（`::sshcomm::utils`） | **現役** | 本体が `askpass-helper` で依存。[api-reference.md](api-reference.md) §6 |
> | `hostsetup.tcl`（`::host-setup`、§2・§3） | **非推奨** | 近年使われていない。以下は経緯・実装の記録として残す |
> | `git-ssh-proxy.tcl`（§4） | **ほぼ非推奨** | 数年使われていない。将来復活の可能性は残す |
>
> 補足: `utils.tcl` は `register-plugin` を呼ぶが、その**ユーティリティ自体は本体から直接使われ現役**。
> 「プラグインとして登録・一括転送される」経路だけが実験的（休眠）、という切り分け。
>
> 非推奨モジュールのパッケージング上の扱い（分離案）は
> [improvement-notes.md](improvement-notes.md) §3 を参照。

## 1. プラグイン機構【実験的】

> ⚠️ **実験的（experimental）**。`register-plugin` による登録と `-plugins` でのリモート一括転送は
> ~10年使用実績がなく、テストを免除する。`sshcomm.tcl` のコードにも `# EXPERIMENTAL` を明記。
> ただし `utils.tcl` のユーティリティ自体は本体が直接使うため現役（上の表の切り分けを参照）。

### 仕組み

- `sshcomm::register-plugin ?ns?`（`sshcomm.tcl:45`）が名前空間を `pluginList` に登録する。
- `utils.tcl` / `hostsetup.tcl` / `git-ssh-proxy.tcl` は、**読み込まれた時点で**
  `register-plugin` の存在を確認してから自分自身を登録する（`sshcomm` 未ロードでも単体で動く防御）。
- `sshcomm::ssh`（`sshcomm.tcl:33`）は `-plugins [list-plugins]` を付けて `connection` を生成する。
- `connection` は `current-definition`（`:370`）で `::sshcomm` ＋プラグイン名前空間をまとめて
  `definition` 化し、`remote setup` 時にリモートへ転送する。

つまりプラグインとは **「リモートへ一緒に転送したい追加名前空間」** の登録の仕組みです。

### 重要な注意（パッケージング）

`pkgIndex.tcl` は **`sshcomm.tcl` しかロードしない**。よって:

- `package require sshcomm` だけでは `utils` / `host-setup` / `git-ssh-proxy` は登録されない。
- これらを使う・転送するには、利用側で明示的に `source` する必要がある。
- `sshcomm.tcl` の `askpass-helper`（`:148`）は `::sshcomm::utils::askpass` を呼ぶため、
  utils 未ロードだと実行時に失敗する暗黙依存がある。

→ 改善候補。[improvement-notes.md](improvement-notes.md) を参照。

## 2. host-setup — 宣言的構成管理 DSL（`hostsetup.tcl`）【非推奨】

> ⚠️ **非推奨（deprecated）**。`::host-setup` は近年使われておらず、新規利用は推奨しない。
> 以下は設計の経緯と実装内容を記録として残すもの。`sshcomm` 本体の利用には不要。

`::host-setup` 名前空間は、**冪等な「ルール／ターゲット」でホスト設定を収束させる**
小さな構成管理フレームワーク（Ansible/Chef の極小版）です。
`sshcomm` でリモートへ転送し、リモート側で「あるべき状態」を適用する用途を想定していました。

### 2.1 基本概念

- **rule**: 関連するターゲットをまとめた単位。内部的には1つの `snit::type` にコンパイルされる。
- **target**: 個々の収束単位。`check`/`ensure`（判定）と `action`（適用）を持つ。
- **check-all / apply-all**: ルール内の全ターゲットを順に検査／適用する（型に自動生成される）。

### 2.2 `rule` の定義（`hostsetup.tcl:120`）

```tcl
rule etc-git {
    -title "..."          ;# 必須。-title が無いとエラー
    -prefix ""            ;# 各オプションは option として型に展開される
    -etc /etc
    {-user
        help "git config user.name に使う"
        subst {[exec git config user.name]}   ;# 既定値を式で算出
    } ""
} {
    target gitignore { ... }
    target git-init  { require "gitignore" ... }
    ...
}
```

- ルール名 `__FILE__` を指定すると、ソースファイル名（拡張子なし）がルール名になる。
- `build-opts`（`:95`）がオプション仕様を解析し、`option` 宣言列に変換。
  `help`/`default`/`subst`/`type`（`textarea` 等のUIヒント）を持てる。
- ルール本体は `type_template`（`:16`）に `string map` で埋め込まれ、`snit::type` としてコンパイルされる。
- コンパイル失敗時、環境変数 `DEBUG_HOSTSETUP` が真なら詳細な
  `snit::compile` 結果を含めてエラーを投げる（デバッグ支援）。

### 2.3 `target` マクロ（`hostsetup.tcl:198`、`snit::macro`）

各ターゲットは次の3要素で定義します。

| キー | 役割 |
|---|---|
| `check` / `ensure` | 「望ましい状態か」を判定。`{真偽 詳細...}` を返す（`ensure` 省略時は `check` を流用）|
| `action` | 望ましくない時に実行する収束処理 |
| `require` | 先行すべき他ターゲット名（依存）|
| `doc` | 説明文 |

生成される `ensure $target` メソッドは、`check` を評価し、

- 真 → `yes`
- 偽 → `action` を実行してから再 `check`

という **「判定→適用→再判定」** の冪等ループを行います（`hostsetup.tcl:225`）。

### 2.4 ライフサイクルフック

- `initially body`（`:241`）→ `initialize` メソッド。`reset` 時に呼ばれる。
- `finally body`（`:238`）→ `finalize` メソッド。`apply-all` 成功後に呼ばれる。
- `reset`（テンプレート内）: `state*` 変数を初期化して `initialize` を呼ぶ。

### 2.5 型に自動生成される操作

`type_template`（`hostsetup.tcl:16`）より:

- `{list target}`（typemethod）: ターゲット名一覧
- `check-all`: 全ターゲットを検査。最初の NG で `{NG ... OK ... DEBUG ...}` を返す
- `apply-all`: 全ターゲットを適用。`finalize` 後に結果を返す
- `doc $target` / `check $target` / `ensure $target`: ターゲット個別操作

### 2.6 ルールの登録・探索

| proc | 説明 |
|---|---|
| `rule-new name args`（`:73`） | ルール名から `snit::type` インスタンスを生成 |
| `list-rules`（`:90`） | 登録済みルール一覧 |
| `find-rule` / `find-type-of-rule`（`:79`/`76`） | ルール名→定義/型 |
| `list-targets-of-rule rule`（`:86`） | ルールのターゲット一覧 |
| `load-builtin-actions`（`:273`） | `action/*.tcl` を読み込み、組み込みルールとして記録 |
| `is-builtin-rule`（`:283`） | 組み込みルールか（組み込みは再定義を許容）|
| `import-into` / `source-once`（`:251`/`257`） | 補助ソースの取り込み（多重 source 防止）|

> 補足: マクロ内で使う proc は `proc` ではなく `_proc` で定義する必要がある
> （`utils` 変数内の `from` / `__EXPAND`、`:177`〜）。snit::macro のコンパイル文脈の都合。

## 3. 組み込みルール（`action/*.tcl`）【非推奨】

> ⚠️ host-setup（§2）の一部であり、同様に **非推奨**。`host-setup` DSL の実例としての記録。

`load-builtin-actions` で読み込まれる組み込みルール群。`host-setup` DSL の実例にもなっています。

### `etc-git`（`action/etc-git.tcl`）
`/etc` を git 管理下に置く。ターゲット: `gitignore`（`.gitignore` 設置）→ `git-init`
（`git init --shared=0600`）→ `git-config`（user.name/email 設定）→ `commit-all`
（未コミット変更を `git add -A && git commit`）。`require` で順序を表現。

### `sshd_config`（action/sshd_config.tcl）
`sshd_config` のパスワードログインを無効化。`initially` で設定ファイルを読み、
各ターゲット（`PasswordAuthentication no` 等）を `test`→`do APPEND/REPLACE/OK` で収束し、
`finally` で書き戻して sshd を再起動（`systemctl`/`service` を自動判別）。
正規表現で設定行を検出・置換し、重複設定があればエラーにする防御つき。

### `copy-uploaded-sysroot`（action/copy-uploaded-sysroot.tcl）
`/root/upload/sysroot/*` を `/` へ展開コピー。`target copied` で
missing/size-diff/content-diff を検出して差分のみコピー（mtime・属性も保持）。
加えて `/root` `/etc/pki/tls/private` `/etc/sudoers.d` の所有者・パーミッションを収束。

## 4. git-ssh-proxy（`git-ssh-proxy.tcl`）【ほぼ非推奨】

> ⚠️ **ほぼ非推奨**。数年使われていない。ただし多段 SSH／接続多重化のニーズが再来すれば
> 復活もありうるため、削除はせず実装の記録として残す。

SSH の **ControlMaster** を使った `GIT_SSH` プロキシスクリプトを生成する独立モジュール
（snit::type ＋ CLI）。多段 SSH（踏み台越し）や接続多重化のための補助。

- `connect`（`:73`）: `ssh -A -M -o ControlPath=...` でマスタ接続を張り、
  生成した zsh スクリプトのパスを `$::env(GIT_SSH)` に設定。
- 生成スクリプト（`ourScriptTemplate`、`:91`）は zsh の `zparseopts` で ssh オプションを解釈し、
  対象ホストが元ホストと同じならマスタソケット経由（`ssh -S`）、異なれば
  元ホストを踏み台にした2段 ssh（`ssh -A -S $orig ssh -q $opts $host`）を行う。
- `scriptFn`（`:31`）は一時ディレクトリを `/run/user/<uid>` → `~/.ssh/tmp` の順で決定。
- CLI として直接実行も可能（`:127`、`tclsh git-ssh-proxy.tcl host ...`）。

これは `sshcomm` 本体の `-prefer-git-ssh`（`$GIT_SSH` を優先利用）と組み合わせることで、
sshcomm の接続自体を踏み台・多重化経由にできる、という連携を想定した部品です。
