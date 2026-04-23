# WarmTestRunner.jl

`WarmTestRunner.jl` は、Julia パッケージ開発中のローカルなテスト反復を速くするためのテストランナーです。

通常の `Pkg.test()` は毎回クリーンな Julia プロセスでテストを実行します。一方で `WarmTestRunner.jl` は、デーモンプロセスと warm な worker pool を使い回し、パッケージ読み込みやコンパイルのコストを複数回のテスト実行に分散します。

このため、用途は次のように分けるのが基本です。

- 日々の編集とテストの反復: `WarmTestRunner.run()`
- マージ前、リリース前、CI 相当の最終確認: `Pkg.test()`

`WarmTestRunner.jl` は `Pkg.test()` の完全な置き換えではありません。worker プロセスは使い回されるため、厳密なクリーンルーム実行よりも反復速度を優先します。

## 必要条件

- Julia 1.10 以上
- テスト対象パッケージの `Project.toml`
- 通常の Julia テストファイルを置く `test/` ディレクトリ

## インストール

このパッケージをテスト対象プロジェクトの環境で使えるようにします。未登録パッケージとしてローカル checkout を使う場合は、テスト対象プロジェクトで次のように追加します。

```julia
using Pkg
Pkg.develop(path = "/path/to/WarmTestRunner.jl")
```

このリポジトリ自体で開発する場合は、依存関係を先に instantiate してください。

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## 基本的な使い方

テスト対象パッケージのルートディレクトリで Julia を起動します。

```bash
julia --project=.
```

最初に worker pool を起動します。

```julia
using WarmTestRunner

WarmTestRunner.serve(jobs = 4)
```

テストを実行します。

```julia
summary = WarmTestRunner.run()
```

`run()` は `test/` 以下の `*.jl` を探索して実行します。ただし、テスト全体の入口として扱われる `test/runtests.jl` と、worker 起動時フックの `test/warmtest_bootstrap.jl` は自動探索から除外されます。

返り値は `RunSummary` です。

```julia
summary.passed
summary.failed
summary.errored
summary.crashed
summary.skipped
summary.results
```

各テストファイルの結果は `summary.results` に入り、`status`, `stdout`, `stderr`, `exception_summary`, `stacktrace`, `elapsed` などを確認できます。

機械処理しやすい JSON 文字列が必要な場合は `output_format = :json` を指定します。

```julia
json = WarmTestRunner.run(output_format = :json)
```

JSON には集計件数、合計実行時間、ファイルごとの `path`, `status`, `stdout`, `stderr`, `exception_summary`, `stacktrace`, `worker_id` が含まれます。

## コマンドラインから使う

Julia の `-e` オプションだけでも使えます。

```bash
julia --project=. -e 'using WarmTestRunner; WarmTestRunner.serve(jobs = 4)'
julia --project=. -e 'using WarmTestRunner; WarmTestRunner.run()'
julia --project=. -e 'using WarmTestRunner; WarmTestRunner.stop()'
```

既存のデーモンがある場合、`serve()` と `run()` はそれを再利用します。
専用の CLI wrapper はまだ未実装です。

## 一部のテストだけ実行する

`tests` にファイル名を渡すと、そのファイルだけを実行します。相対パスは `test/` からの相対名として解釈されます。

```julia
WarmTestRunner.run(tests = ["foo.jl"])
WarmTestRunner.run(tests = ["unit/foo.jl", "unit/bar.jl"])
```

絶対パスも指定できます。

```julia
WarmTestRunner.run(tests = ["/path/to/MyPkg/test/foo.jl"])
```

現在の公開 API では、ファイル名の部分一致、正規表現、タグ include/exclude による絞り込みはまだ未実装です。
その用途では、今は `tests = [...]`、`changed_only = true`、`rerun_failed = true` を使って対象を絞ってください。

## 失敗したらすぐ止める

`quickfail = true` を指定すると、失敗またはエラーが見つかった時点で残りのテストを skipped として扱います。

```julia
WarmTestRunner.run(quickfail = true)
```

## 変更されたテストだけ実行する

Git 管理下のパッケージでは `changed_only = true` が使えます。

```julia
WarmTestRunner.run(changed_only = true)
```

現在の実装では、次の方針で対象を選びます。

