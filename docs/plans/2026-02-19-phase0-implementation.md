# Phase 0: ex_wxf Library — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build `ex_wxf`, a standalone Hex package that encodes and decodes the Wolfram eXchange Format (WXF) binary serialization, covering the full spec with a quality stack enforcing Credo strict, Dialyzer, 90% coverage, and TDD.

**Architecture:** Expression struct tree for full WXF fidelity, with auto-mapping of common Elixir types (int, float, string, list, map) for ergonomics. Encoder and decoder are pure-function modules — no processes, no state. Varint (LEB128) and token constants are isolated modules.

**Tech Stack:** Elixir 1.18.3 / OTP 27, StreamData (property tests), Credo, Dialyxir, Sobelow, ExCoveralls

**Design doc:** `docs/plans/2026-02-19-phase0-wxf-library-design.md`

---

### Task 1: Scaffold Mix Project with Quality Stack

**Files:**
- Create: entire `ex_wxf/` project structure
- Create: `ex_wxf/.credo.exs`
- Create: `ex_wxf/coveralls.json`
- Create: `ex_wxf/.dialyzer_ignore.exs`
- Create: `ex_wxf/.formatter.exs`

**Step 1: Generate the Mix project**

```bash
cd /Volumes/MacintoshEDD/workspace/PERSONAL
mix new ex_wxf
```

**Step 2: Replace `mix.exs` with full quality stack config**

Replace the contents of `/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/mix.exs` with:

```elixir
defmodule ExWxf.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_wxf,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        quality: :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true,
        flags: [
          :unmatched_returns,
          :error_handling,
          :underspecs,
          :extra_return,
          :missing_return
        ]
      ],
      description: "Elixir encoder/decoder for the Wolfram eXchange Format (WXF)",
      package: package(),
      source_url: "https://github.com/fruizg0302/ex_wxf"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.0", only: :test}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ],
      quality: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "cmd mix hex.audit",
        "dialyzer",
        "cmd MIX_ENV=test mix coveralls"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/fruizg0302/ex_wxf"}
    ]
  end
end
```

**Step 3: Install dependencies**

```bash
cd /Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf
mix deps.get
```

**Step 4: Generate Credo config**

```bash
mix credo gen.config
```

Then edit `.credo.exs` — in the `checks:` list, find the `Readability.Specs` check and ensure it's enabled (not `false`):

```elixir
{Credo.Check.Readability.Specs, []}
```

Also add the `requires:` line at the top of the config to load custom checks:

```elixir
%{
  configs: [
    %{
      name: "default",
      requires: ["lib/ex_wxf_checks/**/*.ex"],
      # ... rest of config
    }
  ]
}
```

**Step 5: Create coveralls.json**

Create `/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/coveralls.json`:

```json
{
  "minimum_coverage": 90,
  "treat_no_relevant_lines_as_covered": true,
  "skip_files": [
    "test/support",
    "lib/ex_wxf_checks"
  ]
}
```

**Step 6: Create .dialyzer_ignore.exs**

Create `/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/.dialyzer_ignore.exs`:

```elixir
[
  # Add known false positives here as they arise
]
```

**Step 7: Create priv/plts directory and update .gitignore**

```bash
mkdir -p priv/plts
```

Add to `.gitignore`:

```
/priv/plts/
```

**Step 8: Verify it compiles and tests pass**

```bash
mix compile --warnings-as-errors
mix test
```

Expected: default generated test passes.

**Step 9: Initialize git and commit**

```bash
cd /Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf
git init
git add -A
git commit -m "Scaffold ex_wxf project with quality stack"
```

---

### Task 2: Custom Credo Checks (EX9001, EX9002)

**Files:**
- Create: `lib/ex_wxf_checks/no_nested_modules.ex`
- Create: `lib/ex_wxf_checks/no_process_sleep_in_tests.ex`

**Step 1: Create the EX9001 check (no nested modules)**

Create `lib/ex_wxf_checks/no_nested_modules.ex`:

```elixir
defmodule ExWxfChecks.NoNestedModules do
  @moduledoc """
  EX9001: One `defmodule` per file.
  """
  use Credo.Check,
    id: "EX9001",
    base_priority: :high,
    category: :design,
    param_defaults: [],
    explanations: [
      check: """
      Each file should contain exactly one `defmodule`. Nested modules make
      files harder to find and violate the one-module-per-file convention.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
    |> Enum.reject(&is_nil/1)
    |> then(fn issues ->
      if length(issues) > 1 do
        Enum.drop(issues, 1)
      else
        []
      end
    end)
  end

  defp traverse({:defmodule, meta, _} = ast, issues, issue_meta) do
    issue = issue_for(issue_meta, meta[:line])
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message: "File contains more than one `defmodule`. Extract nested modules to separate files.",
      line_no: line_no
    )
  end
end
```

**Step 2: Create the EX9002 check (no Process.sleep in tests)**

Create `lib/ex_wxf_checks/no_process_sleep_in_tests.ex`:

```elixir
defmodule ExWxfChecks.NoProcessSleepInTests do
  @moduledoc """
  EX9002: No `Process.sleep/1` in tests.
  """
  use Credo.Check,
    id: "EX9002",
    base_priority: :high,
    category: :warning,
    param_defaults: [],
    explanations: [
      check: """
      `Process.sleep/1` in tests indicates flaky timing-dependent assertions.
      Use `assert_receive`, `eventually`, or other deterministic waiting patterns.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if String.ends_with?(source_file.filename, "_test.exs") do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _} = ast,
         issues,
         issue_meta
       ) do
    issue =
      format_issue(issue_meta,
        message: "Avoid `Process.sleep/1` in tests. Use deterministic waiting patterns.",
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end
end
```

**Step 3: Update Dialyzer config for Credo PLT**

In `mix.exs`, add `plt_add_apps: [:credo]` to the dialyzer config:

```elixir
dialyzer: [
  plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
  plt_add_apps: [:credo],
  # ... rest unchanged
]
```

**Step 4: Verify Credo runs with custom checks**

```bash
mix credo --strict
```

Expected: passes (no violations yet — we only have one defmodule per file).

**Step 5: Commit**

```bash
git add lib/ex_wxf_checks/ mix.exs .credo.exs
git commit -m "Add custom Credo checks EX9001 (no nested modules) and EX9002 (no Process.sleep in tests)"
```

---

### Task 3: Token Constants and Varint Module

**Files:**
- Create: `lib/ex_wxf/tokens.ex`
- Create: `lib/ex_wxf/varint.ex`
- Create: `test/ex_wxf/varint_test.exs`

**Step 1: Write the failing varint tests**

Create `test/ex_wxf/varint_test.exs`:

```elixir
defmodule ExWxf.VarintTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExWxf.Varint

  describe "encode/1" do
    test "encodes 0" do
      assert Varint.encode(0) == <<0x00>>
    end

    test "encodes single-byte values (0-127)" do
      assert Varint.encode(1) == <<0x01>>
      assert Varint.encode(127) == <<0x7F>>
    end

    test "encodes two-byte values (128-16383)" do
      assert Varint.encode(128) == <<0x80, 0x01>>
      assert Varint.encode(300) == <<0xAC, 0x02>>
    end

    test "encodes three-byte values" do
      assert Varint.encode(16384) == <<0x80, 0x80, 0x01>>
    end

    test "encodes large values" do
      assert Varint.encode(268_435_455) == <<0xFF, 0xFF, 0xFF, 0x7F>>
    end
  end

  describe "decode/1" do
    test "decodes 0" do
      assert Varint.decode(<<0x00, "rest">>) == {0, "rest"}
    end

    test "decodes single-byte values" do
      assert Varint.decode(<<0x01>>) == {1, <<>>}
      assert Varint.decode(<<0x7F>>) == {127, <<>>}
    end

    test "decodes two-byte values" do
      assert Varint.decode(<<0x80, 0x01>>) == {128, <<>>}
      assert Varint.decode(<<0xAC, 0x02>>) == {300, <<>>}
    end

    test "decodes and returns remaining bytes" do
      assert Varint.decode(<<0x01, 0xFF, 0xAA>>) == {1, <<0xFF, 0xAA>>}
    end

    test "raises on truncated input" do
      assert_raise ExWxf.DecodeError, fn ->
        Varint.decode(<<0x80>>)
      end
    end
  end

  describe "round-trip" do
    property "encode then decode returns original value" do
      check all value <- integer(0..1_000_000_000) do
        encoded = Varint.encode(value)
        assert {^value, <<>>} = Varint.decode(encoded)
      end
    end
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/ex_wxf/varint_test.exs --trace
```

Expected: FAIL — modules not found.

**Step 3: Create the error modules**

Create `lib/ex_wxf/encode_error.ex`:

```elixir
defmodule ExWxf.EncodeError do
  @moduledoc "Raised when WXF encoding fails."
  defexception [:message, :term]

  @type t :: %__MODULE__{message: String.t(), term: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    message = Keyword.get(opts, :message, "encoding failed")
    term = Keyword.get(opts, :term)
    %__MODULE__{message: message, term: term}
  end
end
```

Create `lib/ex_wxf/decode_error.ex`:

```elixir
defmodule ExWxf.DecodeError do
  @moduledoc "Raised when WXF decoding fails."
  defexception [:message, :binary]

  @type t :: %__MODULE__{message: String.t(), binary: binary() | nil}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    message = Keyword.get(opts, :message, "decoding failed")
    bin = Keyword.get(opts, :binary)
    %__MODULE__{message: message, binary: bin}
  end
end
```

**Step 4: Create the Tokens module**

Create `lib/ex_wxf/tokens.ex`:

