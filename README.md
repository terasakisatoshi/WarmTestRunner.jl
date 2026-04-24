# WarmTestRunner.jl

`WarmTestRunner.jl` は、Julia パッケージ開発中のローカルなテスト反復を速くするためのテストランナーです。

通常の `Pkg.test()` は毎回クリーンな Julia プロセスでテストを実行します。一方で `WarmTestRunner.jl` は、デーモンプロセスと warm な worker pool を使い回し、パッケージ読み込みやコンパイルのコストを複数回のテスト実行に分散します。

このため、用途は次のように分けるのが基本です。

- 日々の編集とテストの反復: `using WarmTestRunner; runtests()`
- マージ前、リリース前、CI 相当の最終確認: `Pkg.test()`

`WarmTestRunner.jl` は `Pkg.test()` の完全な置き換えではありません。worker プロセスは使い回され、各 worker の `Main` が warm な実行コンテキストとして残ります。厳密なクリーンルーム実行よりも反復速度を優先します。

## 必要条件

- Julia 1.12 以上
- テスト対象パッケージの `Project.toml`
- 通常の Julia テストファイルを置く `test/` ディレクトリ

## インストール

このパッケージをテスト対象プロジェクトの環境で使えるようにします。未登録パッケージとしてローカル checkout を使う場合は、テスト対象プロジェクトで次のように追加します。

```bash
cd path/to/this/directory
julia -e 'using Pkg; Pkg.activate(); Pkg.develop(path = ".")'
```

## 基本的な使い方

```julia
using WarmTestRunner
summary = runtests()
```

`runtests()` は `test/runtests.jl` があればそれをテストスイートの入口として実行します。`tests = [...]` で一部のファイルを指定した場合も、到達可能な included file であれば `test/runtests.jl` を経由して、そのファイルのテストだけを選択実行します。

返り値は `RunSummary` です。

```julia
summary.passed
summary.failed
summary.errored
summary.crashed
summary.skipped
summary.results
```

各結果は `summary.results` に入り、`path`, `status`, `stdout`, `stderr`, `exception_summary`, `stacktrace`, `elapsed`, `diagnostics` などを確認できます。全体実行では通常 `test/runtests.jl` が結果単位になり、`tests = [...]` によるファイル選択では選択ファイルが結果単位になります。

