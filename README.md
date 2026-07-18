<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Elixir Client</h1>

<p align="center">
  <b>Pure Elixir client for MongrelDB, embedded and server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
</p>

<p align="center">
  <a href="https://hex.pm/packages/mongreldb"><img src="https://img.shields.io/hexpm/v/mongreldb.svg" alt="Hex" /></a>
  <a href="https://hexdocs.pm/mongreldb"><img src="https://img.shields.io/badge/docs-hexdocs-4B275F.svg" alt="HexDocs" /></a>
  <a href="https://elixir-lang.org/"><img src="https://img.shields.io/badge/Elixir-%3E%3D1.14-4B275F.svg" alt="Elixir" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Elixir client | `mongreldb` | `mix deps.get` with `:mongreldb` in `deps/0` |

```elixir
def deps do
  [
    {:mongreldb, "~> 0.60.2"}
  ]
end
```

History retention: `MongrelDB.history_retention_epochs/1`,
`MongrelDB.earliest_retained_epoch/1`, `MongrelDB.set_history_retention_epochs/2`,
and the raw `MongrelDB.history_retention/1`.

## Requirements

- **Elixir 1.14 or newer** (with a matching OTP 25+)
- No external runtime dependencies; built on Erlang/OTP's `:inets` (`:httpc`) and `Base`
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, with idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match.
- **Idempotent batch transactions**, all operations staged in a buffer and committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, multi-statement execution, and the `mongreldb_fts_rank` relevance-scoring UDF.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **Maintenance**: compaction (all tables or per-table).
- **`:httpc` transport** with no external runtime dependencies beyond OTP, and a vendored JSON encoder so there is no JSON library to install.
- **Typed exception hierarchy** using `defexception`: `AuthException` (401/403), `NotFoundException` (404), `ConstraintException` (409, with error code and op index), `ConnectionException` (network), and `QueryException` (everything else).
- **Robust JSON handling**: NaN and Infinity raise a clear `QueryException` instead of corrupting data; malformed UTF-8 is passed through so the daemon can substitute it.

## Examples

Runnable, commented examples live in [`examples/`](examples):

- [Basic CRUD](examples/basic_crud.exs), connect, create a table, insert, query, count.

## Quick Example

```elixir
# Connect to a running mongreldb-server daemon.
db = MongrelDB.connect("http://127.0.0.1:8453")

# Create a table.
MongrelDB.create_table(db, "orders", [
  %{"id" => 1, "name" => "id",       "ty" => "int64",   "primary_key" => true,  "nullable" => false},
  %{"id" => 2, "name" => "customer", "ty" => "varchar", "primary_key" => false, "nullable" => false},
  %{"id" => 3, "name" => "amount",   "ty" => "float64", "primary_key" => false, "nullable" => false},
])

# Insert rows. Cells map column id to value.
MongrelDB.put(db, "orders", %{1 => 1, 2 => "Alice", 3 => 99.50})
MongrelDB.put(db, "orders", %{1 => 2, 2 => "Bob",   3 => 150.00})

# Upsert (insert or update on PK conflict).
MongrelDB.upsert(db, "orders", %{1 => 1, 2 => "Alice", 3 => 120.00}, %{3 => 120.00})

# Query with a native index condition (learned-range index).
alias MongrelDB.QueryBuilder

{:ok, rows} =
  db
  |> MongrelDB.query("orders")
  |> QueryBuilder.where("range", %{"column" => 3, "min" => 100.0})
  |> QueryBuilder.projection([1, 2])
  |> QueryBuilder.limit(100)
  |> QueryBuilder.execute()

{:ok, 2} = MongrelDB.count(db, "orders")

# Run SQL.
{:ok, _} = MongrelDB.sql(db, "UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## Auth

```elixir
# Bearer token (--auth-token mode).
db = MongrelDB.connect("http://127.0.0.1:8453", token: "my-secret-token")

# HTTP Basic (--auth-users mode).
db = MongrelDB.connect("http://127.0.0.1:8453", username: "admin", password: "s3cret")
```

## Transactions

Operations are staged in a buffer and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```elixir
alias MongrelDB.Transaction

txn =
  Transaction.put(MongrelDB.begin_transaction(db), "orders", %{1 => 10, 2 => "Dave", 3 => 50.0})
  |> Transaction.put("orders", %{1 => 11, 2 => "Eve", 3 => 75.0})
  |> Transaction.delete_by_pk("orders", 2)