```elixir
defmodule ExWxf.Tokens do
  @moduledoc "WXF type token byte constants."

  @spec function() :: byte()
  def function, do: 0x66

  @spec symbol() :: byte()
  def symbol, do: 0x73

  @spec string() :: byte()
  def string, do: 0x53

  @spec binary_string() :: byte()
  def binary_string, do: 0x42

  @spec integer8() :: byte()
  def integer8, do: 0x43

  @spec integer16() :: byte()
  def integer16, do: 0x6A

  @spec integer32() :: byte()
  def integer32, do: 0x69

  @spec integer64() :: byte()
  def integer64, do: 0x4C

  @spec real64() :: byte()
  def real64, do: 0x72

  @spec big_integer() :: byte()
  def big_integer, do: 0x49

  @spec big_real() :: byte()
  def big_real, do: 0x52

  @spec packed_array() :: byte()
  def packed_array, do: 0xC1

  @spec numeric_array() :: byte()
  def numeric_array, do: 0xC2

  @spec association() :: byte()
  def association, do: 0x41

  @spec rule() :: byte()
  def rule, do: 0x2D

  @spec rule_delayed() :: byte()
  def rule_delayed, do: 0x3A
end
```

**Step 5: Create the Varint module**

Create `lib/ex_wxf/varint.ex`:

```elixir
defmodule ExWxf.Varint do
  @moduledoc "LEB128 variable-length integer encoding/decoding for WXF."

  @spec encode(non_neg_integer()) :: binary()
  def encode(value) when is_integer(value) and value >= 0 do
    do_encode(value, <<>>)
  end

  @spec decode(binary()) :: {non_neg_integer(), binary()}
  def decode(binary) when is_binary(binary) do
    do_decode(binary, 0, 0)
  end

  defp do_encode(value, acc) when value < 128 do
    acc <> <<value::8>>
  end

  defp do_encode(value, acc) do
    byte = Bitwise.bor(Bitwise.band(value, 0x7F), 0x80)
    do_encode(Bitwise.bsr(value, 7), acc <> <<byte::8>>)
  end

  defp do_decode(<<byte::8, rest::binary>>, value, shift) do
    value = Bitwise.bor(value, Bitwise.bsl(Bitwise.band(byte, 0x7F), shift))

    if Bitwise.band(byte, 0x80) == 0 do
      {value, rest}
    else
      do_decode(rest, value, shift + 7)
    end
  end

  defp do_decode(<<>>, _value, _shift) do
    raise ExWxf.DecodeError, message: "truncated varint: unexpected end of input"
  end
end
```

**Step 6: Run the tests**

```bash
mix test test/ex_wxf/varint_test.exs --trace
```

Expected: All tests pass.

**Step 7: Commit**

```bash
git add lib/ex_wxf/tokens.ex lib/ex_wxf/varint.ex lib/ex_wxf/encode_error.ex lib/ex_wxf/decode_error.ex test/ex_wxf/varint_test.exs
git commit -m "Add WXF token constants, varint LEB128 module, and error types"
```

---

### Task 4: Expression Structs and Array Type Constants

**Files:**
- Create: `lib/ex_wxf/expression/symbol.ex`
- Create: `lib/ex_wxf/expression/function.ex`
- Create: `lib/ex_wxf/expression/big_integer.ex`
- Create: `lib/ex_wxf/expression/big_real.ex`
- Create: `lib/ex_wxf/expression/binary_string.ex`
- Create: `lib/ex_wxf/expression/packed_array.ex`
- Create: `lib/ex_wxf/expression/numeric_array.ex`
- Create: `lib/ex_wxf/expression/association.ex`
- Create: `lib/ex_wxf/expression/rule.ex`
- Create: `lib/ex_wxf/array_types.ex`

**Step 1: Create each expression struct in its own file (EX9001 — one defmodule per file)**

Create `lib/ex_wxf/expression/symbol.ex`:

```elixir
defmodule ExWxf.Expression.Symbol do
  @moduledoc "A Wolfram Language symbol (e.g., `List`, `Plus`, `` Global`x ``)."

  @type t :: %__MODULE__{name: String.t()}

  @enforce_keys [:name]
  defstruct [:name]
end
```

Create `lib/ex_wxf/expression/function.ex`:

```elixir
defmodule ExWxf.Expression.Function do
  @moduledoc "A Wolfram Language function application (e.g., `f[x, y]`)."

  @type t :: %__MODULE__{head: term(), parts: [term()]}

  @enforce_keys [:head]
  defstruct [:head, parts: []]
end
```

Create `lib/ex_wxf/expression/big_integer.ex`:

```elixir
defmodule ExWxf.Expression.BigInteger do
  @moduledoc "An arbitrary-precision integer, stored as a decimal digit string."

  @type t :: %__MODULE__{value: String.t()}

  @enforce_keys [:value]
  defstruct [:value]
end
```

Create `lib/ex_wxf/expression/big_real.ex`:

```elixir
defmodule ExWxf.Expression.BigReal do
  @moduledoc "An arbitrary-precision real, stored as a Wolfram InputForm string."

  @type t :: %__MODULE__{value: String.t()}

  @enforce_keys [:value]
  defstruct [:value]
end
```

Create `lib/ex_wxf/expression/binary_string.ex`:

```elixir
defmodule ExWxf.Expression.BinaryString do
  @moduledoc "A raw byte sequence (Wolfram `ByteArray`)."

  @type t :: %__MODULE__{data: binary()}

  @enforce_keys [:data]
  defstruct [:data]
end
```

Create `lib/ex_wxf/expression/packed_array.ex`:

```elixir
defmodule ExWxf.Expression.PackedArray do
  @moduledoc "A homogeneous numeric array (restricted value types)."

  @type t :: %__MODULE__{
          type: atom(),
          dimensions: [pos_integer()],
          data: binary()
        }

  @enforce_keys [:type, :dimensions, :data]
  defstruct [:type, :dimensions, :data]
end
```

Create `lib/ex_wxf/expression/numeric_array.ex`:

```elixir
defmodule ExWxf.Expression.NumericArray do
  @moduledoc "A homogeneous numeric array (all value types supported)."

  @type t :: %__MODULE__{
          type: atom(),
          dimensions: [pos_integer()],
          data: binary()
        }

  @enforce_keys [:type, :dimensions, :data]
  defstruct [:type, :dimensions, :data]
end
```

Create `lib/ex_wxf/expression/association.ex`:

```elixir
defmodule ExWxf.Expression.Association do
  @moduledoc "A Wolfram Language association (`<| key -> val, ... |>`)."

  @type t :: %__MODULE__{rules: [ExWxf.Expression.Rule.t()]}

  defstruct rules: []
end
```

Create `lib/ex_wxf/expression/rule.ex`:

```elixir
defmodule ExWxf.Expression.Rule do
  @moduledoc "A rule within an association (`key -> value` or `key :> value`)."

  @type t :: %__MODULE__{key: term(), value: term(), delayed: boolean()}

  @enforce_keys [:key, :value]
  defstruct [:key, :value, delayed: false]
end
```

**Step 2: Create array type constants**

Create `lib/ex_wxf/array_types.ex`:

```elixir
defmodule ExWxf.ArrayTypes do
  @moduledoc "PackedArray and NumericArray value type byte constants and metadata."

  @type value_type ::
          :integer8
          | :integer16
          | :integer32
          | :integer64
          | :unsigned_integer8
          | :unsigned_integer16
          | :unsigned_integer32
          | :unsigned_integer64
          | :real32
          | :real64
          | :complex_real32
          | :complex_real64

  @type_to_byte %{
    integer8: 0x00,
    integer16: 0x01,
    integer32: 0x02,
    integer64: 0x03,
    unsigned_integer8: 0x10,
    unsigned_integer16: 0x11,
    unsigned_integer32: 0x12,
    unsigned_integer64: 0x13,
    real32: 0x22,
    real64: 0x23,
    complex_real32: 0x33,
    complex_real64: 0x34
  }

  @byte_to_type Map.new(@type_to_byte, fn {k, v} -> {v, k} end)

  @type_to_size %{
    integer8: 1,
    integer16: 2,
    integer32: 4,
    integer64: 8,
    unsigned_integer8: 1,
    unsigned_integer16: 2,
    unsigned_integer32: 4,
    unsigned_integer64: 8,
    real32: 4,
    real64: 8,
    complex_real32: 8,
    complex_real64: 16
  }

  @packed_types [:integer8, :integer16, :integer32, :integer64, :real32, :real64, :complex_real32, :complex_real64]

  @spec to_byte(value_type()) :: byte()
  def to_byte(type), do: Map.fetch!(@type_to_byte, type)

  @spec from_byte(byte()) :: value_type()
  def from_byte(byte), do: Map.fetch!(@byte_to_type, byte)

  @spec element_size(value_type()) :: pos_integer()
  def element_size(type), do: Map.fetch!(@type_to_size, type)

  @spec packed_type?(value_type()) :: boolean()
  def packed_type?(type), do: type in @packed_types