- `test/` 以下のテストファイルだけが変更されている場合、そのファイルだけを実行する
- `src/` 以下に変更がある場合、影響範囲を安全側に倒して全テストを実行する
- Git 情報が取得できない場合、全テストを実行する
- 関連する変更がない場合、空の `RunSummary` を返す

`changed_only = true` は、明示的な `tests = [...]` や `rerun_failed = true` とは同時に使えません。

## ファイル変更を監視して再実行する

`watch()` は `src/` と `test/` を監視し、変更後に debounce してからテストを再実行します。
既定では `changed_only = true` を使います。

```julia
WarmTestRunner.watch()
```

すべてのテストを毎回実行したい場合は次のように指定します。

```julia
WarmTestRunner.watch(changed_only = false)
```

停止するには `Ctrl-C` を使います。

## 前回失敗したテストだけ再実行する

`rerun_failed = true` を指定すると、同じデーモンまたはパッケージルートで記録されている前回の失敗ファイルだけを再実行します。

```julia
WarmTestRunner.run(rerun_failed = true)
```

明示的なテストリストと組み合わせると、そのリストを前回失敗したファイルに絞り込みます。

```julia
WarmTestRunner.run(tests = ["foo.jl", "bar.jl"], rerun_failed = true)
```

失敗履歴がない場合は、空の `RunSummary` を返します。

## worker を作り直す

warm な worker は実行間で状態を保持します。グローバル状態の汚染が疑わしい場合は、`fresh = true` で worker pool を作り直してからテストを実行できます。

```julia
WarmTestRunner.run(fresh = true)
```

デーモンの設定自体を変えたい場合、既存デーモンを止めてから起動し直します。

```julia
WarmTestRunner.stop()
WarmTestRunner.serve(jobs = 8)
```

既存デーモンと互換性のない `jobs` などを指定して再利用しようとすると、`ArgumentError` が発生します。

## デーモン状態の確認と停止

状態を確認します。

```julia
status = WarmTestRunner.status()
status.state
status.jobs
status.running_jobs
status.last_failed
```

停止します。

```julia
WarmTestRunner.stop()
```

`stop()` はデーモンから停止要求の ACK を受け取った時点で返ります。実際の registry file 削除やプロセス終了は、その後に非同期で完了します。

## worker 起動時のフック

`test/warmtest_bootstrap.jl` が存在する場合、各 worker の起動時に読み込まれます。テスト実行前に必要な初期化を置くためのファイルです。

```julia
# test/warmtest_bootstrap.jl
ENV["MY_TEST_MODE"] = "warm"
```

このファイルは通常のテストファイルとしては自動実行されません。

## Revise 連携

`serve(use_revise = true)` は各 worker の bootstrap で `Revise` を読み込みます。
読み込み順は環境 activation、`Revise`、対象パッケージ preload、`test/warmtest_bootstrap.jl` です。

`Revise` の状態は worker ごとに独立しています。macro 展開、generated function、constant の再定義などは追跡しきれない場合があるため、warm state が疑わしい場合は `run(fresh = true)` で worker pool を作り直してください。

## 設定

現在の MVP で実際に使える主なキーワード引数は次の通りです。

```julia
WarmTestRunner.serve(
    pkgroot = pwd(),
    jobs = 4,
    threads_per_worker = 1,
    use_testenv = true,
    use_revise = false,
    preload_package = true,
    startup_file = false,
)
```

- `pkgroot`: テスト対象パッケージのルート
- `jobs`: worker 数
- `threads_per_worker`: 各 worker の Julia thread 数
- `use_testenv`: `TestEnv.activate(pkgroot)` を試す
- `use_revise`: worker 起動時に `Revise` を読み込む
- `preload_package`: worker 起動時に対象パッケージを `using` する
- `startup_file`: worker 起動時に Julia startup file を読む

仕様上は存在するが、現在は未実装として拒否される設定もあります。

- `color = false`
- `worker_timeout != 60.0`
- `log_level != :info`

## 最終確認

`WarmTestRunner.jl` は開発中の反復を速くするための道具です。最終確認では、通常の `Pkg.test()` を別途実行してください。

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

このリポジトリのテストスイートを直接走らせる場合は次を使います。

```bash
julia --project=. --startup-file=no -e 'include("test/runtests.jl")'
```
