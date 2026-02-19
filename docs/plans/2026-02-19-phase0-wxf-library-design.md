# Phase 0 Design: ex_wxf — Elixir WXF Library

## Overview

`ex_wxf` is a standalone Hex package that encodes and decodes the Wolfram eXchange Format (WXF), a binary serialization format for Wolfram Language expressions. It covers the full WXF spec: integers, reals, strings, symbols, functions, associations, packed/numeric arrays, big integers/reals, and zlib compression.

This is a prerequisite for the atlas_tracker project's planned ZMQ-based kernel communication, and an open-source contribution to the Elixir ecosystem (no Elixir WXF library exists today).

## Decisions

- **Separate Hex package** — own repo/directory, publishable to hex.pm. Clean dependency boundary.
- **Full WXF spec** — all types including packed/numeric arrays, big integers/reals, compression.
- **Package name: `ex_wxf`** — follows `ex_` convention for Elixir wrappers.
- **Expression struct tree + auto-mapping** — internal structs for full fidelity, but common Elixir types (int, float, string, list, map) auto-map for convenience.

## WXF Format Summary

### Header

Every WXF binary starts with `"8:"` (version 1.0, uncompressed) or `"8C:"` (compressed). The header is always plain ASCII; only the body after `":"` is zlib-compressed when the `C` flag is present.

### Varint Encoding

All lengths use LEB128 (Little-Endian Base 128). Each byte uses 7 data bits and 1 continuation bit (0x80).

### Type Tokens

| Type | Byte | Description |
|------|------|-------------|
| Function | `0x66` | Composite expression: head + N parts |
| Symbol | `0x73` | Wolfram symbol name (UTF-8) |
| String | `0x53` | Unicode string (UTF-8) |
| BinaryString | `0x42` | Raw byte sequence |
| Integer8 | `0x43` | Signed 8-bit integer |
| Integer16 | `0x6A` | Signed 16-bit integer |
| Integer32 | `0x69` | Signed 32-bit integer |
| Integer64 | `0x4C` | Signed 64-bit integer |
| Real64 | `0x72` | IEEE 754 double (little-endian) |
| BigInteger | `0x49` | Arbitrary-precision integer (digit string) |
| BigReal | `0x52` | Arbitrary-precision real (InputForm string) |
| PackedArray | `0xC1` | Homogeneous numeric array (restricted types) |
| NumericArray | `0xC2` | Homogeneous numeric array (all types) |
| Association | `0x41` | Key-value association |
| Rule | `0x2D` | Rule within an association |
| RuleDelayed | `0x3A` | Delayed rule within an association |

### Serialization per Type

- **Integers:** Token + little-endian signed bytes (1/2/4/8 bytes). Encoder picks smallest fit.
- **Real64:** Token + 8 bytes IEEE 754 double, little-endian.
- **Symbol/String/BinaryString/BigInteger/BigReal:** Token + varint byte-length + UTF-8 data.
- **Function:** Token + varint(num_parts) + head_expr + part_1...part_N. `num_parts` excludes the head.
- **Association:** Token + varint(num_rules) + rule_1...rule_N. No explicit head.
- **Rule/RuleDelayed:** Token + key_expr + value_expr. No length field (always 2 parts). Only valid inside associations.
- **PackedArray/NumericArray:** Token + value_type_byte + varint(rank) + varint(dim_1)...varint(dim_N) + raw binary data in row-major order.

### Array Value Types

| Value Type | Byte | Size | Packed? | Numeric? |
|-----------|------|------|---------|----------|
| Integer8 | `0x00` | 1B | Yes | Yes |
| Integer16 | `0x01` | 2B | Yes | Yes |
| Integer32 | `0x02` | 4B | Yes | Yes |
| Integer64 | `0x03` | 8B | Yes | Yes |
| UnsignedInteger8 | `0x10` | 1B | No | Yes |
| UnsignedInteger16 | `0x11` | 2B | No | Yes |
| UnsignedInteger32 | `0x12` | 4B | No | Yes |
| UnsignedInteger64 | `0x13` | 8B | No | Yes |
| Real32 | `0x22` | 4B | Yes | Yes |
| Real64 | `0x23` | 8B | Yes | Yes |
| ComplexReal32 | `0x33` | 8B | Yes | Yes |
| ComplexReal64 | `0x34` | 16B | Yes | Yes |

## Module Structure

```
ex_wxf/
├── lib/
│   ├── ex_wxf.ex                    # Public API: encode/decode/encode!/decode!
│   └── ex_wxf/
│       ├── expression.ex            # Struct definitions for all WXF types
│       ├── encoder.ex               # Elixir terms -> WXF binary
│       ├── decoder.ex               # WXF binary -> Elixir terms
│       ├── varint.ex                # LEB128 varint encode/decode
│       ├── tokens.ex                # WXF type token byte constants
│       └── array_types.ex           # PackedArray/NumericArray value type constants
├── test/
│   ├── ex_wxf_test.exs              # Integration tests (round-trip)
│   └── ex_wxf/
│       ├── encoder_test.exs
│       ├── decoder_test.exs
│       └── varint_test.exs
```

