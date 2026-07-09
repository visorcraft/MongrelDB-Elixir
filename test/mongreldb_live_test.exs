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
    assert :ok = MongrelDB.put(db(), table, %{1 => 1, 2 => "alpha", 3 => 10.0})
    assert :ok = MongrelDB.put(db(), table, %{1 => 2, 2 => "beta", 3 => 25.0})

    assert {:ok, 2} = MongrelDB.count(db(), table)

    assert {:ok, rows} =
             MongrelDB.query(db(), table)
             |> QueryBuilder.where("pk", %{"value" => 2})
             |> QueryBuilder.execute()

    assert length(rows) >= 1
  end

  @tag :skip_without_server
  test "upsert updates an existing row on PK conflict" do
    skip_unless_reachable!()
    table = unique_name("ex_upsert")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())
    assert :ok = MongrelDB.put(db(), table, %{1 => 1, 2 => "alpha", 3 => 10.0})
    assert {:ok, _} = MongrelDB.upsert(db(), table, %{1 => 1, 2 => "alpha", 3 => 99.0}, %{3 => 99.0})

    assert {:ok, 1} = MongrelDB.count(db(), table)
  end

  @tag :skip_without_server
  test "transaction commits multiple ops atomically" do
    skip_unless_reachable!()
    table = unique_name("ex_txn")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())

    txn =
      Transaction.put(MongrelDB.begin_transaction(db()), table, %{1 => 10, 2 => "dave", 3 => 50.0})
      |> Transaction.put(table, %{1 => 11, 2 => "eve", 3 => 75.0})
      |> Transaction.delete_by_pk(table, 10)

    assert {:ok, _} = Transaction.commit(txn)
    assert Transaction.op_count(txn) == 3
    assert {:ok, 1} = MongrelDB.count(db(), table)
  end

  @tag :skip_without_server
  test "SQL round-trips through /sql" do
    skip_unless_reachable!()
    table = unique_name("ex_sql")

    assert {:ok, _} = MongrelDB.create_table(db(), table, columns())
    assert :ok = MongrelDB.put(db(), table, %{1 => 1, 2 => "alpha", 3 => 1.0})
    assert {:ok, _} = MongrelDB.sql(db(), "INSERT INTO #{table} (id, label, amount) VALUES (2, 'beta', 2.0)")

    assert {:ok, 2} = MongrelDB.count(db(), table)
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

  defp columns do
    [
      %{"id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false},
      %{"id" => 2, "name" => "label", "ty" => "varchar", "primary_key" => false, "nullable" => false},
      %{"id" => 3, "name" => "amount", "ty" => "float64", "primary_key" => false, "nullable" => false}
    ]
  end

  defp skip_unless_reachable! do
    unless server_reachable?(), do: ExUnit.skip("MONGRELDB_URL not reachable")
  end
end
