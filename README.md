# jejeje.el

[🇺🇸 English](README.en.md)

[jejeje](https://github.com/wakamenod/jejeje) 競技プログラミング CLI ツール（`je`）向け Emacs インターフェースです。AtCoder・Codeforces・yukicoder・AOJ に対応しています。

## 機能

- **`jejeje-prepare`**: ジャッジとコンテストをインタラクティブに選択し、サンプルケースを取得する。
- **`jejeje-test`**: シンタックスハイライト付きでテストケースを実行する。実行コマンドは [quickrun](https://github.com/emacsorphanage/quickrun) 経由でバッファのファイル種別から自動検出される。`C-u` で1回のみコマンドや表示方法を上書きできる。
- **`jejeje-submit`**: 言語とソースコードをライブの `xwidget-webkit` セッションの提出フォームに注入する。提出ボタンはユーザーが手動で押す。
- **`jejeje-info`**: `.je-meta.json` からコンテストのメタデータを表示する。
- **`jejeje-browse-problem`**: 現在の問題のウェブページを Emacs 内で開く。
- **`jejeje-menu`**: 全コマンドをまとめた [Transient](https://github.com/magit/transient) ポップアップメニュー。

## 必要環境

- **Emacs** 28.1 以上
- **`je` CLI**: 初回実行時に自動ダウンロードされ、起動のたびにバックグラウンドで自動更新される。手動インストール不要。
- **transient** 0.4.0 以上（パッケージマネージャーで自動解決）
- **quickrun** 2.3 以上（パッケージマネージャーで自動解決）
- **posframe** *(任意)*: `jejeje-test` の結果をフローティングフレームで表示する。
- **xwidgets** *(任意、`jejeje-submit` に必要)*: `--with-xwidgets` オプション付きでビルドされた Emacs が必要。macOS では [emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus) が対応済み。

## インストール

### Emacs 29+（`package-vc`）

```elisp
(use-package jejeje
  :vc (:url "https://github.com/wakamenod/jejeje.el")
  :bind (("C-c j" . jejeje-menu)))
```

### `straight.el` を使う場合

```elisp
(use-package jejeje
  :straight (jejeje :type git :host github :repo "wakamenod/jejeje.el")
  :bind (("C-c j" . jejeje-menu)))
```

## 設定

```elisp
(setq jejeje-executable "/usr/local/bin/je")  ; 管理バイナリを上書きする場合のみ設定
(setq jejeje-test-command nil)                ; nil = quickrun で自動検出（デフォルト）
(setq jejeje-test-tle 2.0)                    ; タイムリミット（秒）
(setq jejeje-buffer-name "*jejeje*")          ; 出力バッファ名
(setq jejeje-test-display-method 'posframe)   ; 'posframe（デフォルト）または 'buffer
```

プロジェクトごとの上書きは `.dir-locals.el` で設定できる：

```elisp
((nil . ((jejeje-test-command . "./a.out"))))
```

## 使い方

`M-x jejeje-menu`（推奨）、またはプレフィックスマップをキーにバインドする：

```elisp
(global-set-key (kbd "C-c j") jejeje-map)
```

デフォルトのキーバインド：

| キー | コマンド                |
|------|------------------------|
| `p`  | `jejeje-prepare`       |
| `t`  | `jejeje-test`          |
| `s`  | `jejeje-submit-problem` |
| `i`  | `jejeje-info`          |
| `w`  | `jejeje-browse-problem` |
| `T`  | `jejeje-template`      |
| `V`  | `jejeje-version`       |
| `m`  | `jejeje-menu`          |

## 開発

```sh
just lint && just test && just package
```

## ライセンス

GPL-3.0-or-later