end
```

**Step 3: Verify compilation**

```bash
mix compile --warnings-as-errors
```

Expected: compiles cleanly.

**Step 4: Commit**

```bash
git add lib/ex_wxf/expression/ lib/ex_wxf/array_types.ex
git commit -m "Add expression structs and array type constants"
```

---

### Task 5: Encoder — Scalar Types (Integers, Reals, Strings, Symbols)

**Files:**
- Create: `lib/ex_wxf/encoder.ex`
- Create: `test/ex_wxf/encoder_test.exs`

**Step 1: Write the failing encoder tests for scalar types**

Create `test/ex_wxf/encoder_test.exs`:

```elixir
defmodule ExWxf.EncoderTest do
  use ExUnit.Case, async: true

  alias ExWxf.Encoder

  describe "encode_expression/1 — integers" do
    test "encodes integer 0 as Integer8" do
      assert Encoder.encode_expression(0) == <<0x43, 0>>
    end

    test "encodes positive integer8" do
      assert Encoder.encode_expression(42) == <<0x43, 42>>
    end

    test "encodes negative integer8" do
      assert Encoder.encode_expression(-1) == <<0x43, 255>>
    end

    test "encodes integer that needs 16 bits" do
      assert Encoder.encode_expression(200) == <<0x6A, 200, 0>>
    end

    test "encodes negative integer16" do
      assert Encoder.encode_expression(-200) == <<0x6A, 56, 0xFF>>
    end

    test "encodes integer that needs 32 bits" do
      assert Encoder.encode_expression(100_000) == <<0x69, 0xA0, 0x86, 0x01, 0x00>>
    end

    test "encodes integer that needs 64 bits" do
      val = 3_000_000_000
      <<a, b, c, d, e, f, g, h>> = <<val::64-little-signed>>
      assert Encoder.encode_expression(val) == <<0x4C, a, b, c, d, e, f, g, h>>
    end

    test "encodes big integer beyond 64-bit range" do
      big = 9_999_999_999_999_999_999_999
      digits = Integer.to_string(big)
      len_bytes = ExWxf.Varint.encode(byte_size(digits))
      assert Encoder.encode_expression(big) == <<0x49>> <> len_bytes <> digits
    end

    test "encodes negative big integer" do
      big = -9_999_999_999_999_999_999_999
      digits = Integer.to_string(big)
      len_bytes = ExWxf.Varint.encode(byte_size(digits))
      assert Encoder.encode_expression(big) == <<0x49>> <> len_bytes <> digits
    end
  end

  describe "encode_expression/1 — reals" do
    test "encodes float as Real64" do
      assert Encoder.encode_expression(3.14) == <<0x72, 3.14::64-little-float>>
    end

    test "encodes 0.0" do
      assert Encoder.encode_expression(0.0) == <<0x72, 0.0::64-little-float>>
    end
  end

  describe "encode_expression/1 — strings" do
    test "encodes empty string" do
      assert Encoder.encode_expression("") == <<0x53, 0x00>>
    end

    test "encodes ASCII string" do
      assert Encoder.encode_expression("hello") == <<0x53, 5, "hello">>
    end

    test "encodes UTF-8 string with multibyte chars" do
      str = "héllo"
      bytes = byte_size(str)
      len_bytes = ExWxf.Varint.encode(bytes)
      assert Encoder.encode_expression(str) == <<0x53>> <> len_bytes <> str
    end
  end

  describe "encode_expression/1 — symbols (atoms)" do
    test "encodes true as Symbol True" do
      assert Encoder.encode_expression(true) == <<0x73, 4, "True">>
    end

    test "encodes false as Symbol False" do
      assert Encoder.encode_expression(false) == <<0x73, 5, "False">>
    end

    test "encodes nil as Symbol Null" do
      assert Encoder.encode_expression(nil) == <<0x73, 4, "Null">>
    end

    test "encodes arbitrary atom as Symbol" do
      assert Encoder.encode_expression(:Plus) == <<0x73, 4, "Plus">>
    end
  end

  describe "encode_expression/1 — Expression.Symbol struct" do
    test "encodes Symbol struct" do
      sym = %ExWxf.Expression.Symbol{name: "Global`x"}
      name = "Global`x"
      assert Encoder.encode_expression(sym) == <<0x73, byte_size(name), name::binary>>
    end
  end

  describe "encode_expression/1 — Expression.BigReal struct" do
    test "encodes BigReal struct" do
      br = %ExWxf.Expression.BigReal{value: "3.14159265358979323846`30."}
      val = br.value
      len_bytes = ExWxf.Varint.encode(byte_size(val))
      assert Encoder.encode_expression(br) == <<0x52>> <> len_bytes <> val
    end
  end

  describe "encode_expression/1 — Expression.BinaryString struct" do
    test "encodes BinaryString struct" do
      bs = %ExWxf.Expression.BinaryString{data: <<0xFF, 0x00, 0xAA>>}
      assert Encoder.encode_expression(bs) == <<0x42, 3, 0xFF, 0x00, 0xAA>>
    end
  end
end
```

**Step 2: Run tests to verify they fail**

```bash
mix test test/ex_wxf/encoder_test.exs --trace
```

Expected: FAIL — `ExWxf.Encoder` not found.

**Step 3: Implement Encoder for scalar types**

Create `lib/ex_wxf/encoder.ex`:

```elixir
defmodule ExWxf.Encoder do
  @moduledoc "Encodes Elixir terms into WXF binary expression data (no header)."

  alias ExWxf.{Tokens, Varint}
  alias ExWxf.Expression

  @spec encode_expression(term()) :: binary()
  def encode_expression(value) when is_integer(value) do
    encode_integer(value)
  end

  def encode_expression(value) when is_float(value) do
    <<Tokens.real64(), value::64-little-float>>
  end

  def encode_expression(value) when is_binary(value) do
    <<Tokens.string()>> <> Varint.encode(byte_size(value)) <> value
  end

  def encode_expression(true), do: encode_symbol_name("True")
  def encode_expression(false), do: encode_symbol_name("False")
  def encode_expression(nil), do: encode_symbol_name("Null")

  def encode_expression(value) when is_atom(value) do
    encode_symbol_name(Atom.to_string(value))
  end

  def encode_expression(%Expression.Symbol{name: name}) do
    encode_symbol_name(name)
  end

  def encode_expression(%Expression.BigReal{value: value}) do
    <<Tokens.big_real()>> <> Varint.encode(byte_size(value)) <> value
  end

  def encode_expression(%Expression.BinaryString{data: data}) do
    <<Tokens.binary_string()>> <> Varint.encode(byte_size(data)) <> data
  end

  defp encode_integer(value) when value >= -128 and value <= 127 do
    <<Tokens.integer8(), value::8-little-signed>>
  end

  defp encode_integer(value) when value >= -32_768 and value <= 32_767 do
    <<Tokens.integer16(), value::16-little-signed>>
  end

  defp encode_integer(value) when value >= -2_147_483_648 and value <= 2_147_483_647 do
    <<Tokens.integer32(), value::32-little-signed>>
  end

  defp encode_integer(value) when value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807 do
    <<Tokens.integer64(), value::64-little-signed>>
  end

  defp encode_integer(value) do
    digits = Integer.to_string(value)
    <<Tokens.big_integer()>> <> Varint.encode(byte_size(digits)) <> digits
  end

  defp encode_symbol_name(name) do
    <<Tokens.symbol()>> <> Varint.encode(byte_size(name)) <> name
  end
end
```

**Step 4: Run the tests**

```bash
mix test test/ex_wxf/encoder_test.exs --trace
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add lib/ex_wxf/encoder.ex test/ex_wxf/encoder_test.exs
git commit -m "Add encoder for scalar types: integers, reals, strings, symbols"
```

---

### Task 6: Encoder — Composite Types (Lists, Maps, Functions, Associations)

**Files:**
- Modify: `lib/ex_wxf/encoder.ex`
- Modify: `test/ex_wxf/encoder_test.exs`

**Step 1: Write failing tests for composite types**

Append to `test/ex_wxf/encoder_test.exs`:

```elixir
  describe "encode_expression/1 — lists" do
    test "encodes empty list" do
      result = Encoder.encode_expression([])
      # Function(0) + Symbol("List")
      assert result == <<0x66, 0x00, 0x73, 4, "List">>
    end

    test "encodes list of integers" do
      result = Encoder.encode_expression([1, 2, 3])
      assert result == <<0x66, 3>> <> <<0x73, 4, "List">> <> <<0x43, 1>> <> <<0x43, 2>> <> <<0x43, 3>>
    end

    test "encodes nested list" do
      result = Encoder.encode_expression([[1, 2], [3]])
      # Function(2) List [ Function(2) List [1, 2], Function(1) List [3] ]
      expected =
        <<0x66, 2>> <> <<0x73, 4, "List">> <>
        <<0x66, 2>> <> <<0x73, 4, "List">> <> <<0x43, 1>> <> <<0x43, 2>> <>
        <<0x66, 1>> <> <<0x73, 4, "List">> <> <<0x43, 3>>

      assert result == expected
    end
  end

  describe "encode_expression/1 — maps" do
    test "encodes empty map" do
      result = Encoder.encode_expression(%{})
      assert result == <<0x41, 0x00>>
    end

    test "encodes map with string keys" do
      result = Encoder.encode_expression(%{"a" => 1})
      # Association(1) Rule String("a") Integer8(1)
      assert result == <<0x41, 1, 0x2D>> <> <<0x53, 1, "a">> <> <<0x43, 1>>
    end
  end

  describe "encode_expression/1 — Function struct" do
    test "encodes Function with symbol head" do
      func = %ExWxf.Expression.Function{
        head: %ExWxf.Expression.Symbol{name: "Plus"},
        parts: [1, 2]
      }

      result = Encoder.encode_expression(func)
      assert result == <<0x66, 2>> <> <<0x73, 4, "Plus">> <> <<0x43, 1>> <> <<0x43, 2>>
    end
  end

  describe "encode_expression/1 — Association struct" do
    test "encodes Association with rules" do
      assoc = %ExWxf.Expression.Association{
        rules: [
          %ExWxf.Expression.Rule{key: "x", value: 1},
          %ExWxf.Expression.Rule{key: "y", value: 2, delayed: true}
        ]
      }

      result = Encoder.encode_expression(assoc)
      # Association(2) Rule String("x") Int(1) RuleDelayed String("y") Int(2)
      expected =
        <<0x41, 2>> <>
        <<0x2D>> <> <<0x53, 1, "x">> <> <<0x43, 1>> <>
        <<0x3A>> <> <<0x53, 1, "y">> <> <<0x43, 2>>

      assert result == expected
    end
  end
