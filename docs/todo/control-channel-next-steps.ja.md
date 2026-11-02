# 制御チャネル ソケット化 — 残課題の計画

ブランチ `17-control-socket` で「制御チャネルの専用ソケット化」（[improvement-notes.md](improvement-notes.ja.md) §0）は
Phase 0–4 まで実装・検証済み（`-control-channel socket` で opt-in、既定は `pipe`）。
本書は **残る2課題** の計画を書き残すもの。

- 課題1: リモート **stderr** のアプリ開放（`-remote-stderr merge|channel` の実装）
- 課題2: `-control-channel` の **既定を `socket` に切り替えるか** の判断

実装済みの土台（参照）: `sshcomm.tcl` の `control-handoff` / `control-readable` / `accept__control` /
`forward new` / `remote app-output` / `-on-remote-output` / `gen-cookie`、および `docs/architecture.md` §3。

---

## 課題1: リモート stderr のアプリ開放

### 前提（なぜ難しいか）

SSH パイプは `open [list | ssh ... tclsh] w+` で開く **stdin+stdout のみ**。
リモート `tclsh` の stderr は ssh の stderr 経由でローカル ssh プロセスの stderr に出るだけで、
現状の `-remote-stderr local`（既定）は capture しない。`-on-remote-output` が拾うのは stdout だけ。
ただし下記のとおり、**ローカルで ssh プロセスの stderr を拾えば** capture できる（リモート無改変）。

### 本命: `channel` — ssh の stderr をローカルの `chan pipe` で受ける（✅ 実装済み）

> **実装済み**（ブランチ `17-control-socket`）。`-remote-stderr channel` ＋ `-on-remote-stderr`
> コールバックで動作し、pipe / socket 両モードで統合テスト済み。以下は設計メモ。

`ssh host cmd` は **cmd（リモート tclsh）の stderr を ssh プロセスの stderr(fd 2) へ中継**する。
かつ sshcomm は既に **`ssh -T`（PTY 無し）** で起動しており、リモートの stdout と stderr は
**別 fd に保たれる**（PTY だと統合されてしまう）。よって ssh の fd 2 をローカルの `chan pipe` に
振り向けるだけで、**リモート側の dup / `chan push` を一切使わず**に stderr を分離取得できる。

```tcl
# remote open の中で:
lassign [chan pipe] mySSHError writeErr
set mySSH [open [list | {*}$cmd 2>@ $writeErr] w+]
close $writeErr   ;# ★必須: 親が書き端を手放さないと mySSHError が永遠に eof にならない
fconfigure $mySSHError -buffering line
fileevent $mySSHError readable [list $self remote read-error]
```

`remote read-error` は行を読み、`-on-remote-stderr`（stdout 側 `-on-remote-output` と対称な
コールバック）へ配送する。

- **実証済み（この環境で確認）**:
  1. `2>@ $chan` が子プロセスの stderr を `chan pipe` に分離（stdout と混ざらない）。
  2. `ssh -T 127.0.0.1 tclsh` のリモート `puts stderr` がローカル stderr パイプに到達。
- **長所**:
  - リモート無改変（案の旧B「remote dup / `chan push`」は不要だった）。
  - **両モードで動く**（この stderr パイプは `-control-channel` と直交。pipe / socket どちらでも可）。
  - stdout/stderr を分離保持。
- **注意点**:
  1. `open` 直後の **`close $writeErr` が必須**（eof のため。子だけが書き端を持つ状態にする）。
  2. ssh 自身の診断（`-v` 出力・`Warning:`・接続エラー等）も同じ stderr に乗る。既存の
     `-ssh-verbose` の `2>@ stderr`（ssh stderr をローカル stderr へ）とは **排他**（fd 2 の行き先は一つ）。
     どちらを優先するか整合が要る（例: `-remote-stderr channel` 指定時は verbose 診断もパイプへ）。
  3. **destructor で `mySSHError` も close**。fd 衛生: 後続 ssh 子が read 端を継承しうるが無害
     （書き端は親が即 close 済みで継承されないので、この接続の stderr eof は正しく来る）。
  4. `gcloud` 等の代替 sshcmd でも「cmd の stderr を自プロセスの stderr に中継する」限り同様に動く
     （gcloud は実験的。要確認）。