## Expression Types

```elixir
defmodule ExWxf.Expression.Symbol do
  defstruct [:name]
end

defmodule ExWxf.Expression.Function do
  defstruct [:head, parts: []]
end

defmodule ExWxf.Expression.BigInteger do
  defstruct [:value]
end

defmodule ExWxf.Expression.BigReal do
  defstruct [:value]
end

defmodule ExWxf.Expression.BinaryString do
  defstruct [:data]
end

defmodule ExWxf.Expression.PackedArray do
  defstruct [:type, :dimensions, :data]
end

defmodule ExWxf.Expression.NumericArray do
  defstruct [:type, :dimensions, :data]
end

defmodule ExWxf.Expression.Association do
  defstruct [rules: []]
end

defmodule ExWxf.Expression.Rule do
  defstruct [:key, :value, delayed: false]
end
```

## Auto-Mapping

### Encoding (Elixir -> WXF)

| Elixir Type | WXF Type |
|------------|----------|
| `integer` (fits 64-bit) | Integer8/16/32/64 (smallest fit) |
| `integer` (> 64-bit) | BigInteger |
| `float` | Real64 |
| `binary/string` | String |
| `true` / `false` | Symbol("True") / Symbol("False") |
| `nil` | Symbol("Null") |
| `list` | Function with head Symbol("List") |
| `map` | Association with Rules |
| `atom` | Symbol |
| Any `ExWxf.Expression.*` struct | Encoded directly |

### Decoding (WXF -> Elixir)

| WXF Type | Elixir Type |
|----------|------------|
| Integer8/16/32/64 | `integer` |
| Real64 | `float` |
| String | `binary` |
| Symbol("True"/"False"/"Null") | `true`/`false`/`nil` |
| Symbol(other) | `%ExWxf.Expression.Symbol{}` |
| Function with head List | `list` |
| Function with other head | `%ExWxf.Expression.Function{}` |
| Association | `map` |
| BigInteger | `integer` (Elixir handles arbitrary precision natively) |
| BigReal | `%ExWxf.Expression.BigReal{}` |
| PackedArray/NumericArray | `%ExWxf.Expression.PackedArray/NumericArray{}` |

## Public API

```elixir
defmodule ExWxf do
  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, ExWxf.EncodeError.t()}
  def encode(term, opts \\ [])

  @spec encode!(term(), keyword()) :: binary()
  def encode!(term, opts \\ [])

  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, ExWxf.DecodeError.t()}
  def decode(binary, opts \\ [])

  @spec decode!(binary(), keyword()) :: term()
  def decode!(binary, opts \\ [])
end
```

Options:
- `compress: true/false` (default false) — zlib compression on encode
- `raw: true/false` (default false) — skip auto-mapping, return/accept Expression structs

## Quality Stack

### Dependencies

```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
{:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
{:excoveralls, "~> 0.18", only: :test},
{:stream_data, "~> 1.0", only: :test}
```

### Mix Aliases

```elixir
precommit: [
  "compile --warnings-as-errors",
  "deps.unlock --unused",
  "format",
  "credo --strict",
  "test"
]
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
```

### Enforced Rules

- `@spec` on all public functions (Credo `Readability.Specs`)
- One `defmodule` per file (custom check EX9001)
- No `Process.sleep` in tests (custom check EX9002)
- Dialyzer flags: `:unmatched_returns`, `:error_handling`, `:underspecs`, `:extra_return`, `:missing_return`
- Coverage floor: 90%
- `--warnings-as-errors` on compile

### Skipped Rules (not applicable)

- EX9003 (LiveView-specific)
- EX9004 (HTTP client — no HTTP in this library)
- EX9005/EX9006 (no processes spawned)
- EX9007/EX9008 (no OTP callbacks)

## Testing Strategy

- **Unit tests per type:** Encode each WXF type, verify exact bytes. Decode known bytes, verify Elixir term.
- **Round-trip property tests (StreamData):** Encode then decode returns original for all auto-mapped types.
- **Reference test vectors:** Generate WXF from Wolfram (`BinarySerialize`) and verify decoder. Generate from ex_wxf and verify with Wolfram (`BinaryDeserialize`).
- **Edge cases:** Empty list, empty string, empty association, max/min int64, NaN, Infinity, deeply nested expressions, large packed arrays.

## Error Handling

- `ExWxf.EncodeError` — raised/returned when encoding fails (unsupported type, invalid struct)
- `ExWxf.DecodeError` — raised/returned when decoding fails (invalid bytes, truncated input, unknown token)
- Both include descriptive `:message` and `:term`/`:binary` fields for debugging

## Success Criteria

1. `ExWxf.encode!([1, "hello", %{"key" => 3.14}])` produces valid WXF binary
2. `ExWxf.decode!(binary)` round-trips all auto-mapped types
3. WXF binaries generated by Wolfram's `BinarySerialize` decode correctly
4. All WXF types from the spec are supported (including packed/numeric arrays)
5. `mix quality` passes with zero warnings
6. Coverage >= 90%