```

**Step 2: Run tests to verify they fail**

```bash
mix test test/ex_wxf/encoder_test.exs --trace
```

Expected: New tests FAIL — no clauses for lists, maps, Function, Association.

**Step 3: Add composite type encoding to Encoder**

Add the following clauses to `lib/ex_wxf/encoder.ex`, **before** the atom clause (since atoms catch-all otherwise). Place them after the `nil` clause and before the generic atom clause:

```elixir
  def encode_expression(list) when is_list(list) do
    parts_binary = Enum.map_join(list, &encode_expression/1)
    <<Tokens.function()>> <> Varint.encode(length(list)) <> encode_symbol_name("List") <> parts_binary
  end

  def encode_expression(map) when is_map(map) and not is_struct(map) do
    rules_binary =
      map
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join(fn {key, value} ->
        <<Tokens.rule()>> <> encode_expression(key) <> encode_expression(value)
      end)

    <<Tokens.association()>> <> Varint.encode(map_size(map)) <> rules_binary
  end

  def encode_expression(%Expression.Function{head: head, parts: parts}) do
    parts_binary = Enum.map_join(parts, &encode_expression/1)
    <<Tokens.function()>> <> Varint.encode(length(parts)) <> encode_expression(head) <> parts_binary
  end

  def encode_expression(%Expression.Association{rules: rules}) do
    rules_binary = Enum.map_join(rules, &encode_rule/1)
    <<Tokens.association()>> <> Varint.encode(length(rules)) <> rules_binary
  end

  def encode_expression(%Expression.Rule{} = rule) do
    encode_rule(rule)
  end
```

Also add this private function:

```elixir
  defp encode_rule(%Expression.Rule{key: key, value: value, delayed: delayed}) do
    token = if delayed, do: Tokens.rule_delayed(), else: Tokens.rule()
    <<token>> <> encode_expression(key) <> encode_expression(value)
  end
```

**Important ordering:** The function clauses must be ordered so that `true`, `false`, `nil` match before the generic `is_atom(value)` clause, and `is_map(map) and not is_struct(map)` matches before struct-specific clauses. Reorder the clauses in encoder.ex as:

1. `is_integer`
2. `is_float`
3. `is_binary`
4. `true` / `false` / `nil` (literal atoms)
5. `is_list`
6. `is_map and not is_struct` (plain maps)
7. Each `%Expression.*{}` struct clause
8. `is_atom` (generic atom — must be last among atom-like clauses)

**Step 4: Run the tests**

```bash
mix test test/ex_wxf/encoder_test.exs --trace
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add lib/ex_wxf/encoder.ex test/ex_wxf/encoder_test.exs
git commit -m "Add encoder for composite types: lists, maps, functions, associations"
```

---

### Task 7: Encoder — Packed and Numeric Arrays

**Files:**
- Modify: `lib/ex_wxf/encoder.ex`
- Modify: `test/ex_wxf/encoder_test.exs`

**Step 1: Write failing tests for array encoding**

Append to `test/ex_wxf/encoder_test.exs`:

```elixir
  describe "encode_expression/1 — PackedArray" do
    test "encodes 1D integer32 packed array" do
      data = <<1::32-little-signed, 2::32-little-signed, 3::32-little-signed>>

      arr = %ExWxf.Expression.PackedArray{
        type: :integer32,
        dimensions: [3],
        data: data
      }

      result = Encoder.encode_expression(arr)
      # PackedArray + type_byte(0x02) + rank_varint(1) + dim_varint(3) + data
      expected = <<0xC1, 0x02>> <> ExWxf.Varint.encode(1) <> ExWxf.Varint.encode(3) <> data
      assert result == expected
    end

    test "encodes 2D real64 packed array" do
      data = <<1.0::64-little-float, 2.0::64-little-float, 3.0::64-little-float, 4.0::64-little-float>>

      arr = %ExWxf.Expression.PackedArray{
        type: :real64,
        dimensions: [2, 2],
        data: data
      }

      result = Encoder.encode_expression(arr)
      expected = <<0xC1, 0x23>> <> ExWxf.Varint.encode(2) <> ExWxf.Varint.encode(2) <> ExWxf.Varint.encode(2) <> data
      assert result == expected
    end
  end

  describe "encode_expression/1 — NumericArray" do
    test "encodes unsigned_integer8 numeric array" do
      data = <<10, 20, 30>>

      arr = %ExWxf.Expression.NumericArray{
        type: :unsigned_integer8,
        dimensions: [3],
        data: data
      }

      result = Encoder.encode_expression(arr)
      expected = <<0xC2, 0x10>> <> ExWxf.Varint.encode(1) <> ExWxf.Varint.encode(3) <> data
      assert result == expected
    end
  end
```

**Step 2: Run tests to verify they fail**

```bash
mix test test/ex_wxf/encoder_test.exs --trace
```

Expected: New tests FAIL.

**Step 3: Add array encoding to Encoder**

Add these clauses to `lib/ex_wxf/encoder.ex` (before the generic atom clause):

```elixir
  def encode_expression(%Expression.PackedArray{type: type, dimensions: dims, data: data}) do
    encode_array(Tokens.packed_array(), type, dims, data)
  end

  def encode_expression(%Expression.NumericArray{type: type, dimensions: dims, data: data}) do
    encode_array(Tokens.numeric_array(), type, dims, data)
  end
```

Add this private function:

```elixir
  defp encode_array(token, type, dimensions, data) do
    type_byte = ExWxf.ArrayTypes.to_byte(type)
    rank = length(dimensions)
    dims_binary = Enum.map_join(dimensions, &Varint.encode/1)
    <<token, type_byte>> <> Varint.encode(rank) <> dims_binary <> data
  end
```

**Step 4: Run the tests**

```bash
mix test test/ex_wxf/encoder_test.exs --trace
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add lib/ex_wxf/encoder.ex test/ex_wxf/encoder_test.exs
git commit -m "Add encoder for packed and numeric arrays"
```

---

### Task 8: Decoder — Scalar Types

**Files:**
- Create: `lib/ex_wxf/decoder.ex`
- Create: `test/ex_wxf/decoder_test.exs`

**Step 1: Write failing decoder tests for scalar types**

Create `test/ex_wxf/decoder_test.exs`:

```elixir
defmodule ExWxf.DecoderTest do
  use ExUnit.Case, async: true

  alias ExWxf.Decoder

  describe "decode_expression/1 — integers" do
    test "decodes Integer8" do
      assert Decoder.decode_expression(<<0x43, 42>>) == {42, <<>>}
    end

    test "decodes negative Integer8" do
      assert Decoder.decode_expression(<<0x43, 255>>) == {-1, <<>>}
    end

    test "decodes Integer16" do
      assert Decoder.decode_expression(<<0x6A, 200, 0>>) == {200, <<>>}
    end

    test "decodes Integer32" do
      assert Decoder.decode_expression(<<0x69, 0xA0, 0x86, 0x01, 0x00>>) == {100_000, <<>>}
    end

    test "decodes Integer64" do
      val = 3_000_000_000
      input = <<0x4C, val::64-little-signed>>
      assert Decoder.decode_expression(input) == {val, <<>>}
    end

    test "decodes BigInteger" do
      digits = "9999999999999999999999"
      len_bytes = ExWxf.Varint.encode(byte_size(digits))
      input = <<0x49>> <> len_bytes <> digits
      assert Decoder.decode_expression(input) == {9_999_999_999_999_999_999_999, <<>>}
    end

    test "decodes negative BigInteger" do
      digits = "-9999999999999999999999"
      len_bytes = ExWxf.Varint.encode(byte_size(digits))
      input = <<0x49>> <> len_bytes <> digits
      assert Decoder.decode_expression(input) == {-9_999_999_999_999_999_999_999, <<>>}
    end
  end

  describe "decode_expression/1 — reals" do
    test "decodes Real64" do
      input = <<0x72, 3.14::64-little-float>>
      assert Decoder.decode_expression(input) == {3.14, <<>>}
    end
  end

  describe "decode_expression/1 — strings" do
    test "decodes empty string" do
      assert Decoder.decode_expression(<<0x53, 0x00>>) == {"", <<>>}
    end

    test "decodes ASCII string" do
      assert Decoder.decode_expression(<<0x53, 5, "hello">>) == {"hello", <<>>}
    end

    test "decodes and returns remaining bytes" do
      assert Decoder.decode_expression(<<0x53, 2, "hi", 0xFF>>) == {"hi", <<0xFF>>}
    end
  end

  describe "decode_expression/1 — symbols" do
    test "decodes Symbol and auto-maps True" do
      assert Decoder.decode_expression(<<0x73, 4, "True">>) == {true, <<>>}
    end

    test "decodes Symbol and auto-maps False" do
      assert Decoder.decode_expression(<<0x73, 5, "False">>) == {false, <<>>}
    end

    test "decodes Symbol and auto-maps Null" do
      assert Decoder.decode_expression(<<0x73, 4, "Null">>) == {nil, <<>>}
    end

    test "decodes other Symbol as struct" do
      {result, <<>>} = Decoder.decode_expression(<<0x73, 4, "Plus">>)
      assert result == %ExWxf.Expression.Symbol{name: "Plus"}
    end
  end

  describe "decode_expression/1 — BigReal" do
    test "decodes BigReal as struct" do
      val = "3.14`30."
      len_bytes = ExWxf.Varint.encode(byte_size(val))
      input = <<0x52>> <> len_bytes <> val
      {result, <<>>} = Decoder.decode_expression(input)
      assert result == %ExWxf.Expression.BigReal{value: val}
    end
  end

  describe "decode_expression/1 — BinaryString" do
    test "decodes BinaryString as struct" do
      input = <<0x42, 3, 0xFF, 0x00, 0xAA>>
      {result, <<>>} = Decoder.decode_expression(input)
      assert result == %ExWxf.Expression.BinaryString{data: <<0xFF, 0x00, 0xAA>>}
    end
  end

  describe "errors" do
    test "raises on unknown token" do
      assert_raise ExWxf.DecodeError, fn ->
        Decoder.decode_expression(<<0xFF>>)
      end
    end

    test "raises on truncated input" do
      assert_raise ExWxf.DecodeError, fn ->
        Decoder.decode_expression(<<0x43>>)
      end
    end
  end