case Transaction.commit(txn) do # atomic, all or nothing
  {:ok, results} ->
    IO.puts("Staged #{Transaction.op_count(txn)} operations")

  {:error, %MongrelDB.ConstraintException{error_code: code} = e} ->
    IO.puts("Constraint violated: #{code} - #{e.message}")
end

# Idempotent commit, safe to retry; daemon returns the original response.
txn2 =
  MongrelDB.begin_transaction(db)
  |> Transaction.put("orders", %{1 => 20, 2 => "Frank", 3 => 100.00})

{:ok, _} = Transaction.commit(txn2, idempotency_key: "order-20-create")
```

## Query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(to `column_id`), `min`/`max` (to `lo`/`hi`). The canonical keys are also
accepted directly.

```elixir
alias MongrelDB.QueryBuilder

# Bitmap equality (low-cardinality columns).
{:ok, _} =
  db |> MongrelDB.query("orders")
  |> QueryBuilder.where("bitmap_eq", %{"column" => 2, "value" => "Alice"})
  |> QueryBuilder.execute()

# Range query (learned-range index).
{:ok, _} =
  db |> MongrelDB.query("orders")
  |> QueryBuilder.where("range", %{"column" => 3, "min" => 50.0, "max" => 150.0})
  |> QueryBuilder.limit(100)
  |> QueryBuilder.execute()

# Full-text search (FM-index).
{:ok, _} =
  db |> MongrelDB.query("documents")
  |> QueryBuilder.where("fm_contains", %{"column" => 2, "pattern" => "database performance"})
  |> QueryBuilder.limit(10)
  |> QueryBuilder.execute()

# Vector similarity search (HNSW).
{:ok, _} =
  db |> MongrelDB.query("embeddings")
  |> QueryBuilder.where("ann", %{"column" => 2, "query" => [0.1, 0.2, 0.3], "k" => 10})
  |> QueryBuilder.execute()

# Check whether a result was capped by the limit.
q =
  db |> MongrelDB.query("orders")
  |> QueryBuilder.where("range", %{"column" => 3, "min" => 0})
  |> QueryBuilder.limit(100)

{:ok, rows} = QueryBuilder.execute(q)

if QueryBuilder.truncated?(q) do
  # result set hit the limit; more matches exist on the server.
