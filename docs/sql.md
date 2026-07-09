# SQL

For ad-hoc SQL, the client talks to the daemon's DataFusion-backed `/sql`
endpoint. The client never parses or interprets SQL locally; it just ships the
statement and returns the response.

## Running SQL

```elixir
{:ok, _} = MongrelDB.sql(db, "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
{:ok, _} = MongrelDB.sql(db, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")
```

The `/sql` endpoint may return Arrow IPC bytes for rich SELECTs. In that case
`sql/2` returns `{:ok, []}`. For typed, JSON-shaped reads, prefer the native
[query builder](queries.md).

## DataFusion features

Because the engine delegates to DataFusion, you get its full surface for free:

```elixir
# Recursive CTE
MongrelDB.sql(db, "WITH RECURSIVE r(n) AS "
  <> "(SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")

# Window function
MongrelDB.sql(db, "SELECT id, ROW_NUMBER() OVER "
  <> "(PARTITION BY customer ORDER BY amount DESC) FROM orders")

# CREATE TABLE AS SELECT
MongrelDB.sql(db, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")
```

## When to use SQL vs the query builder

- Use the [native query builder](queries.md) when you want typed conditions
  that push down to bitmap, learned-range, FM-index, or HNSW indexes. There is
  no SQL injection surface because values are serialized as typed JSON.
- Use `sql/2` when you need DataFusion features the Kit endpoint does not
  expose (window functions, recursive CTEs, `CREATE TABLE AS SELECT`).