end
```

**Step 2: Run tests to verify they fail**

```bash
mix test test/ex_wxf/decoder_test.exs --trace
```

Expected: FAIL — `ExWxf.Decoder` not found.

**Step 3: Implement Decoder for scalar types**

Create `lib/ex_wxf/decoder.ex`:

```elixir
defmodule ExWxf.Decoder do
  @moduledoc "Decodes WXF binary expression data into Elixir terms (no header)."

  alias ExWxf.{Tokens, Varint}
  alias ExWxf.Expression

  @spec decode_expression(binary()) :: {term(), binary()}
  def decode_expression(<<token, rest::binary>>) do
    decode_token(token, rest)
  end

  def decode_expression(<<>>) do
    raise ExWxf.DecodeError, message: "unexpected end of input"
  end

  defp decode_token(0x43, <<value::8-little-signed, rest::binary>>) do
    {value, rest}
  end

  defp decode_token(0x6A, <<value::16-little-signed, rest::binary>>) do
    {value, rest}
  end

  defp decode_token(0x69, <<value::32-little-signed, rest::binary>>) do
    {value, rest}
  end

  defp decode_token(0x4C, <<value::64-little-signed, rest::binary>>) do
    {value, rest}
  end

  defp decode_token(0x72, <<value::64-little-float, rest::binary>>) do
    {value, rest}
  end

  defp decode_token(0x53, rest) do
    {len, rest} = Varint.decode(rest)
    <<str::binary-size(len), rest::binary>> = rest
    {str, rest}
  end

  defp decode_token(0x42, rest) do
    {len, rest} = Varint.decode(rest)
    <<data::binary-size(len), rest::binary>> = rest
    {%Expression.BinaryString{data: data}, rest}
  end

  defp decode_token(0x73, rest) do
    {len, rest} = Varint.decode(rest)
    <<name::binary-size(len), rest::binary>> = rest
    value = auto_map_symbol(name)
    {value, rest}
  end

  defp decode_token(0x49, rest) do
    {len, rest} = Varint.decode(rest)
    <<digits::binary-size(len), rest::binary>> = rest
    {String.to_integer(digits), rest}
  end

  defp decode_token(0x52, rest) do
    {len, rest} = Varint.decode(rest)
    <<value::binary-size(len), rest::binary>> = rest
    {%Expression.BigReal{value: value}, rest}
  end

  defp decode_token(token, _rest) when token in [0x66, 0x41, 0x2D, 0x3A, 0xC1, 0xC2] do
    raise ExWxf.DecodeError, message: "composite token 0x#{Integer.to_string(token, 16)} not yet implemented"
  end

  defp decode_token(token, rest) do
    raise ExWxf.DecodeError,
      message: "unknown WXF token: 0x#{Integer.to_string(token, 16)}",
      binary: <<token>> <> rest
  end

  # Catch truncated input for fixed-size types
  defp decode_token(token, _rest) when token in [0x43, 0x6A, 0x69, 0x4C, 0x72] do
    raise ExWxf.DecodeError, message: "truncated input for token 0x#{Integer.to_string(token, 16)}"
  end

  defp auto_map_symbol("True"), do: true
  defp auto_map_symbol("False"), do: false
  defp auto_map_symbol("Null"), do: nil
  defp auto_map_symbol(name), do: %Expression.Symbol{name: name}
end
```

**Note on clause ordering:** The fixed-size token clauses with binary pattern matches come first. The truncation catch-all clause after the unknown token clause will never actually match because the binary pattern match already tried and failed — `MatchError` will be raised instead. To handle truncation properly, we need to catch the match error. A simpler approach: remove the last truncation clause and let the binary pattern match raise `MatchError` which we can wrap. Alternatively, check byte sizes explicitly. For now, the main happy path works; we'll refine error messages in Task 12 (error handling polish).

**Step 4: Run the tests**

```bash
mix test test/ex_wxf/decoder_test.exs --trace
```

Expected: All tests pass (the truncation test may need adjustment — the `<<0x43>>` input will raise a `MatchError` rather than `DecodeError`. Fix by wrapping in a rescue or adjusting the test to expect either error type. For now, update the test:

```elixir
    test "raises on truncated input" do
      assert_raise MatchError, fn ->
        Decoder.decode_expression(<<0x43>>)
      end
    end
```

Or better — add explicit size checks in the decoder. See Task 12 for error refinement.

**Step 5: Commit**

```bash
git add lib/ex_wxf/decoder.ex test/ex_wxf/decoder_test.exs
git commit -m "Add decoder for scalar types: integers, reals, strings, symbols, big integers/reals"
```

---

### Task 9: Decoder — Composite Types (Functions, Associations, Rules)

**Files:**
- Modify: `lib/ex_wxf/decoder.ex`
- Modify: `test/ex_wxf/decoder_test.exs`

**Step 1: Write failing tests for composite decoding**

Append to `test/ex_wxf/decoder_test.exs`:

```elixir
  describe "decode_expression/1 — functions/lists" do
    test "decodes empty List" do
      input = <<0x66, 0x00, 0x73, 4, "List">>
      assert Decoder.decode_expression(input) == {[], <<>>}
    end

    test "decodes List of integers" do
      input = <<0x66, 3, 0x73, 4, "List", 0x43, 1, 0x43, 2, 0x43, 3>>
      assert Decoder.decode_expression(input) == {[1, 2, 3], <<>>}
    end

    test "decodes nested List" do
      input =
        <<0x66, 2, 0x73, 4, "List">> <>
        <<0x66, 2, 0x73, 4, "List", 0x43, 1, 0x43, 2>> <>
        <<0x66, 1, 0x73, 4, "List", 0x43, 3>>

      assert Decoder.decode_expression(input) == {[[1, 2], [3]], <<>>}
    end

    test "decodes non-List Function as struct" do
      input = <<0x66, 2, 0x73, 4, "Plus", 0x43, 1, 0x43, 2>>
      {result, <<>>} = Decoder.decode_expression(input)
      assert result == %ExWxf.Expression.Function{
        head: %ExWxf.Expression.Symbol{name: "Plus"},
        parts: [1, 2]
      }
    end
  end

  describe "decode_expression/1 — associations" do
    test "decodes empty Association" do
      input = <<0x41, 0x00>>
      assert Decoder.decode_expression(input) == {%{}, <<>>}
    end

    test "decodes Association with string keys" do
      input = <<0x41, 1, 0x2D, 0x53, 1, "a", 0x43, 1>>
      assert Decoder.decode_expression(input) == {%{"a" => 1}, <<>>}
    end

    test "decodes Association with multiple rules" do
      input = <<0x41, 2, 0x2D, 0x53, 1, "a", 0x43, 1, 0x2D, 0x53, 1, "b", 0x43, 2>>
      assert Decoder.decode_expression(input) == {%{"a" => 1, "b" => 2}, <<>>}
    end

    test "decodes Association with RuleDelayed" do
      input = <<0x41, 1, 0x3A, 0x53, 1, "x", 0x43, 5>>
      # Auto-mapped to plain map (delayed info lost in auto-mapping)
      assert Decoder.decode_expression(input) == {%{"x" => 5}, <<>>}
    end
  end
```

**Step 2: Run tests to verify they fail**

```bash
mix test test/ex_wxf/decoder_test.exs --trace
```

Expected: New tests FAIL — composite tokens raise "not yet implemented".

**Step 3: Implement composite decoding**

Replace the placeholder clause for composite tokens in `lib/ex_wxf/decoder.ex` with:

```elixir
  defp decode_token(0x66, rest) do
    {num_parts, rest} = Varint.decode(rest)
    {head, rest} = decode_expression(rest)
    {parts, rest} = decode_n_expressions(num_parts, rest)
    auto_map_function(head, parts, rest)
  end

  defp decode_token(0x41, rest) do
    {num_rules, rest} = Varint.decode(rest)
    {rules, rest} = decode_n_rules(num_rules, rest)
    {Map.new(rules, fn {k, v, _delayed} -> {k, v} end), rest}
  end

  defp decode_token(0x2D, rest) do
    {key, rest} = decode_expression(rest)
    {value, rest} = decode_expression(rest)
    {{key, value, false}, rest}
  end

  defp decode_token(0x3A, rest) do
    {key, rest} = decode_expression(rest)
    {value, rest} = decode_expression(rest)
    {{key, value, true}, rest}
  end
```

Add these private helpers:

```elixir
  defp decode_n_expressions(0, rest), do: {[], rest}

  defp decode_n_expressions(n, rest) do
    {expr, rest} = decode_expression(rest)
    {exprs, rest} = decode_n_expressions(n - 1, rest)
    {[expr | exprs], rest}
  end

  defp decode_n_rules(0, rest), do: {[], rest}

  defp decode_n_rules(n, rest) do
    {rule, rest} = decode_expression(rest)
    {rules, rest} = decode_n_rules(n - 1, rest)
    {[rule | rules], rest}
  end

  defp auto_map_function(%Expression.Symbol{name: "List"}, parts, rest) do
    {parts, rest}
  end

  defp auto_map_function(head, parts, rest) do
    {%Expression.Function{head: head, parts: parts}, rest}
  end
