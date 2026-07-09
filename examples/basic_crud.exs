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

# Per-run unique suffix so concurrent/CI runs never collide on a table name.
table = "ex_demo_#{System.system_time(:nanosecond)}"

try do
  # Drop a leftover table if present, then create a fresh one.
  _ = MongrelDB.drop_table(db, table)

  {:ok, _} =
    MongrelDB.create_table(db, table, [
      %{"id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false},
      %{"id" => 2, "name" => "label", "ty" => "varchar", "primary_key" => false, "nullable" => false},
      %{"id" => 3, "name" => "amount", "ty" => "float64", "primary_key" => false, "nullable" => false}
    ])

  # MongrelDB.put/4 returns {:ok, map()}, not :ok.
  {:ok, _} = MongrelDB.put(db, table, %{1 => 1, 2 => "first", 3 => 10.0})
  {:ok, _} = MongrelDB.put(db, table, %{1 => 2, 2 => "second", 3 => 20.0})
  {:ok, count} = MongrelDB.count(db, table)
  IO.puts("count: #{count}")

  # Upsert: change the second row.
  {:ok, _} = MongrelDB.upsert(db, table, %{1 => 2, 2 => "second", 3 => 42.0}, %{3 => 42.0})

  # Read it back via the query builder.
  {:ok, rows} =
    db
    |> MongrelDB.query(table)
    |> QueryBuilder.where("pk", %{"value" => 2})
    |> QueryBuilder.execute()

  IO.puts("row 2: #{length(rows)} rows returned")

  # Batch delete in a transaction. Transaction.commit/2 returns
  # {:ok, results, txn}, not {:ok, _}.
  txn =
    MongrelDB.begin_transaction(db)
    |> Transaction.delete_by_pk(table, 1)
    |> Transaction.delete_by_pk(table, 2)

  {:ok, _, _} = Transaction.commit(txn)

  {:ok, final_count} = MongrelDB.count(db, table)
  IO.puts("count after txn: #{final_count}")
after
  # Guaranteed cleanup: drop the table even if the body raised, so CI runs
  # never leave an orphan table behind.
  _ = MongrelDB.drop_table(db, table)
  IO.puts("dropped: #{table}")
end
