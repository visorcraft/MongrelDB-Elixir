defmodule MongrelDB.CommitHlc do
  @moduledoc """
  Structural hybrid logical clock from durable recovery (0.64+).

  Fields match the daemon's `last_commit_hlc` JSON object. Parsing is structural
  (map keys), never free-form status text.
  """

  @type t :: %__MODULE__{
          physical_micros: non_neg_integer(),
          logical: non_neg_integer(),
          node_tiebreaker: non_neg_integer()
        }

  defstruct physical_micros: 0, logical: 0, node_tiebreaker: 0

  @doc "Parse a `last_commit_hlc` map. Returns `nil` when the shape is unusable."
  @spec from_map(term()) :: t() | nil
  def from_map(nil), do: nil

  def from_map(raw) when is_map(raw) do
    case Map.get(raw, "physical_micros") do
      nil ->
        nil

      pm ->
        %__MODULE__{
          physical_micros: to_non_neg_int(pm, 0),
          logical: to_non_neg_int(Map.get(raw, "logical"), 0),
          node_tiebreaker: to_non_neg_int(Map.get(raw, "node_tiebreaker"), 0)
        }
    end
  end

  def from_map(_), do: nil

  defp to_non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp to_non_neg_int(value, _default) when is_float(value), do: trunc(value)

  defp to_non_neg_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp to_non_neg_int(_, default), do: default
end

defmodule MongrelDB.DurableOutcome do
  @moduledoc """
  Nested durable recovery payload on query status / cancel responses (0.64+).

  Parity with the server `DurableOutcome` / `outcome` / `durable` JSON object.
  """

  alias MongrelDB.CommitHlc

  @type t :: %__MODULE__{
          committed: boolean() | nil,
          committed_statements: integer() | nil,
          last_commit_epoch: non_neg_integer() | nil,
          last_commit_epoch_text: String.t() | nil,
          last_commit_hlc: CommitHlc.t() | nil,
          first_commit_statement_index: integer() | nil,
          last_commit_statement_index: integer() | nil,
          completed_statements: integer() | nil,
          statement_index: integer() | nil,
          serialization: String.t(),
          serialization_state: String.t() | nil,
          terminal_state: String.t() | nil
        }

  defstruct [
    :committed,
    :committed_statements,
    :last_commit_epoch,
    :last_commit_epoch_text,
    :last_commit_hlc,
    :first_commit_statement_index,
    :last_commit_statement_index,
    :completed_statements,
    :statement_index,
    :serialization_state,
    :terminal_state,
    serialization: ""
  ]

  @doc "Parse an outcome/durable map. Missing maps become empty defaults."
  @spec from_map(term()) :: t()
  def from_map(raw) when is_map(raw) do
    %__MODULE__{
      committed: Map.get(raw, "committed"),
      committed_statements: optional_int(Map.get(raw, "committed_statements")),
      last_commit_epoch: optional_non_neg_int(Map.get(raw, "last_commit_epoch")),
      last_commit_epoch_text: optional_string(Map.get(raw, "last_commit_epoch_text")),
      last_commit_hlc: CommitHlc.from_map(Map.get(raw, "last_commit_hlc")),
      first_commit_statement_index: optional_int(Map.get(raw, "first_commit_statement_index")),
      last_commit_statement_index: optional_int(Map.get(raw, "last_commit_statement_index")),
      completed_statements: optional_int(Map.get(raw, "completed_statements")),
      statement_index: optional_int(Map.get(raw, "statement_index")),
      serialization: to_string(Map.get(raw, "serialization") || ""),
      serialization_state: optional_string(Map.get(raw, "serialization_state")),
      terminal_state: optional_string(Map.get(raw, "terminal_state"))
    }
  end

  def from_map(_), do: %__MODULE__{}

  defp optional_int(nil), do: nil
  defp optional_int(v) when is_integer(v), do: v
  defp optional_int(v) when is_float(v), do: trunc(v)

  defp optional_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp optional_int(_), do: nil

  defp optional_non_neg_int(nil), do: nil
  defp optional_non_neg_int(v) when is_integer(v) and v >= 0, do: v
  defp optional_non_neg_int(v) when is_float(v) and v >= 0, do: trunc(v)

  defp optional_non_neg_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp optional_non_neg_int(_), do: nil

  defp optional_string(nil), do: nil
  defp optional_string(v) when is_binary(v), do: v
  defp optional_string(v), do: to_string(v)
end

defmodule MongrelDB.QueryStatus do
  @moduledoc """
  Decoded `GET /queries/{query_id}` status for durable recovery (0.64+).

  Prefer `commit_hlc/1` and `serialization_state/1` over ad-hoc map access —
  they resolve nested durable / outcome / top-level fields in server order.
  """

  alias MongrelDB.{CommitHlc, DurableOutcome}

  @type t :: %__MODULE__{
          query_id: String.t(),
          status: String.t(),
          state: String.t(),
          server_state: String.t(),
          terminal_state: String.t() | nil,
          committed: boolean() | nil,
          outcome: DurableOutcome.t(),
          durable: DurableOutcome.t() | nil,
          last_commit_hlc: CommitHlc.t() | nil,
          raw: map()
        }

  defstruct [
    :query_id,
    :status,
    :state,
    :server_state,
    :terminal_state,
    :committed,
    :outcome,
    :durable,
    :last_commit_hlc,
    :raw
  ]

  @doc "Parse a query-status JSON object map into a `%QueryStatus{}`."
  @spec from_map(map()) :: t()
  def from_map(raw) when is_map(raw) do
    state = to_string(Map.get(raw, "state") || "")

    %__MODULE__{
      query_id: to_string(Map.get(raw, "query_id") || ""),
      status: to_string(Map.get(raw, "status") || ""),
      state: state,
      server_state: to_string(Map.get(raw, "server_state") || state),
      terminal_state: optional_string(Map.get(raw, "terminal_state")),
      committed: Map.get(raw, "committed"),
      outcome: DurableOutcome.from_map(Map.get(raw, "outcome") || %{}),
      durable:
        case Map.get(raw, "durable") do
          d when is_map(d) -> DurableOutcome.from_map(d)
          _ -> nil
        end,
      last_commit_hlc: CommitHlc.from_map(Map.get(raw, "last_commit_hlc")),
      raw: raw
    }
  end

  @doc """
  Authoritative commit HLC: nested `durable`, then `outcome`, then top-level.
  """
  @spec commit_hlc(t()) :: CommitHlc.t() | nil
  def commit_hlc(%__MODULE__{} = s) do
    (s.durable && s.durable.last_commit_hlc) ||
      s.outcome.last_commit_hlc ||
      s.last_commit_hlc
  end

  @doc """
  Prefer nested durable/outcome `serialization_state`, then `serialization`.
  """
  @spec serialization_state(t()) :: String.t()
  def serialization_state(%__MODULE__{} = s) do
    cond do
      is_binary(s.durable && s.durable.serialization_state) and
          s.durable.serialization_state != "" ->
        s.durable.serialization_state

      is_binary(s.outcome.serialization_state) and s.outcome.serialization_state != "" ->
        s.outcome.serialization_state

      is_binary(s.durable && s.durable.serialization) and s.durable.serialization != "" ->
        s.durable.serialization

      true ->
        s.outcome.serialization || ""
    end
  end

  defp optional_string(nil), do: nil
  defp optional_string(v) when is_binary(v), do: v
  defp optional_string(v), do: to_string(v)
end