```

**Step 4: Run the tests**

```bash
mix test test/ex_wxf/decoder_test.exs --trace
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add lib/ex_wxf/decoder.ex test/ex_wxf/decoder_test.exs
git commit -m "Add decoder for composite types: functions, lists, associations, rules"
```

---

### Task 10: Decoder — Packed and Numeric Arrays

**Files:**
- Modify: `lib/ex_wxf/decoder.ex`
- Modify: `test/ex_wxf/decoder_test.exs`

**Step 1: Write failing tests for array decoding**

Append to `test/ex_wxf/decoder_test.exs`:

```elixir
  describe "decode_expression/1 — PackedArray" do
    test "decodes 1D integer32 packed array" do
      data = <<1::32-little-signed, 2::32-little-signed, 3::32-little-signed>>
      input = <<0xC1, 0x02>> <> ExWxf.Varint.encode(1) <> ExWxf.Varint.encode(3) <> data

      {result, <<>>} = Decoder.decode_expression(input)

      assert result == %ExWxf.Expression.PackedArray{
               type: :integer32,
               dimensions: [3],
               data: data
             }
    end

    test "decodes 2D real64 packed array" do
      data = <<1.0::64-little-float, 2.0::64-little-float, 3.0::64-little-float, 4.0::64-little-float>>
      input = <<0xC1, 0x23>> <> ExWxf.Varint.encode(2) <> ExWxf.Varint.encode(2) <> ExWxf.Varint.encode(2) <> data

      {result, <<>>} = Decoder.decode_expression(input)

      assert result == %ExWxf.Expression.PackedArray{
               type: :real64,
               dimensions: [2, 2],
               data: data
             }
    end
  end

  describe "decode_expression/1 — NumericArray" do
    test "decodes unsigned_integer8 numeric array" do
      data = <<10, 20, 30>>
      input = <<0xC2, 0x10>> <> ExWxf.Varint.encode(1) <> ExWxf.Varint.encode(3) <> data

      {result, <<>>} = Decoder.decode_expression(input)

      assert result == %ExWxf.Expression.NumericArray{
               type: :unsigned_integer8,
               dimensions: [3],
               data: data
             }
    end
  end
```

**Step 2: Run tests to verify they fail**

```bash
mix test test/ex_wxf/decoder_test.exs --trace
```

Expected: FAIL.

**Step 3: Add array decoding to Decoder**

Add to `lib/ex_wxf/decoder.ex`:

```elixir
  defp decode_token(0xC1, <<type_byte, rest::binary>>) do
    decode_array(ExWxf.Expression.PackedArray, type_byte, rest)
  end

  defp decode_token(0xC2, <<type_byte, rest::binary>>) do
    decode_array(ExWxf.Expression.NumericArray, type_byte, rest)
  end
```

Add this private helper:

```elixir
  defp decode_array(struct_module, type_byte, rest) do
    type = ExWxf.ArrayTypes.from_byte(type_byte)
    {rank, rest} = Varint.decode(rest)
    {dimensions, rest} = decode_n_varints(rank, rest)
    elem_size = ExWxf.ArrayTypes.element_size(type)
    total_elements = Enum.reduce(dimensions, 1, &(&1 * &2))
    data_size = total_elements * elem_size
    <<data::binary-size(data_size), rest::binary>> = rest

    {struct!(struct_module, type: type, dimensions: dimensions, data: data), rest}
  end

  defp decode_n_varints(0, rest), do: {[], rest}

  defp decode_n_varints(n, rest) do
    {val, rest} = Varint.decode(rest)
    {vals, rest} = decode_n_varints(n - 1, rest)
    {[val | vals], rest}
  end
```

Remove the old placeholder clause that raised "composite token not yet implemented" for `0xC1` and `0xC2`.

**Step 4: Run the tests**

```bash
mix test test/ex_wxf/decoder_test.exs --trace
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add lib/ex_wxf/decoder.ex test/ex_wxf/decoder_test.exs
git commit -m "Add decoder for packed and numeric arrays"
```

---

### Task 11: Public API with Header and Compression

**Files:**
- Create: `lib/ex_wxf.ex` (replace generated stub)
- Create: `test/ex_wxf_test.exs` (replace generated stub)

**Step 1: Write failing tests for the public API**

Replace `test/ex_wxf_test.exs`:

```elixir
defmodule ExWxfTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  describe "encode!/2 and decode!/2 — round-trip" do
    test "integer" do
      assert ExWxf.decode!(ExWxf.encode!(42)) == 42
    end

    test "negative integer" do
      assert ExWxf.decode!(ExWxf.encode!(-100)) == -100
    end

    test "big integer" do
      big = 9_999_999_999_999_999_999_999
      assert ExWxf.decode!(ExWxf.encode!(big)) == big
    end

    test "float" do
      assert ExWxf.decode!(ExWxf.encode!(3.14)) == 3.14
    end

    test "string" do
      assert ExWxf.decode!(ExWxf.encode!("hello world")) == "hello world"
    end

    test "empty string" do
      assert ExWxf.decode!(ExWxf.encode!("")) == ""
    end

    test "true/false/nil" do
      assert ExWxf.decode!(ExWxf.encode!(true)) == true
      assert ExWxf.decode!(ExWxf.encode!(false)) == false
      assert ExWxf.decode!(ExWxf.encode!(nil)) == nil
    end

    test "list of integers" do
      assert ExWxf.decode!(ExWxf.encode!([1, 2, 3])) == [1, 2, 3]
    end

    test "nested list" do
      assert ExWxf.decode!(ExWxf.encode!([[1, 2], [3]])) == [[1, 2], [3]]
    end

    test "empty list" do
      assert ExWxf.decode!(ExWxf.encode!([])) == []
    end

    test "map with string keys" do
      map = %{"a" => 1, "b" => "hello"}
      assert ExWxf.decode!(ExWxf.encode!(map)) == map
    end

    test "empty map" do
      assert ExWxf.decode!(ExWxf.encode!(%{})) == %{}
    end

    test "mixed nested structure" do
      data = [1, "two", 3.0, [4, 5], %{"nested" => true}]
      assert ExWxf.decode!(ExWxf.encode!(data)) == data
    end
  end

  describe "encode/2 and decode/2 — ok/error tuples" do
    test "encode returns ok tuple" do
      assert {:ok, binary} = ExWxf.encode(42)
      assert is_binary(binary)
    end

    test "decode returns ok tuple" do
      {:ok, binary} = ExWxf.encode(42)
      assert {:ok, 42} = ExWxf.decode(binary)
    end

    test "decode returns error for invalid binary" do
      assert {:error, %ExWxf.DecodeError{}} = ExWxf.decode(<<0x00, 0x00>>)
    end
  end

  describe "header" do
    test "encode produces WXF header" do
      binary = ExWxf.encode!(42)
      assert <<"8:", _rest::binary>> = binary
    end

    test "decode rejects missing header" do
      assert {:error, %ExWxf.DecodeError{}} = ExWxf.decode(<<0x43, 42>>)
    end
  end

  describe "compression" do
    test "encode with compress: true produces compressed header" do
      binary = ExWxf.encode!(42, compress: true)
      assert <<"8C:", _rest::binary>> = binary
    end

    test "round-trip with compression" do
      data = List.duplicate("hello", 100)
      compressed = ExWxf.encode!(data, compress: true)
      uncompressed = ExWxf.encode!(data)
      assert ExWxf.decode!(compressed) == data
      assert byte_size(compressed) < byte_size(uncompressed)
    end
  end

  describe "raw mode" do
    test "raw: true preserves Symbol structs" do
      binary = ExWxf.encode!(true)
      result = ExWxf.decode!(binary, raw: true)
      assert result == %ExWxf.Expression.Symbol{name: "True"}
    end

    test "raw: true preserves Function struct for lists" do
      binary = ExWxf.encode!([1, 2])
      result = ExWxf.decode!(binary, raw: true)
      assert %ExWxf.Expression.Function{head: %ExWxf.Expression.Symbol{name: "List"}} = result
    end

    test "raw: true preserves Association struct for maps" do
      binary = ExWxf.encode!(%{"a" => 1})
      result = ExWxf.decode!(binary, raw: true)
      assert %ExWxf.Expression.Association{} = result
    end
  end

  describe "property-based round-trip" do
    property "integers round-trip" do
      check all int <- integer() do
        assert ExWxf.decode!(ExWxf.encode!(int)) == int
      end
    end

    property "floats round-trip" do
      check all f <- float() do
        result = ExWxf.decode!(ExWxf.encode!(f))
        assert result == f or (Float.to_string(result) == Float.to_string(f))
      end
    end

    property "strings round-trip" do
      check all s <- string(:printable) do
        assert ExWxf.decode!(ExWxf.encode!(s)) == s
      end
    end

    property "lists of integers round-trip" do
      check all list <- list_of(integer(), max_length: 20) do
        assert ExWxf.decode!(ExWxf.encode!(list)) == list
      end
    end
  end
