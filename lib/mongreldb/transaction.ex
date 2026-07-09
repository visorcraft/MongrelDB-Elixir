defmodule MongrelDB.Transaction do
  @moduledoc """
  Batch transaction builder for atomic multi-operation commits.

  Operations are staged in a buffer and flushed in a single `/kit/txn` request
  on `commit/2`. The engine enforces unique, foreign key, and check
  constraints atomically, so either every staged op lands or none.

  ## Example

      txn = MongrelDB.begin_transaction(db)
      Transaction.put(txn, "orders", %{1 => 10, 2 => "Dave", 3 => 50.0})
      |> Transaction.put("orders", %{1 => 11, 2 => "Eve", 3 => 75.0})
      |> Transaction.delete_by_pk("orders", 99)
      {:ok, results} = Transaction.commit(txn) # atomic
  """

  @type t :: %__MODULE__{
          db: MongrelDB.t(),
          ops: [map()],
          committed: boolean()
        }

  defstruct [:db, ops: [], committed: false]

  @doc "Stage an insert."
  @spec put(t(), String.t(), map()) :: t()
  def put(%__MODULE__{} = txn, table, cells) do
    op = %{"put" => %{"table" => table, "cells" => cells_to_flat(cells)}}
    %{txn | ops: txn.ops ++ [op]}
  end

  @doc "Stage an upsert (insert or update on PK conflict)."
  @spec upsert(t(), String.t(), map(), map() | nil) :: t()
  def upsert(%__MODULE__{} = txn, table, cells, update_cells \\ nil) do
    inner = %{"table" => table, "cells" => cells_to_flat(cells)}

    inner =
      if update_cells,
        do: Map.put(inner, "update_cells", cells_to_flat(update_cells)),
        else: inner

    op = %{"upsert" => inner}
    %{txn | ops: txn.ops ++ [op]}
  end

  @doc "Stage a delete by internal row id."
  @spec delete(t(), String.t(), integer()) :: t()
  def delete(%__MODULE__{} = txn, table, row_id) do
    op = %{"delete" => %{"table" => table, "row_id" => row_id}}
    %{txn | ops: txn.ops ++ [op]}
  end

  @doc "Stage a delete by primary key value."
  @spec delete_by_pk(t(), String.t(), term()) :: t()
  def delete_by_pk(%__MODULE__{} = txn, table, pk) do
    op = %{"delete_by_pk" => %{"table" => table, "pk" => pk}}
    %{txn | ops: txn.ops ++ [op]}
  end

  @doc "Number of staged operations."
  @spec op_count(t()) :: non_neg_integer()
  def op_count(%__MODULE__{ops: ops}), do: Kernel.length(ops)

  @doc """
  Commit all staged operations atomically.

  Returns `{:ok, results}` where `results` is a list of per-op result maps.
  On a constraint violation the daemon rejects the whole batch and returns
  `{:error, %MongrelDB.ConstraintException{}}`.
  """
  @spec commit(t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def commit(%__MODULE__{committed: true}) do
    {:error, %MongrelDB.QueryException{message: "Transaction already committed"}}
  end

  def commit(%__MODULE__{ops: [], committed: false}) do
    {:ok, []}
  end

  def commit(%__MODULE__{db: db, ops: ops, committed: false}, opts \\ []) do
    payload = %{"ops" => ops}
    payload = maybe_add_idempotency(payload, Keyword.get(opts, :idempotency_key))

    with {:ok, resp} <- MongrelDB.post(db, "/kit/txn", payload) do
      results =
        case MongrelDB.JSON.decode(resp.body) do
          {:ok, data} when is_map(data) -> Map.get(data, "results", [])
          _ -> []
        end

      {:ok, results}
    end
  end

  @doc "Discard all staged operations."
  @spec rollback(t()) :: t()
  def rollback(%__MODULE__{committed: true}) do
    raise ArgumentError, "Cannot rollback a committed transaction"
  end

  def rollback(%__MODULE__{} = txn), do: %{txn | ops: []}

  # Flatten %{col_id => value} into [col_id, value, ...].
  defp cells_to_flat(cells) do
    cells
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.flat_map(fn {k, v} -> [k, v] end)
  end

  defp maybe_add_idempotency(payload, nil), do: payload
  defp maybe_add_idempotency(payload, key), do: Map.put(payload, "idempotency_key", key)
end
