# 制御チャネル ソケット化 — 残課題の計画

ブランチ `17-control-socket` で「制御チャネルの専用ソケット化」（[improvement-notes.md](improvement-notes.md) §0）は
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
**そのままでは Tcl チャネルとして読めない**。現状の `-remote-stderr local`（既定）はこの素の挙動
（ssh stderr → ローカル stderr）で、capture しない。`-on-remote-output` が拾うのは stdout だけ。

`-remote-stderr` のオプション枠は実装済み（`merge`/`channel` は `connect` でエラー）。以下を実装する。

### 案A: `merge`（推奨・簡単）— exec レベルで stderr を stdout に統合

リモート tclsh の stderr を **ローカルの exec リダイレクトで stdout（=パイプ）に統合**する。
`remote open` のパイプ生成（`set mySSH [open [list | {*}$cmd] w+]`）で、`$cmd` 末尾の
リダイレクトを `2>@ stderr` ではなく **stdout へ統合**する形にする（Tcl の `2>@1` 相当。
要 Tcl バージョン確認）。こうすると ssh が中継するリモート stderr が stdout 側に乗り、
socket モードではパイプ＝アプリ出力なので `-on-remote-output` に **stdout と stderr が混在**して届く。

- **socket モード限定**: pipe モードで統合すると制御プロトコルに stderr が混ざり破綻する。
  → `connect` のバリデーションで `merge` は `-control-channel socket` 必須にする
  （`-on-remote-output` と同じ扱い）。
- 長所: 実装が小さい（パイプ生成のリダイレクト1箇所＋バリデーション）。
- 短所: stdout/stderr の区別が失われる。ssh 自身の診断メッセージ（`-ssh-verbose` の出力等）も混ざる。
- テスト: socket モードで `comm send {puts stderr "E"; flush stderr; list ok}` を送り、
  `-on-remote-output` に `E` が届くこと（接続必須の統合テスト）。

### 案B: `channel`（分離・難しい）— stderr 専用の転送ソケット

stdout/stderr を分けたい場合。`forward new raw` 派生でもう1本（kind=`stderr`）socket を張り、
リモートの stderr をそこへ流す。`-on-remote-stderr` コールバックで配送。

- **難所**: Tcl はリモート `tclsh` 内で **`stderr` チャネル（fd 2）を socket に振り向けにくい**
  （`dup2` 相当が無く、`stderr` という予約チャネル名を別チャネルに差し替えられない）。
  検討すべき実装アプローチ:
  1. **`interp` / `puts` ラッパ**: リモートで `puts` を薄くラップし、`stderr` 宛て書き込みを
     stderr-socket へ送る。アプリの `puts stderr` は拾えるが、C 拡張や `error` 経由の stderr 出力は漏れる。
  2. **OS レベルのリダイレクト**: 起動コマンドを `tclsh 2>(...)` 等にしてリモート側で fd 2 を
     別パイプ→フォワーダへ。リモートシェル依存・移植性に難。
  3. **`chan push`（リフレクトチャネル変換, Tcl 8.6+）**: `stderr` に変換レイヤを被せ、
     書き込みを socket へリダイレクト。最も Tcl らしいが実装量が多い。
- 長所: stdout/stderr を分離保持。短所: 実装・移植性のコストが高い。
- 推奨: まず案A（`merge`）を実装し、分離が本当に必要になった時に案B（`chan push` 路線）を検討。

### 着手順（課題1）

1. 案A `merge` を実装（`remote open` のリダイレクト＋`connect` バリデーション＋統合テスト）。
2. 必要なら案B `channel` を別途設計（`chan push` のリフレクトチャネルで stderr を socket へ）。

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
| 1a | `-remote-stderr merge`（exec で stderr→stdout 統合、socket 限定） | 小 | — |
| 1b | `-remote-stderr channel`（stderr 専用 socket、`chan push`） | 中〜大 | 1a の後でよい |
| 2a | socket teardown の移植可能化（`exec kill` 脱却） | 中 | Windows 検証環境 |
| 2b | `-control-channel` 既定切替（まず unix 限定） | 小 | 2a・1・soak |

各タスクは [improvement-notes.md](improvement-notes.md) §0 の設計メモと整合させること。
テストは既存方針どおり、接続不要ユニットを優先し、実 ssh 必須分は `-integration` 下に置く。