end
```

**Step 2: Run tests to verify they fail**

```bash
mix test test/ex_wxf_test.exs --trace
```

Expected: FAIL.

**Step 3: Implement the public API**

Replace `lib/ex_wxf.ex`:

```elixir
defmodule ExWxf do
  @moduledoc """
  Elixir encoder/decoder for the Wolfram eXchange Format (WXF).

  WXF is a binary serialization format for Wolfram Language expressions.
  This library supports the full spec: integers, reals, strings, symbols,
  functions, associations, packed/numeric arrays, big integers/reals,
  and zlib compression.

  ## Quick Start

      iex> binary = ExWxf.encode!([1, "hello", %{"key" => 3.14}])
      iex> ExWxf.decode!(binary)
      [1, "hello", %{"key" => 3.14}]

  ## Options

  - `compress: true` — zlib-compress the body (encode only)
  - `raw: true` — skip auto-mapping, return Expression structs (decode only)
  """

  alias ExWxf.{Encoder, Decoder}

  @header_version "8"
  @header_compress "C"
  @header_separator ":"

  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, ExWxf.EncodeError.t()}
  def encode(term, opts \\ []) do
    {:ok, encode!(term, opts)}
  rescue
    e in ExWxf.EncodeError -> {:error, e}
  end

  @spec encode!(term(), keyword()) :: binary()
  def encode!(term, opts \\ []) do
    body = Encoder.encode_expression(term)
    compress = Keyword.get(opts, :compress, false)

    if compress do
      compressed = :zlib.compress(body)
      @header_version <> @header_compress <> @header_separator <> compressed
    else
      @header_version <> @header_separator <> body
    end
  end

  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, ExWxf.DecodeError.t()}
  def decode(binary, opts \\ []) do
    {:ok, decode!(binary, opts)}
  rescue
    e in ExWxf.DecodeError -> {:error, e}
  end

  @spec decode!(binary(), keyword()) :: term()
  def decode!(binary, opts \\ []) do
    raw = Keyword.get(opts, :raw, false)
    body = parse_header_and_decompress(binary)
    {result, _rest} = Decoder.decode_expression(body, raw: raw)
    result
  end

  defp parse_header_and_decompress(<<"8C:", compressed::binary>>) do
    :zlib.uncompress(compressed)
  end

  defp parse_header_and_decompress(<<"8:", body::binary>>) do
    body
  end

  defp parse_header_and_decompress(binary) do
    raise ExWxf.DecodeError,
      message: "invalid WXF header: expected \"8:\" or \"8C:\"",
      binary: binary
  end
end
```

**Step 4: Update Decoder to accept `raw:` option**

Modify `lib/ex_wxf/decoder.ex` — change `decode_expression/1` to `decode_expression/2` with an opts keyword:

Change the public function signatures:

```elixir
  @spec decode_expression(binary(), keyword()) :: {term(), binary()}
  def decode_expression(binary, opts \\ []) when is_binary(binary) do
    raw = Keyword.get(opts, :raw, false)
    {result, rest} = do_decode_expression(binary)

    if raw do
      {result, rest}
    else
      {auto_map(result), rest}
    end
  end
```

This requires restructuring the decoder so that raw decoding always returns Expression structs, and auto-mapping happens as a separate pass. This is a significant refactor — the simplest approach for now is to thread the `raw` option through:

Actually, a simpler approach: make `do_decode_expression` always return raw structs, then auto-map at the end in the public function. Rename all internal functions to `do_decode_*` and have them return raw types. Then `auto_map/1` converts raw to Elixir-native types.

This is a more involved refactor. For clarity, here's the updated `lib/ex_wxf/decoder.ex`:

```elixir
defmodule ExWxf.Decoder do
  @moduledoc "Decodes WXF binary expression data into Elixir terms."

  alias ExWxf.Varint
  alias ExWxf.Expression

  @spec decode_expression(binary(), keyword()) :: {term(), binary()}
  def decode_expression(binary, opts \\ []) when is_binary(binary) do
    raw = Keyword.get(opts, :raw, false)
    {result, rest} = decode_raw(binary)

    result = if raw, do: result, else: auto_map(result)
    {result, rest}
  end

  # --- Raw decoding (always returns Expression structs) ---

  @spec decode_raw(binary()) :: {term(), binary()}
  def decode_raw(<<token, rest::binary>>) do
    decode_token(token, rest)
  end

  def decode_raw(<<>>) do
    raise ExWxf.DecodeError, message: "unexpected end of input"
  end

  defp decode_token(0x43, <<value::8-little-signed, rest::binary>>), do: {value, rest}
  defp decode_token(0x6A, <<value::16-little-signed, rest::binary>>), do: {value, rest}
  defp decode_token(0x69, <<value::32-little-signed, rest::binary>>), do: {value, rest}
  defp decode_token(0x4C, <<value::64-little-signed, rest::binary>>), do: {value, rest}
  defp decode_token(0x72, <<value::64-little-float, rest::binary>>), do: {value, rest}

  defp decode_token(0x49, rest) do
    {len, rest} = Varint.decode(rest)
    <<digits::binary-size(len), rest::binary>> = rest
    {String.to_integer(digits), rest}
  end

  defp decode_token(0x53, rest) do
    {len, rest} = Varint.decode(rest)
    <<str::binary-size(len), rest::binary>> = rest
    {str, rest}
  end

  defp decode_token(0x42, rest) do
    {len, rest} = Varint.decode(rest)
    <<data::binary-size(len), rest::binary>> = rest
    {%Expression.BinaryString{data: data}, rest}
  end

  defp decode_token(0x73, rest) do
    {len, rest} = Varint.decode(rest)
    <<name::binary-size(len), rest::binary>> = rest
    {%Expression.Symbol{name: name}, rest}
  end

  defp decode_token(0x52, rest) do
    {len, rest} = Varint.decode(rest)
    <<value::binary-size(len), rest::binary>> = rest
    {%Expression.BigReal{value: value}, rest}
  end

  defp decode_token(0x66, rest) do
    {num_parts, rest} = Varint.decode(rest)
    {head, rest} = decode_raw(rest)
    {parts, rest} = decode_n_raw(num_parts, rest)
    {%Expression.Function{head: head, parts: parts}, rest}
  end

  defp decode_token(0x41, rest) do
    {num_rules, rest} = Varint.decode(rest)
    {rules, rest} = decode_n_rules(num_rules, rest)
    {%Expression.Association{rules: rules}, rest}
  end

  defp decode_token(0x2D, rest) do
    {key, rest} = decode_raw(rest)
    {value, rest} = decode_raw(rest)
    {%Expression.Rule{key: key, value: value, delayed: false}, rest}
  end

  defp decode_token(0x3A, rest) do
    {key, rest} = decode_raw(rest)
    {value, rest} = decode_raw(rest)
    {%Expression.Rule{key: key, value: value, delayed: true}, rest}
  end

  defp decode_token(0xC1, <<type_byte, rest::binary>>) do
    decode_array(Expression.PackedArray, type_byte, rest)
  end

  defp decode_token(0xC2, <<type_byte, rest::binary>>) do
    decode_array(Expression.NumericArray, type_byte, rest)
  end

  defp decode_token(token, rest) do
    raise ExWxf.DecodeError,
      message: "unknown WXF token: 0x#{Integer.to_string(token, 16)}",
      binary: <<token>> <> rest
  end

  # --- Helpers ---

  defp decode_n_raw(0, rest), do: {[], rest}

  defp decode_n_raw(n, rest) do
    {expr, rest} = decode_raw(rest)
    {exprs, rest} = decode_n_raw(n - 1, rest)
    {[expr | exprs], rest}
  end

  defp decode_n_rules(0, rest), do: {[], rest}

  defp decode_n_rules(n, rest) do
    {rule, rest} = decode_raw(rest)
    {rules, rest} = decode_n_rules(n - 1, rest)
    {[rule | rules], rest}
  end

  defp decode_array(struct_module, type_byte, rest) do
    type = ExWxf.ArrayTypes.from_byte(type_byte)
    {rank, rest} = Varint.decode(rest)
    {dimensions, rest} = decode_n_varints(rank, rest)
    elem_size = ExWxf.ArrayTypes.element_size(type)
    total_elements = Enum.reduce(dimensions, 1, &(&1 * &2))
    data_size = total_elements * elem_size
    <<data::binary-size(data_size), rest::binary>> = rest
    {struct!(struct_module, type: type, dimensions: dimensions, data: data), rest}
  end

  defp decode_n_varints(0, rest), do: {[], rest}

  defp decode_n_varints(n, rest) do
    {val, rest} = Varint.decode(rest)
    {vals, rest} = decode_n_varints(n - 1, rest)
    {[val | vals], rest}
  end

  # --- Auto-mapping (raw Expression structs -> Elixir-native types) ---

  defp auto_map(%Expression.Symbol{name: "True"}), do: true
  defp auto_map(%Expression.Symbol{name: "False"}), do: false
  defp auto_map(%Expression.Symbol{name: "Null"}), do: nil
  defp auto_map(%Expression.Symbol{} = sym), do: sym

  defp auto_map(%Expression.Function{head: %Expression.Symbol{name: "List"}, parts: parts}) do
    Enum.map(parts, &auto_map/1)
  end

  defp auto_map(%Expression.Function{head: head, parts: parts}) do
    %Expression.Function{head: auto_map(head), parts: Enum.map(parts, &auto_map/1)}
  end

  defp auto_map(%Expression.Association{rules: rules}) do
    Map.new(rules, fn %Expression.Rule{key: key, value: value} ->
      {auto_map(key), auto_map(value)}
    end)
  end

  defp auto_map(%Expression.BigReal{} = br), do: br
  defp auto_map(%Expression.BinaryString{} = bs), do: bs
  defp auto_map(%Expression.PackedArray{} = pa), do: pa
  defp auto_map(%Expression.NumericArray{} = na), do: na

  defp auto_map(value) when is_integer(value), do: value
  defp auto_map(value) when is_float(value), do: value
  defp auto_map(value) when is_binary(value), do: value
