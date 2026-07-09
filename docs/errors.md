# Error handling

Every client function that can fail returns `{:ok, result}` or
`{:error, exception}`, where the exception is a struct that implements the
`MongrelDB.Exceptions` behaviour. You can pattern match on the specific struct
or on the common shape.

## Hierarchy

```
MongrelDB.Exceptions (behaviour, sets .kind)
  +-- MongrelDB.AuthException        HTTP 401 / 403,        kind: :auth
  +-- MongrelDB.NotFoundException    HTTP 404,              kind: :not_found
  +-- MongrelDB.ConstraintException  HTTP 409,              kind: :constraint
  +-- MongrelDB.ConnectionException  network-level failure, kind: :connection
  +-- MongrelDB.QueryException       HTTP 400 / 500,        kind: :query
```

All exception structs carry a `message` field and implement the Exception
protocol so they print cleanly.

## Matching by category

```elixir
case MongrelDB.put(db, "orders", %{1 => 1}) do # duplicate PK
  {:ok, result} ->
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
    IO.inspect(other)
end
```

## ConstraintException fields

- `message` - human-readable detail from the daemon.
- `error_code` - the server's error code string, e.g. `UNIQUE_VIOLATION`.
- `op_index` - when reported, the index of the offending operation within the
  batch (useful when a [transaction](transactions.md) commit fails).

## Connection failures

`ConnectionException` is returned for any network-level problem: connection
refused, DNS lookup failure, a broken socket, or a timeout. The `health/1`
helper swallows these and returns `{:ok, false}` instead, which is handy for
startup checks:

```elixir
{:ok, false} = MongrelDB.health(db)
# daemon not reachable; degrade gracefully
```

## JSON edge cases

The client refuses to send values that have no valid JSON representation:
infinity, NaN, and recursive structures. These raise a `QueryException` at the
client boundary rather than corrupting data on the server. Malformed UTF-8 is
passed through so the daemon can substitute it.
