# Transactions

The MongrelDB daemon commits batched operations atomically. The Elixir client
mirrors that with the `MongrelDB.Transaction` module: each `put`, `upsert`,
`delete`, and `delete_by_pk` stages an operation into a buffer, and `commit/2`
flushes the whole batch in a single `/kit/txn` request. Unique, foreign key,
and check constraints are enforced by the engine at commit time, so either
every operation lands or none.

## Basic commit

```elixir
alias MongrelDB.Transaction

txn =
  Transaction.put(MongrelDB.begin_transaction(db), "orders", %{1 => 10, 2 => "Dave", 3 => 50.0})
  |> Transaction.put("orders", %{1 => 11, 2 => "Eve", 3 => 75.0})
  |> Transaction.delete_by_pk("orders", 99)

{:ok, results} = Transaction.commit(txn) # atomic: all or nothing
```

`commit/2` returns `{:ok, results}` where `results` is a list of per-operation
result maps. Each entry reflects the `action` the engine took (`inserted`,
`updated`, `unchanged`, etc.).

## Rollback

Discard everything that has not been committed:

```elixir
txn =
  MongrelDB.begin_transaction(db)
  |> Transaction.put("orders", %{1 => 99, 2 => "temp", 3 => 0.0})

txn = Transaction.rollback(txn) # nothing is sent to the daemon
```

Calling `commit/2` twice, or `rollback/1` after `commit/2`, raises an error.

## Idempotent commits

Pass an idempotency key to make a commit safe to retry. If the daemon sees the
same key again (even after a crash), it returns the original response instead
of replaying the work:

```elixir
{:ok, results} = Transaction.commit(txn, idempotency_key: "order-20-create")
```

Keys are opaque, caller-supplied strings. The client does not derive or store
them.

## Constraint handling

If a staged operation violates a constraint, the engine rejects the whole batch
and `commit/2` returns `{:error, %MongrelDB.ConstraintException{}}` with the
server's `error_code` (for example, `UNIQUE_VIOLATION`) and, when reported, the
`op_index` of the offending operation:

```elixir
case Transaction.commit(txn) do
  {:ok, results} -> :ok
  {:error, %MongrelDB.ConstraintException{error_code: code, op_index: idx}} ->
    IO.puts("Constraint violated: #{code} (op #{idx})")
end
```

## Supported operations

| Function | Description |
|---|---|
| `Transaction.put(txn, table, cells)` | Stage an insert |
| `Transaction.upsert(txn, table, cells, update_cells)` | Stage an insert-or-update on PK conflict |
| `Transaction.delete(txn, table, row_id)` | Stage a delete by internal row id |
| `Transaction.delete_by_pk(txn, table, pk)` | Stage a delete by primary key value |
| `Transaction.commit(txn, opts)` | Flush the batch atomically |
| `Transaction.rollback(txn)` | Discard the staged batch |
| `Transaction.op_count(txn)` | Number of staged operations |
