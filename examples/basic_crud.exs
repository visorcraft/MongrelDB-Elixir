# Basic CRUD example for the MongrelDB Elixir client.
#
# Run with:
#   mix deps.get
#   mix run examples/basic_crud.exs
#
# Requires a running mongreldb-server on http://127.0.0.1:8453.
alias MongrelDB.QueryBuilder
alias MongrelDB.Transaction

db = MongrelDB.connect("http://127.0.0.1:8453")

{:ok, healthy?} = MongrelDB.health(db)
IO.puts("health: #{healthy?}")

# Drop a leftover table if present, then create a fresh one.
_ = MongrelDB.drop_table(db, "demo")

{:ok, _} =
  MongrelDB.create_table(db, "demo", [
    %{"id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false},
    %{"id" => 2, "name" => "label", "ty" => "varchar", "primary_key" => false, "nullable" => false},
    %{"id" => 3, "name" => "amount", "ty" => "float64", "primary_key" => false, "nullable" => false}
  ])

:ok = MongrelDB.put(db, "demo", %{1 => 1, 2 => "first", 3 => 10.0})
:ok = MongrelDB.put(db, "demo", %{1 => 2, 2 => "second", 3 => 20.0})
{:ok, count} = MongrelDB.count(db, "demo")
IO.puts("count: #{count}")

# Upsert: change the second row.
{:ok, _} = MongrelDB.upsert(db, "demo", %{1 => 2, 2 => "second", 3 => 42.0}, %{3 => 42.0})

# Read it back via the query builder.
{:ok, rows} =
  db
  |> MongrelDB.query("demo")
  |> QueryBuilder.where("pk", %{"value" => 2})
  |> QueryBuilder.execute()

IO.puts("row 2: #{length(rows)} rows returned")

# Batch delete in a transaction.
txn =
  MongrelDB.begin_transaction(db)
  |> Transaction.delete_by_pk("demo", 1)
  |> Transaction.delete_by_pk("demo", 2)

{:ok, _} = Transaction.commit(txn)

{:ok, final_count} = MongrelDB.count(db, "demo")
IO.puts("count after txn: #{final_count}")
