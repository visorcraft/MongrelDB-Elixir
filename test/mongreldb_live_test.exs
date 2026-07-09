defmodule MongrelDB.LiveTest do
  use ExUnit.Case, async: false

  alias MongrelDB.QueryBuilder
  alias MongrelDB.Transaction

  @server_url System.get_env("MONGRELDB_URL", "http://127.0.0.1:8453")

  # The live tests need a running mongreldb-server. Skip the whole module if it
  # is not reachable.
  setup_all do
    unless server_reachable?() do
      IO.puts("\nSKIP live tests: MONGRELDB_URL not reachable at #{@server_url}")
    end

    {:ok, []}
  end

  defp server_reachable? do
    db = MongrelDB.connect(@server_url)

    case MongrelDB.health(db) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp db, do: MongrelDB.connect(@server_url)

  defp unique_name(prefix) do
    "#{prefix}_#{System.system_time(:nanosecond)}"
  end

  @tag :skip_without_server
  test "health reports true" do
    skip_unless_reachable!()
    assert {:ok, true} = MongrelDB.health(db())
  end

  @tag :skip_without_server
  test "create_table, put, count, and query round-trip" do
    skip_unless_reachable!()
    table = unique_name("ex_items")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 1, 2 => "alpha", 3 => 10.0})
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 2, 2 => "beta", 3 => 25.0})

    assert {:ok, 2} = MongrelDB.count(db(), table)

    assert {:ok, rows} =
             MongrelDB.query(db(), table)
             |> QueryBuilder.where("pk", %{"value" => 2})
             |> QueryBuilder.execute()

    assert rows != []
    # The returned row must carry primary key 2. Confirm via SQL JSON mode,
    # where rows are keyed by column name.
    assert {:ok, pk_rows} = MongrelDB.sql(db(), "SELECT id FROM #{table} WHERE id = 2")
    assert pk_rows != []
    assert hd(pk_rows)["id"] == 2
  end

  @tag :skip_without_server
  test "upsert updates an existing row on PK conflict" do
    skip_unless_reachable!()
    table = unique_name("ex_upsert")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 1, 2 => "alpha", 3 => 10.0})

    assert {:ok, _} =
             MongrelDB.upsert(db(), table, %{1 => 1, 2 => "alpha", 3 => 99.0}, %{3 => 99.0})

    assert {:ok, 1} = MongrelDB.count(db(), table)
    # Query the row back and verify the upserted value landed. SQL JSON mode
    # returns rows keyed by column name.
    assert {:ok, rows} = MongrelDB.sql(db(), "SELECT amount FROM #{table} WHERE id = 1")
    assert rows != []
    assert hd(rows)["amount"] == 99.0
  end

  @tag :skip_without_server
  test "transaction commits multiple ops atomically" do
    skip_unless_reachable!()
    table = unique_name("ex_txn")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())

    # Seed a row outside the batch so the in-batch delete_by_pk can see it.
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 9, 2 => "seed", 3 => 1.0})

    txn =
      Transaction.put(MongrelDB.begin_transaction(db()), table, %{1 => 10, 2 => "dave", 3 => 50.0})
      |> Transaction.put(table, %{1 => 11, 2 => "eve", 3 => 75.0})
      |> Transaction.delete_by_pk(table, 9)

    assert {:ok, _, _} = Transaction.commit(txn)
    assert Transaction.op_count(txn) == 3
    # Seed (9) deleted, 10 and 11 inserted -> 2 rows.
    assert {:ok, 2} = MongrelDB.count(db(), table)
  end

  @tag :skip_without_server
  test "SQL round-trips through /sql" do
    skip_unless_reachable!()
    table = unique_name("ex_sql")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 1, 2 => "alpha", 3 => 1.0})

    assert {:ok, _} =
             MongrelDB.sql(
               db(),
               "INSERT INTO #{table} (id, label, amount) VALUES (2, 'beta', 2.0)"
             )

    assert {:ok, 2} = MongrelDB.count(db(), table)
    # JSON mode makes SELECT return rows as JSON objects (column names as
    # keys). Verify both rows come back with the right primary keys.
    assert {:ok, selected} = MongrelDB.sql(db(), "SELECT id FROM #{table} ORDER BY id")
    assert length(selected) == 2
    assert Enum.map(selected, & &1["id"]) == [1, 2]
  end

  @tag :skip_without_server
  test "schema lists the created table" do
    skip_unless_reachable!()
    table = unique_name("ex_schema")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())
    assert {:ok, names} = MongrelDB.table_names(db())
    assert table in names
    assert {:ok, desc} = MongrelDB.schema_for(db(), table)
    assert map_size(desc) > 0
  end

  @tag :skip_without_server
  test "range query returns only rows within the bounds" do
    skip_unless_reachable!()
    table = unique_name("ex_range")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 1, 2 => "a", 3 => 50.0})
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 2, 2 => "b", 3 => 75.0})
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 3, 2 => "c", 3 => 90.0})
    assert {:ok, _} = MongrelDB.put(db(), table, %{1 => 4, 2 => "d", 3 => 100.0})

    # Only scores >= 80 should come back (90 and 100) - assert the count.
    # Use range_f64 because column 3 is float64 (plain range expects i64).
    assert {:ok, rows} =
             MongrelDB.query(db(), table)
             |> QueryBuilder.where("range_f64", %{
               "column" => 3,
               "min" => 80.0,
               "max" => 200.0,
               "min_inclusive" => true,
               "max_inclusive" => true
             })
             |> QueryBuilder.execute()

    assert length(rows) == 2
    # Only rows with id 3 (amount 90) and 4 (amount 100) qualify. Confirm
    # their exact PK values via SQL JSON mode (rows keyed by column name).
    assert {:ok, selected} =
             MongrelDB.sql(db(), "SELECT id FROM #{table} WHERE amount >= 80.0 ORDER BY id")

    assert Enum.map(selected, & &1["id"]) == [3, 4]
  end

  @tag :skip_without_server
  test "schema_for on a nonexistent table returns a NotFoundException" do
    skip_unless_reachable!()

    assert {:error, %MongrelDB.NotFoundException{}} =
             MongrelDB.schema_for(db(), "nonexistent_table_xyz")
  end

  @tag :skip_without_server
  test "idempotent commit does not duplicate the row" do
    skip_unless_reachable!()
    table = unique_name("ex_idem")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())

    # Idempotency key must be unique per run so a stale key from an earlier
    # run can't be replayed against this table.
    key = "order-100-create-#{System.system_time(:nanosecond)}"

    # First idempotent commit inserts the row.
    txn =
      MongrelDB.begin_transaction(db())
      |> Transaction.put(table, %{1 => 100, 2 => "order", 3 => 1.0})

    assert {:ok, _, _} = Transaction.commit(txn, idempotency_key: key)
    assert {:ok, 1} = MongrelDB.count(db(), table)

    # A second, identical commit with the SAME key must not duplicate it.
    txn2 =
      MongrelDB.begin_transaction(db())
      |> Transaction.put(table, %{1 => 100, 2 => "order", 3 => 1.0})

    # The daemon deduplicates; tolerate either a clean dedupe reply or an error.
    _ = Transaction.commit(txn2, idempotency_key: key)
    assert {:ok, 1} = MongrelDB.count(db(), table)
  end

  defp columns do
    [
      %{"id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false},
      %{
        "id" => 2,
        "name" => "label",
        "ty" => "varchar",
        "primary_key" => false,
        "nullable" => false
      },
      %{
        "id" => 3,
        "name" => "amount",
        "ty" => "float64",
        "primary_key" => false,
        "nullable" => false
      }
    ]
  end

  defp skip_unless_reachable! do
    # The live suite is excluded by default (test_helper.exs). CI enables it
    # only after booting mongreldb-server. If we somehow run without a server,
    # fail loudly so the run surfaces it instead of looking like a skip.
    unless server_reachable?() do
      flunk("MONGRELDB_URL not reachable at #{@server_url}")
    end
  end
end
