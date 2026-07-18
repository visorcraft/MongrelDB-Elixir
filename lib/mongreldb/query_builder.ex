defmodule MongrelDB.QueryBuilder do
  @moduledoc """
  Fluent query builder for the Kit `/kit/query` endpoint.

  Conditions push down to the engine's specialized indexes for sub-millisecond
  lookups. Friendly aliases are translated to the server's on-wire keys before
  the request leaves the client:

    * `column` -> `column_id`
    * `min` / `max` -> `lo` / `hi`
    * `min_inclusive` / `max_inclusive` -> `lo_inclusive` / `hi_inclusive`

  The server's canonical keys are also accepted directly.

  ## Example

      MongrelDB.query(db, "orders")
      |> QueryBuilder.where("range", %{"column" => 3, "min" => 100.0})
      |> QueryBuilder.projection([1, 2])
      |> QueryBuilder.limit(100)
      |> QueryBuilder.execute()
  """

  @type t :: %__MODULE__{
          db: MongrelDB.t(),
          table: String.t(),
          conditions: [map()],
          projection: [integer()] | nil,
          limit: integer() | nil,
          offset: integer() | nil,
          truncated: boolean()
        }

  defstruct [:db, :table, :projection, :limit, :offset, conditions: [], truncated: false]

  @doc """
  Add a native condition.

  Supported types: `pk`, `bitmap_eq`, `bitmap_in`, `range`, `range_f64`,
  `is_null`, `is_not_null`, `fm_contains`, `fm_contains_all`, `ann`,
  `sparse_match`, `min_hash_similar`.
  """
  @spec where(t(), String.t(), map()) :: t()
  def where(%__MODULE__{} = q, type, params) do
    %{q | conditions: q.conditions ++ [%{type => normalize_condition(type, params)}]}
  end

  @doc "Set the column projection (column ids to return)."
  @spec projection(t(), [integer()]) :: t()
  def projection(%__MODULE__{} = q, column_ids) do
    %{q | projection: column_ids}
  end

  @doc "Set the row limit."
  @spec limit(t(), integer()) :: t()
  def limit(%__MODULE__{} = q, limit) do
    %{q | limit: limit}
  end

  @doc "Skip matching rows before applying the limit."
  @spec offset(t(), integer()) :: t()
  def offset(%__MODULE__{} = q, offset) do
    %{q | offset: offset}
  end

  @doc "Build the outgoing `/kit/query` payload."
  @spec build(t()) :: map()
  def build(%__MODULE__{} = q) do
    payload = %{"table" => q.table}

    payload =
      if q.conditions != [],
        do: Map.put(payload, "conditions", q.conditions),
        else: payload

    payload =
      if q.projection,
        do: Map.put(payload, "projection", q.projection),
        else: payload

    payload = if q.limit, do: Map.put(payload, "limit", q.limit), else: payload
    payload = if q.offset, do: Map.put(payload, "offset", q.offset), else: payload
    payload
  end

  @doc "Execute the query and return matching rows."
  @spec execute(t()) :: {:ok, [map()]} | {:error, term()}
  def execute(%__MODULE__{db: db} = q) do
    with {:ok, resp} <- MongrelDB.post(db, "/kit/query", build(q)) do
      body = MongrelDB.JSON.decode(resp.body)

      case body do
        {:ok, data} when is_map(data) ->
          rows = Map.get(data, "rows", [])
          {:ok, rows}

        _ ->
          {:ok, []}
      end
    end
  end

  @doc "Whether the last execute/1 result was capped by the limit."
  @spec truncated?(t()) :: boolean()
  def truncated?(%__MODULE__{truncated: truncated}), do: truncated

  # Translate friendly aliases to the server's canonical wire keys.
  @doc false
  def normalize_condition(type, params) do
    aliases = %{
      "column" => "column_id",
      "min" => "lo",
      "max" => "hi",
      "min_inclusive" => "lo_inclusive",
      "max_inclusive" => "hi_inclusive"
    }

    params
    |> Enum.map(fn {key, value} ->
      key =
        if type in ["fm_contains", "fm_contains_all"] and key == "value" do
          "pattern"
        else
          key
        end

      {Map.get(aliases, key, key), value}
    end)
    |> Map.new()
  end
end
