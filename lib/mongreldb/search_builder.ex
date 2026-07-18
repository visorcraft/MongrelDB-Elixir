defmodule MongrelDB.SearchBuilder do
  @moduledoc """
  Fluent builder for `POST /kit/search` — multi-retriever hybrid search with
  reciprocal-rank fusion and optional exact-vector rerank.

  Wire format matches the daemon KitSearchRequest (flattened retrievers).
  """

  @type t :: %__MODULE__{
          db: MongrelDB.t(),
          table: String.t(),
          must: [map()],
          retrievers: [map()],
          fusion: map(),
          rerank: map() | nil,
          limit: integer(),
          projection: [integer()] | nil,
          explain: boolean(),
          cursor: String.t() | nil
        }

  defstruct [
    :db,
    :table,
    :projection,
    :cursor,
    must: [],
    retrievers: [],
    fusion: %{"reciprocal_rank" => %{"constant" => 60}},
    rerank: nil,
    limit: 10,
    explain: false
  ]

  @doc "Hard filter (same condition shapes as QueryBuilder.where/3)."
  @spec must(t(), String.t(), map()) :: t()
  def must(%__MODULE__{} = s, type, params) do
    entry = %{type => MongrelDB.QueryBuilder.normalize_condition(type, params)}
    %{s | must: s.must ++ [entry]}
  end

  @spec ann_retriever(t(), String.t(), integer(), [float()], keyword()) :: t()
  def ann_retriever(%__MODULE__{} = s, name, column_id, query, opts \\ []) do
    k = Keyword.get(opts, :k, 64)
    weight = Keyword.get(opts, :weight, 1.0)

    r = %{
      "name" => name,
      "weight" => weight,
      "ann" => %{"column_id" => column_id, "query" => query, "k" => k}
    }

    %{s | retrievers: s.retrievers ++ [r]}
  end

  @doc "terms is a list of `{token_id, weight}` tuples."
  @spec sparse_retriever(t(), String.t(), integer(), [{integer(), float()}], keyword()) :: t()
  def sparse_retriever(%__MODULE__{} = s, name, column_id, terms, opts \\ []) do
    k = Keyword.get(opts, :k, 64)
    weight = Keyword.get(opts, :weight, 1.0)
    pairs = Enum.map(terms, fn {t, w} -> [t, w] end)

    r = %{
      "name" => name,
      "weight" => weight,
      "sparse" => %{"column_id" => column_id, "query" => pairs, "k" => k}
    }

    %{s | retrievers: s.retrievers ++ [r]}
  end

  @spec min_hash_retriever(t(), String.t(), integer(), [String.t()], keyword()) :: t()
  def min_hash_retriever(%__MODULE__{} = s, name, column_id, members, opts \\ []) do
    k = Keyword.get(opts, :k, 64)
    weight = Keyword.get(opts, :weight, 1.0)

    r = %{
      "name" => name,
      "weight" => weight,
      "min_hash" => %{"column_id" => column_id, "members" => members, "k" => k}
    }

    %{s | retrievers: s.retrievers ++ [r]}
  end

  @spec fusion(t(), integer()) :: t()
  def fusion(%__MODULE__{} = s, constant \\ 60) do
    %{s | fusion: %{"reciprocal_rank" => %{"constant" => max(constant, 1)}}}
  end

  @spec exact_rerank(t(), integer(), [float()], keyword()) :: t()
  def exact_rerank(%__MODULE__{} = s, embedding_column, query, opts \\ []) do
    metric = Keyword.get(opts, :metric, "cosine")
    candidate_limit = Keyword.get(opts, :candidate_limit, 64)
    weight = Keyword.get(opts, :weight, 1.0)

    %{
      s
      | rerank: %{
          "exact_vector" => %{
            "embedding_column" => embedding_column,
            "query" => query,
            "metric" => metric,
            "candidate_limit" => candidate_limit,
            "weight" => weight
          }
        }
    }
  end

  @spec limit(t(), integer()) :: t()
  def limit(%__MODULE__{} = s, limit), do: %{s | limit: limit}

  @spec projection(t(), [integer()]) :: t()
  def projection(%__MODULE__{} = s, column_ids), do: %{s | projection: column_ids}

  @spec explain(t(), boolean()) :: t()
  def explain(%__MODULE__{} = s, on \\ true), do: %{s | explain: on}

  @spec cursor(t(), String.t() | nil) :: t()
  def cursor(%__MODULE__{} = s, cursor), do: %{s | cursor: cursor}

  @spec build(t()) :: map()
  def build(%__MODULE__{} = s) do
    if s.retrievers == [], do: raise(ArgumentError, "search requires at least one retriever")
    if s.limit <= 0, do: raise(ArgumentError, "search limit must be positive")

    payload = %{
      "table" => s.table,
      "retrievers" => s.retrievers,
      "fusion" => s.fusion,
      "limit" => s.limit
    }

    payload = if s.must != [], do: Map.put(payload, "must", s.must), else: payload
    payload = if s.rerank, do: Map.put(payload, "rerank", s.rerank), else: payload
    payload = if s.projection, do: Map.put(payload, "projection", s.projection), else: payload
    payload = if s.explain, do: Map.put(payload, "explain", true), else: payload

    if s.cursor && s.cursor != "" do
      Map.put(payload, "cursor", s.cursor)
    else
      payload
    end
  end

  @doc "Execute hybrid search. Returns `{:ok, body}` with `hits` key."
  @spec execute(t()) :: {:ok, map()} | {:error, term()}
  def execute(%__MODULE__{db: db} = s) do
    with {:ok, resp} <- MongrelDB.post(db, "/kit/search", build(s)) do
      case MongrelDB.JSON.decode(resp.body) do
        {:ok, data} when is_map(data) -> {:ok, data}
        _ -> {:ok, %{"hits" => []}}
      end
    end
  end
end
