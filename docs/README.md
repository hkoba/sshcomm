# sshcomm 開発者向けドキュメント

このディレクトリは、ライブラリ `sshcomm` の **コード全体を調査した結果** をまとめた、
今後の改良作業のための内部設計ドキュメント集です。

エンドユーザ向けの使い方は、リポジトリ直下の [`../README.md`](../README.md) を参照してください。
このディレクトリは「中で何が起きているか」「なぜそうなっているか」「どこを直すべきか」に焦点を当てます。

## sshcomm とは（一言で）

[tcllib の `comm`](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/comm/comm.md)
は Tcl インタプリタ間で TCP ソケット越しに Tcl スクリプトを送り合う仕組みですが、
通信路は **平文・無認証** です。
`sshcomm` は、この `comm` の通信を **SSH ポートフォワード越しのトンネル** に通し、
さらに **Cookie による接続認証** を加えることで、安全なリモートスクリプティングを実現します。

最大の特徴は **リモート側に事前インストールが要らない** ことです。
リモートに必要なのは `tclsh` だけで、`comm` パッケージすら無くても、
ローカル側が自分の名前空間定義（`comm` 本体を含む）をシリアライズしてSSHのstdin経由で送り込み、
リモートインタプリタ内に再構築します。

## ドキュメント構成

| ファイル | 内容 |
|---|---|
| [architecture.md](architecture.md) | 全体アーキテクチャ。2チャネルモデル、接続確立シーケンス、Cookie認証、コード転送、リモートサーバ構造、sshcmd プラットフォーム抽象化 |
| [api-reference.md](api-reference.md) | 公開API・`connection` のオプション一覧・メソッド・リモートAPI・`utils`・非推奨API |
| [plugins-and-hostsetup.md](plugins-and-hostsetup.md) | プラグイン機構、補助モジュール（`host-setup`【非推奨】・`git-ssh-proxy`【ほぼ非推奨】）|
| [improvement-notes.md](improvement-notes.md) | 改良のための覚書。**最優先テーマ＝制御チャネルの専用ソケット化**、既知の `XXX`/`BUG`、技術的負債、Tcl 9 対応、パッケージング、セキュリティ、テスト |

## 開発方針メモ（2026-06 時点）

- **最優先の改良テーマ**: 制御チャネルを SSH の stdin/stdout パイプから `forward new raw` 由来の
  専用ソケットへ分離し、リモートの **stdout/stderr をアプリケーションに開放** する。
  詳細な考察は [improvement-notes.md](improvement-notes.md) §0。
- **`hostsetup.tcl`（`::host-setup`）は非推奨**、**`git-ssh-proxy.tcl` はほぼ非推奨**
  （将来復活の可能性は残す）。`utils.tcl` は現役。
  → [plugins-and-hostsetup.md](plugins-and-hostsetup.md) 参照。

## 基本情報

- **バージョン**: 0.4（`pkgIndex.tcl` / `package provide sshcomm 0.4`）
- **依存**: `snit`, `comm`（いずれも tcllib）。`require Tcl 8.5` を宣言
- **動作確認環境（調査時）**: Tcl 9.0.2 / snit 2.3.4 / comm 4.7.3
- **作者**: Hiroaki Kobayashi (hkoba) / Copyright 2005-2020
- **リポジトリ**: https://github.com/hkoba/sshcomm

## ファイル一覧（リポジトリ直下）

| ファイル | 役割 |
|---|---|
| `sshcomm.tcl` | 本体。`::sshcomm` 名前空間、`sshcomm::connection`（ローカル側オブジェクト）、`definition`（コード転送）、`::sshcomm::remote`（リモート側サーバ）|
| `utils.tcl` | `::sshcomm::utils` 汎用ユーティリティ（dict/ファイル/askpass など）。プラグイン |
| `hostsetup.tcl` | 【非推奨】`::host-setup` 宣言的構成管理DSL。プラグイン |
| `action/*.tcl` | 【非推奨】host-setup の組み込みルール（`etc-git` / `sshd_config` / `copy-uploaded-sysroot`）|
| `git-ssh-proxy.tcl` | 【ほぼ非推奨】SSH ControlMaster を使う `GIT_SSH` プロキシ生成スクリプト。プラグイン兼CLI |
| `sshcomm.test` | `tcltest` によるテストスイート |
| `pkgIndex.tcl` | パッケージインデックス（`sshcomm.tcl` のみをロード）|
| `sshcomm.man` / `.ja.man` / `.html` | doctools マニュアル（現状はほぼ雛形のみ）|
| `README.md` | エンドユーザ向け使い方・インストール手順 |
