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
    https://github.com/visorcraft/MongrelDB/releases/download/v0.46.2/mongreldb-server-linux-x64
  chmod +x mongreldb-server
  ./mongreldb-server ./data --port 8453
  ```

## Install

Add the dependency to `mix.exs`:

```elixir
defp deps do
  [
    {:mongreldb, "~> 0.1.0"}
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

Columns can carry `enum_variants` and a `default_value` on the descriptor
itself; the server also accepts `default_expr` as an alias for `default_value`.
The client forwards the map keys you supply verbatim.

```elixir
%{
  "id" => 4,
  "name" => "status",
  "ty" => "enum",
  "enum_variants" => ["active", "paused", "archived"],
  "default_value" => "active"
}
```

Cells are passed as a map from column id to value.

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
