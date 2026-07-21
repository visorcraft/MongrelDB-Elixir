# Quickstart

This guide walks through installing the MongrelDB Elixir client, connecting to
a running `mongreldb-server`, and doing your first round-trip of CRUD and
query.

## Prerequisites

- Elixir 1.14 or newer (with a matching OTP).
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
  daemon. The simplest start is the prebuilt Linux binary:

  ```sh
  curl -L -o mongreldb-server \
    https://github.com/visorcraft/MongrelDB/releases/download/v0.63.0/mongreldb-server-linux-x64
  chmod +x mongreldb-server
  ./mongreldb-server ./data --port 8453
  ```

## Install

Add the dependency to `mix.exs`:

```elixir
defp deps do
  [
    {:mongreldb, "~> 0.63.0"}
  ]
end
```

Then fetch dependencies:

```sh
mix deps.get
```

The client has no runtime dependencies beyond Elixir and Erlang/OTP's `:inets`
(the `:httpc` module), which ships with OTP.

## Connect

```elixir
db = MongrelDB.connect("http://127.0.0.1:8453")
{:ok, true} = MongrelDB.health(db)
```

## Create a table and insert rows

```elixir
MongrelDB.create_table(db, "orders", [
  %{"id" => 1, "name" => "id",       "ty" => "int64",   "primary_key" => true,  "nullable" => false},
  %{"id" => 2, "name" => "customer", "ty" => "varchar", "primary_key" => false, "nullable" => false},
  %{"id" => 3, "name" => "amount",   "ty" => "float64", "primary_key" => false, "nullable" => false},
])

:ok = MongrelDB.put(db, "orders", %{1 => 1, 2 => "Alice", 3 => 99.50})
:ok = MongrelDB.put(db, "orders", %{1 => 2, 2 => "Bob",   3 => 150.00})

{:ok, 2} = MongrelDB.count(db, "orders")
```

### Schema constraints

Columns can carry `enum_variants`, `default_value`, and `default_expr` on the
descriptor itself. `default_value` stores a static JSON scalar; `default_expr`
is a separate key that selects a dynamic default such as `"now"` or `"uuid"`.
They are not aliases — literal `"now"` in `default_value` is a string, while
`default_expr: "now"` asks the engine to evaluate the current timestamp.

```elixir
[
  %{"id" => 1, "name" => "id",      "ty" => "int64",   "primary_key" => true,  "nullable" => false},
  %{"id" => 2, "name" => "status",  "ty" => "enum",    "enum_variants" => ["active", "paused", "archived"], "default_value" => "active"},
  %{"id" => 3, "name" => "count",   "ty" => "int64",   "default_value" => 7},
  %{"id" => 4, "name" => "live",    "ty" => "bool",    "default_value" => true},
  %{"id" => 5, "name" => "missing", "ty" => "varchar", "default_value" => nil},
  %{"id" => 6, "name" => "literal_now", "ty" => "varchar", "default_value" => "now"},
  %{"id" => 7, "name" => "created_at",  "ty" => "timestamp", "default_expr" => "now"}
]
```

Cells are passed as a map from column id to value.

## History retention

The daemon keeps a window of recent epochs so you can read historical snapshots
with SQL `AS OF EPOCH`. `history_retention_epochs` is the configured window
size; `earliest_retained_epoch` is the oldest epoch still available.

```elixir
# Set a wide window before doing time-travel reads.
{:ok, 1000} = MongrelDB.set_history_retention_epochs(db, 1000)

# Read the current settings.
{:ok, retention} = MongrelDB.history_retention_epochs(db)
{:ok, floor} = MongrelDB.earliest_retained_epoch(db)

# Query a past snapshot.
{:ok, rows} = MongrelDB.sql(db, "SELECT * FROM orders AS OF EPOCH #{floor}")
```

Lowering `history_retention_epochs` and writing more data advances
`earliest_retained_epoch`. Expanding the window later does not restore epochs
that have already been pruned.

## Run a query

```elixir
alias MongrelDB.QueryBuilder

{:ok, rows} =
  db
  |> MongrelDB.query("orders")
  |> QueryBuilder.where("pk", %{"value" => 1})
  |> QueryBuilder.execute()
```

## Next steps

- [Transactions](transactions.md) for atomic multi-op commits.
- [Queries](queries.md) for the native index condition API.
- [SQL](sql.md) for DataFusion-backed ad-hoc SQL.
- [Auth](auth.md) for Bearer and Basic authentication.
- [Errors](errors.md) for the exception hierarchy.
