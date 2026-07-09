# Queries

The Kit `/kit/query` endpoint pushes conditions down to the engine's
specialized indexes for sub-millisecond lookups. The Elixir
`MongrelDB.QueryBuilder` exposes those condition types through a fluent,
chainable API.

## Builder basics

```elixir
alias MongrelDB.QueryBuilder

{:ok, rows} =
  db
  |> MongrelDB.query("orders")
  |> QueryBuilder.where("bitmap_eq", %{"column" => 2, "value" => "Alice"})
  |> QueryBuilder.projection([1, 2])
  |> QueryBuilder.limit(100)
  |> QueryBuilder.execute()
```

`where/3` may be called multiple times; conditions are AND-ed together.
`projection/2` restricts the returned columns. `limit/2` caps the row count.

## Friendly aliases

The builder accepts readable parameter names and translates them to the
server's exact on-wire keys before sending:

| Alias | Wire key |
|---|---|
| `column` | `column_id` |
| `min` | `lo` |
| `max` | `hi` |
| `min_inclusive` | `lo_inclusive` |
| `max_inclusive` | `hi_inclusive` |

For full-text conditions (`fm_contains`, `fm_contains_all`), the alias `value`
maps to the wire key `pattern`. The server's canonical keys are also accepted
directly, so you can pass the exact wire shape when that is clearer.

## Condition types

| Type | Use | Example parameters |
|---|---|---|
| `pk` | Exact primary key match | `%{"value" => 1}` |
| `bitmap_eq` | Equality on a bitmap-indexed column | `%{"column" => 2, "value" => "Alice"}` |
| `bitmap_in` | IN predicate on a bitmap column | `%{"column" => 2, "values" => ["Alice","Bob"]}` |
| `range` | Integer range predicate | `%{"column" => 3, "min" => 10, "max" => 100}` |
| `range_f64` | Float range predicate | `%{"column" => 3, "min" => 10.0, "max" => 100.0}` |
| `is_null` | Null check | `%{"column" => 2}` |
| `is_not_null` | Not-null check | `%{"column" => 2}` |
| `fm_contains` | Full-text substring (FM-index) | `%{"column" => 2, "pattern" => "database"}` |
| `fm_contains_all` | All patterns must match | `%{"column" => 2, "patterns" => ["database","index"]}` |
| `ann` | Dense vector similarity (HNSW) | `%{"column" => 2, "query" => [0.1,0.2,0.3], "k" => 10}` |
| `sparse_match` | Sparse vector match | `%{"column" => 2, "query" => %{...}}` |
| `min_hash_similar` | MinHash similarity search | `%{"column" => 2, "query" => [...]}` |

## Truncation check

After `execute/1`, read `truncated?/1` to find out whether the result set was
capped by the limit:

```elixir
q =
  db
  |> MongrelDB.query("orders")
  |> QueryBuilder.where("range", %{"column" => 3, "min" => 0})
  |> QueryBuilder.limit(100)

{:ok, rows} = QueryBuilder.execute(q)

if QueryBuilder.truncated?(q) do
  # result set hit the limit; more matches exist on the server.
end
```