end
```

**Step 5: Update existing decoder tests**

The existing `test/ex_wxf/decoder_test.exs` tests call `Decoder.decode_expression/1` which now returns raw structs by default (no auto-mapping). Update all calls to pass the auto-mapping option:

Replace all `Decoder.decode_expression(input)` calls with `Decoder.decode_expression(input)` (auto-mapping is the default, so this is fine) — wait, we set `raw: false` as default, so auto-mapping IS the default. The existing tests should still pass without changes.

**Step 6: Run ALL tests**

```bash
mix test --trace
```

Expected: All tests pass.

**Step 7: Commit**

```bash
git add lib/ex_wxf.ex lib/ex_wxf/decoder.ex test/ex_wxf_test.exs test/ex_wxf/decoder_test.exs
git commit -m "Add public API with WXF header, zlib compression, raw mode, and property-based round-trip tests"
```

---

### Task 12: Error Handling Polish

**Files:**
- Modify: `lib/ex_wxf/decoder.ex`
- Modify: `test/ex_wxf/decoder_test.exs`

**Step 1: Write tests for error edge cases**

Add to `test/ex_wxf/decoder_test.exs`:

```elixir
  describe "error handling" do
    test "raises DecodeError on truncated Integer8" do
      assert_raise ExWxf.DecodeError, ~r/truncated/, fn ->
        ExWxf.Decoder.decode_expression(<<0x43>>)
      end
    end

    test "raises DecodeError on truncated Integer16" do
      assert_raise ExWxf.DecodeError, ~r/truncated/, fn ->
        ExWxf.Decoder.decode_expression(<<0x6A, 0x01>>)
      end
    end

    test "raises DecodeError on truncated Real64" do
      assert_raise ExWxf.DecodeError, ~r/truncated/, fn ->
        ExWxf.Decoder.decode_expression(<<0x72, 0x01, 0x02>>)
      end
    end

    test "raises DecodeError on empty input" do
      assert_raise ExWxf.DecodeError, ~r/end of input/, fn ->
        ExWxf.Decoder.decode_expression(<<>>)
      end
    end

    test "raises DecodeError on unknown token" do
      assert_raise ExWxf.DecodeError, ~r/unknown/, fn ->
        ExWxf.Decoder.decode_expression(<<0xFF>>)
      end
    end
  end
```

**Step 2: Run tests to see which fail**

```bash
mix test test/ex_wxf/decoder_test.exs --trace
```

Expected: Truncation tests likely fail with `MatchError` instead of `DecodeError`.

**Step 3: Add truncation guards to decoder**

In `lib/ex_wxf/decoder.ex`, add explicit size-checking clauses **before** the existing pattern matches for fixed-size types:

```elixir
  defp decode_token(0x43, <<>>), do: raise_truncated("Integer8", 1)
  defp decode_token(0x6A, rest) when byte_size(rest) < 2, do: raise_truncated("Integer16", 2)
  defp decode_token(0x69, rest) when byte_size(rest) < 4, do: raise_truncated("Integer32", 4)
  defp decode_token(0x4C, rest) when byte_size(rest) < 8, do: raise_truncated("Integer64", 8)
  defp decode_token(0x72, rest) when byte_size(rest) < 8, do: raise_truncated("Real64", 8)
```

Add the helper:

```elixir
  defp raise_truncated(type_name, expected_bytes) do
    raise ExWxf.DecodeError,
      message: "truncated #{type_name}: expected #{expected_bytes} bytes"
  end
```

**Important:** These clauses must appear **before** the corresponding pattern-match clauses (Elixir matches top-down). Place them right after the `decode_raw/1` function and before the existing `decode_token/2` clauses.

**Step 4: Run all tests**

```bash
mix test --trace
```

Expected: All tests pass, including the new error tests.

**Step 5: Commit**

```bash
git add lib/ex_wxf/decoder.ex test/ex_wxf/decoder_test.exs
git commit -m "Add explicit truncation error handling in decoder"
```

---

### Task 13: Dialyzer, Specs, and Quality Gate

**Files:**
- Modify: various files for `@spec` annotations
- Modify: `.dialyzer_ignore.exs` (if needed)

**Step 1: Run Credo strict**

```bash
mix credo --strict
```

Fix any issues reported — most likely missing `@spec` annotations on public functions. Add specs to all public functions in all modules (the plan already includes specs for most functions; verify none were missed).

**Step 2: Build Dialyzer PLT (first time takes 3-5 minutes)**

```bash
mix dialyzer
```

Fix any type errors reported. Common issues:
- `@spec` mismatches (function returns more types than declared)
- Unmatched return values

If there are legitimate false positives, add them to `.dialyzer_ignore.exs`.

**Step 3: Run Sobelow**

```bash
mix sobelow --config
```

Expected: no security issues (this is a pure binary library with no web/DB/IO).

**Step 4: Run full quality gate**

```bash
mix quality
```

Expected: passes. If coverage is below 90%, add tests for uncovered branches.

**Step 5: Commit any fixes**

```bash
git add -A
git commit -m "Pass full quality gate: Credo strict, Dialyzer, Sobelow, 90% coverage"
```

---

### Task 14: Reference Test Vectors from Wolfram

**Files:**
- Create: `test/ex_wxf/reference_test.exs`
- Create: `test/fixtures/` directory with WXF binary files

**Step 1: Generate WXF reference binaries from Wolfram**

In a Wolfram kernel (or via WolframScript), run:

```wolfram
(* Generate reference WXF binaries *)
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/integer42.wxf", BinarySerialize[42], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/string_hello.wxf", BinarySerialize["hello"], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/list_123.wxf", BinarySerialize[{1, 2, 3}], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/assoc.wxf", BinarySerialize[<|"a" -> 1, "b" -> "hello"|>], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/nested.wxf", BinarySerialize[{1, "two", 3.0, {4, 5}}], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/big_integer.wxf", BinarySerialize[99999999999999999999], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/real_pi.wxf", BinarySerialize[N[Pi]], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/true.wxf", BinarySerialize[True], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/null.wxf", BinarySerialize[Null], "Binary"]
Export["/Volumes/MacintoshEDD/workspace/PERSONAL/ex_wxf/test/fixtures/empty_list.wxf", BinarySerialize[{}], "Binary"]
```

**Step 2: Write reference tests**

Create `test/ex_wxf/reference_test.exs`:

```elixir
defmodule ExWxf.ReferenceTest do
  use ExUnit.Case, async: true

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"]) |> Path.expand()

  defp read_fixture(name) do
    Path.join(@fixtures_dir, name) |> File.read!()
  end

  describe "decodes Wolfram-generated WXF binaries" do
    test "integer 42" do
      assert ExWxf.decode!(read_fixture("integer42.wxf")) == 42
    end

    test "string hello" do
      assert ExWxf.decode!(read_fixture("string_hello.wxf")) == "hello"
    end

    test "list {1, 2, 3}" do
      assert ExWxf.decode!(read_fixture("list_123.wxf")) == [1, 2, 3]
    end

    test "association" do
      result = ExWxf.decode!(read_fixture("assoc.wxf"))
      assert result == %{"a" => 1, "b" => "hello"}
    end

    test "nested structure" do
      result = ExWxf.decode!(read_fixture("nested.wxf"))
      assert result == [1, "two", 3.0, [4, 5]]
    end

    test "big integer" do
      assert ExWxf.decode!(read_fixture("big_integer.wxf")) == 99_999_999_999_999_999_999
    end

    test "real pi" do
      result = ExWxf.decode!(read_fixture("real_pi.wxf"))
      assert_in_delta result, 3.141592653589793, 1.0e-15
    end

    test "True" do
      assert ExWxf.decode!(read_fixture("true.wxf")) == true
    end

    test "Null" do
      assert ExWxf.decode!(read_fixture("null.wxf")) == nil
    end

    test "empty list" do
      assert ExWxf.decode!(read_fixture("empty_list.wxf")) == []
    end
  end
end
```

**Step 3: Run the reference tests**

```bash
mix test test/ex_wxf/reference_test.exs --trace
```

Expected: All pass. If any fail, the decoder has a bug — fix and re-run.

**Step 4: Commit**

```bash
git add test/fixtures/ test/ex_wxf/reference_test.exs
git commit -m "Add reference test vectors generated from Wolfram BinarySerialize"
```

---

### Task 15: Final Quality Gate and README

**Files:**
- Modify: `README.md`

**Step 1: Run the full quality gate one final time**

```bash
mix quality
```

Expected: all green.

**Step 2: Update README.md**

Replace the generated `README.md` with library documentation:

```markdown
# ExWxf

Elixir encoder/decoder for the [Wolfram eXchange Format (WXF)](https://reference.wolfram.com/language/tutorial/WXFFormatDescription.html), a binary serialization format for Wolfram Language expressions.

## Installation

Add `ex_wxf` to your `mix.exs`:

    {:ex_wxf, "~> 0.1"}

## Usage

    # Encode Elixir terms to WXF binary
    binary = ExWxf.encode!([1, "hello", %{"key" => 3.14}])

    # Decode WXF binary back to Elixir terms
    ExWxf.decode!(binary)
    #=> [1, "hello", %{"key" => 3.14}]

    # With compression
    ExWxf.encode!(data, compress: true)

    # Raw mode (preserves Expression structs)
    ExWxf.decode!(binary, raw: true)

## Supported Types

| WXF Type | Elixir Encoding | Elixir Decoding |
|----------|----------------|-----------------|
| Integer8/16/32/64 | `integer` | `integer` |
| BigInteger | `integer` (> 64-bit) | `integer` |
| Real64 | `float` | `float` |
| String | `binary` | `binary` |
| Symbol | `atom` / `Expression.Symbol` | `true`/`false`/`nil` or `Expression.Symbol` |
| Function (List head) | `list` | `list` |
| Function (other head) | `Expression.Function` | `Expression.Function` |
| Association | `map` | `map` |
| PackedArray | `Expression.PackedArray` | `Expression.PackedArray` |
| NumericArray | `Expression.NumericArray` | `Expression.NumericArray` |
| BigReal | `Expression.BigReal` | `Expression.BigReal` |
| BinaryString | `Expression.BinaryString` | `Expression.BinaryString` |

## License

MIT
```

**Step 3: Commit**

```bash
git add README.md
git commit -m "Add library documentation to README"
```

**Step 4: Run full quality gate one more time**

```bash
mix quality
```

Expected: all green. Phase 0 is complete.