- **テスト**: 接続必須の統合テストで、socket でも pipe でも
  `comm send {puts stderr "E"; flush stderr; list ok}` の `E` が `-on-remote-stderr` に届くこと。

### 任意: `merge` — stderr を stdout(パイプ)に統合

stdout/stderr を1本にまとめたい場合の簡易版。`remote open` のリダイレクトを stdout へ統合
（`2>@1` 相当、要 Tcl バージョン確認）し、socket モードで `-on-remote-output` に混在配送する。
`channel`（上記）があれば基本不要。アプリ側で混ぜたいなら `channel` の2コールバックを束ねればよい。

### 着手順（課題1）

1. **`channel` を実装**（`remote open` の stderr パイプ＋`close $writeErr`＋`remote read-error`＋
   `-on-remote-stderr` 配送＋`-ssh-verbose` との排他整理＋destructor で close＋統合テスト）。
2. （任意）`merge` が要望されれば別途。`channel` でほぼ代替できるため優先度低。

> メモ: 旧版では `channel` を「リモート側 dup が必要で難しい」としていたが、上記のローカル stderr
> パイプ方式（作者の指摘）で**リモート無改変かつ両モード対応**にできることを実測確認した。

---

## 課題2: `-control-channel` の既定を `socket` にするか

### 現状

既定は `pipe`（完全後方互換）。`socket` は opt-in。目的（リモート stdout 開放）は socket で達成済み。

### 既定を `socket` に切り替える際の阻害要因（重要）

- **socket モードの teardown が unix 専用**: destructor は socket モードで `exec kill {*}[pid $mySSH]`
  を使う（リモート終了後も ssh が転送チャネル上で残留し `close $mySSH` がハングするため）。
  **Windows（`plink`）では `exec kill` が効かない**ため、既定を `socket` にすると **Windows を壊す**。
  → 既定切替の前に、socket モード teardown の移植（Windows での ssh 子終了手段）が必須。
- **新しさ**: socket 経路は実績が浅い。一定の soak 期間が望ましい。
- **接続コスト**: handoff の往復が1回増える（connect がわずかに遅くなる）。
- **stderr の扱い**: 課題1が未決のうちは、socket 既定だと stderr が(merge 未指定なら)これまで通り
  ローカル stderr 行きで、アプリからは依然読めない。既定切替と stderr 方針はセットで考えるのが自然。

### 推奨

- 当面 **既定は `pipe` のまま**（socket は opt-in）。
- 切替を検討する条件: (a) socket teardown を移植可能にする（または既定切替を **unix 限定**にし、
  `tcl_platform` で分岐）、(b) 課題1（stderr）の方針確定、(c) soak 完了。
- 代替案: 全体の既定は変えず、**プラットフォーム別**（unix なら socket、windows なら pipe）に
  既定を出し分ける、あるいは「明示 opt-in を推奨」とドキュメント化して既定は据え置く。

### 着手順（課題2）

1. socket teardown を移植可能化（`exec kill` を `pid $mySSH` のプラットフォーム別終了に。
   Windows は `taskkill` 等、または ssh 多重化/`-O exit` 系の検討）。
2. unix 限定での既定切替（`tcl_platform(platform) eq "unix"` 時のみ socket 既定）を試す。
3. soak 後に全体既定の判断。

---

## まとめ（残タスク一覧）

| # | タスク | 規模 | 前提 |
|---|---|---|---|
| 1a | ✅ **済** `-remote-stderr channel`（ローカル `chan pipe` で ssh stderr を受け、`-on-remote-stderr` 配送。両モード対応） | 小 | — |
| 1b | （任意）`-remote-stderr merge`（stderr を stdout に統合、socket 限定） | 小 | 1a でほぼ代替可 |
| 2a | socket teardown の移植可能化（`exec kill` 脱却） | 中 | Windows 検証環境 |
| 2b | `-control-channel` 既定切替（まず unix 限定） | 小 | 2a・1・soak |

各タスクは [improvement-notes.md](improvement-notes.ja.md) §0 の設計メモと整合させること。
テストは既存方針どおり、接続不要ユニットを優先し、実 ssh 必須分は `-integration` 下に置く。