end
```

## SQL

```elixir
{:ok, _} = MongrelDB.sql(db, "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
{:ok, _} = MongrelDB.sql(db, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

# Recursive CTEs and window functions.
{:ok, _} = MongrelDB.sql(db, "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
{:ok, _} = MongrelDB.sql(db, "SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders")
```

## Schema constraints

Columns can carry enum variants and a default value on the descriptor itself.
`default_value` preserves a static JSON scalar (string, number, boolean, or
explicit `null`); `default_expr` selects the dynamic `"now"` or `"uuid"`
default. Literal `"now"` in `default_value` is stored as a string, while
`default_expr: "now"` tells the engine to evaluate the current timestamp. The
Elixir client forwards the map keys you supply verbatim.

```elixir
MongrelDB.create_table(db, "tasks", [
  %{"id" => 1, "name" => "id",     "ty" => "int64", "primary_key" => true,  "nullable" => false},
  %{
    "id" => 2,
    "name" => "status",
    "ty" => "enum",
    "enum_variants" => ["active", "paused", "archived"],
    "default_value" => "active"
  },
  %{"id" => 3, "name" => "count",  "ty" => "int64",  "default_value" => 7},
  %{"id" => 4, "name" => "live",   "ty" => "bool",   "default_value" => true},
  %{"id" => 5, "name" => "missing","ty" => "varchar","default_value" => nil},
  %{"id" => 6, "name" => "literal_now","ty" => "varchar","default_value" => "now"},
  %{"id" => 7, "name" => "created_at","ty" => "timestamp","default_expr" => "now"}
])
```

Table checks use `create_table/4`; the fourth argument is the native
`constraints` map and is enforced by the engine at commit time.

```elixir
checks = %{"checks" => [%{"id" => 1, "name" => "amount_nonneg",
  "expr" => %{"Ge" => [%{"Col" => 3}, %{"Lit" => %{"Float64" => 0.0}}]}}]}
MongrelDB.create_table(db, "orders", columns, checks)
```

## User and role management

User and role administration is done through SQL against the `/sql` endpoint.
Quote identifiers and escape literals so caller-supplied names are safe to
interpolate.

```elixir
MongrelDB.sql(db, "CREATE USER \"admin\" WITH PASSWORD 's3cret-pw'")
MongrelDB.sql(db, "ALTER USER \"admin\" ADMIN")

MongrelDB.sql(db, "CREATE ROLE \"analyst\"")
MongrelDB.sql(db, "GRANT SELECT ON orders TO \"analyst\"")
MongrelDB.sql(db, "GRANT \"analyst\" TO \"alice\"")
```

## Error handling

Every function that can fail returns `{:ok, result}` or `{:error, exception}`,
where the exception is a typed struct.

```elixir
case MongrelDB.put(db, "orders", %{1 => 1}) do # duplicate PK
  {:ok, _} ->
    :ok

  {:error, %MongrelDB.ConstraintException{error_code: code}} ->
    IO.puts("Constraint: #{code}") # UNIQUE_VIOLATION

  {:error, %MongrelDB.AuthException{message: message}} ->
    IO.puts("Not authorized: #{message}")

  {:error, %MongrelDB.NotFoundException{message: message}} ->
    IO.puts("Not found: #{message}")

  {:error, %MongrelDB.ConnectionException{message: message}} ->
    IO.puts("Can't reach daemon: #{message}")

  {:error, other} ->
    IO.puts("Error: #{inspect(other)}")
end
```

## API reference

### `MongrelDB` module

| Function | Description |
|---|---|
| `MongrelDB.connect(url, opts)` | Connect to a daemon |
| `MongrelDB.health(db)` | Check daemon health |
| `MongrelDB.table_names(db)` | List table names |
| `MongrelDB.create_table(db, name, columns)` | Create a table, returns table id; column maps may include enum/default fields |
| `MongrelDB.create_table(db, name, columns, constraints)` | Create a table with native `constraints` JSON (including CHECKs) |
| `MongrelDB.drop_table(db, name)` | Drop a table |
| `MongrelDB.count(db, table)` | Row count |
| `MongrelDB.put(db, table, cells, opts)` | Insert a row |
| `MongrelDB.upsert(db, table, cells, update_cells, opts)` | Upsert a row |
| `MongrelDB.delete(db, table, row_id)` | Delete by row ID |
| `MongrelDB.delete_by_pk(db, table, pk)` | Delete by primary key |
| `MongrelDB.query(db, table)` | Start a native query |
| `MongrelDB.sql(db, statement)` | Execute SQL |
| `MongrelDB.schema(db)` | Full schema catalog |
| `MongrelDB.schema_for(db, table)` | Single table schema |
| `MongrelDB.compact(db)` | Compact all tables |
| `MongrelDB.history_retention_epochs(db)` | Current history retention window in epochs |
| `MongrelDB.earliest_retained_epoch(db)` | Earliest readable epoch for `AS OF EPOCH` |
| `MongrelDB.set_history_retention_epochs(db, epochs)` | Set the history retention window |
| `MongrelDB.history_retention(db)` | Raw `/history/retention` response map |
| `MongrelDB.begin_transaction(db)` | Start a batch |

### `QueryBuilder` module

| Function | Description |
|---|---|
| `QueryBuilder.where(query, type, params)` | Add a native condition |
| `QueryBuilder.projection(query, column_ids)` | Set column projection |
| `QueryBuilder.limit(query, limit)` | Set row limit |
| `QueryBuilder.offset(query, offset)` | Skip matching rows before the limit |
| `QueryBuilder.build(query)` | Build the request payload |
| `QueryBuilder.execute(query)` | Run the query |
| `QueryBuilder.truncated?(query)` | Whether the last result was capped |

### `Transaction` module

| Function | Description |
|---|---|
| `Transaction.put(txn, table, cells)` | Stage an insert |
| `Transaction.upsert(txn, table, cells, update_cells)` | Stage an upsert |
| `Transaction.delete(txn, table, row_id)` | Stage a delete |
| `Transaction.delete_by_pk(txn, table, pk)` | Stage a delete by PK |
| `Transaction.commit(txn, opts)` | Commit atomically |
| `Transaction.rollback(txn)` | Discard all operations |
| `Transaction.op_count(txn)` | Number of staged operations |

## Building and testing

The test suite uses ExUnit and is split into a pure unit suite (no daemon
needed) and a live integration suite.

```sh
mix deps.get
mix test            # runs the unit suite (live tests excluded)
```

For the live round-trip suite, start a daemon and enable the live tag:

```sh
MONGRELDB_URL=http://127.0.0.1:8453 mix test --include skip_without_server
```

Static analysis and formatting:

```sh
mix compile --warnings-as-errors
mix credo --strict
mix format --check-formatted
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change, the suite must stay green.
3. Keep Elixir 1.14 as the minimum supported version.
4. Match the existing style: `mix format` formatting, `snake_case`,
   `with` over nested `case`, and `mix credo --strict` clean.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
