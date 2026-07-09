defmodule MongrelDB.Exceptions do
  @moduledoc """
  Exception hierarchy for the MongrelDB Elixir client.

  Every client error is raised as a struct that implements the
  `MongrelDB.Exception` behaviour, so callers can match on the specific kind
  (auth, not found, constraint, connection, query) or on the common base.

      try do
        MongrelDB.put(db, "orders", %{1 => 1})
      rescue
        e in MongrelDB.ConstraintException ->
          "constraint: \#{e.error_code}"
        e in MongrelDB.AuthException ->
          "not authorized: \#{e.message}"
        e in MongrelDB.Exception ->
          "error: \#{e.message}"
      end
  """

  @doc """
  Behaviour shared by all MongrelDB exceptions. Lets callers pattern match on
  the common `%{__exception__: true, kind: kind, message: message}` shape.
  """
  @callback kind() :: atom()
end

defmodule MongrelDB.Exception do
  @moduledoc """
  Common protocol-like helper: the base of the typed exception hierarchy.

  Every MongrelDB exception struct includes a `kind` field set to one of
  `:auth`, `:not_found`, `:constraint`, `:connection`, or `:query`, plus a
  human-readable `message`. Concrete exceptions live in
  `MongrelDB.Exceptions`.
  """

  @doc "Build the `%{__exception__: true, kind: kind, message: message}` base map."
  def base(kind, message) when is_atom(kind) and is_binary(message) do
    %{__exception__: true, kind: kind, message: message}
  end
end

defmodule MongrelDB.AuthException do
  @moduledoc "Authentication or authorization failure (HTTP 401/403)."
  defstruct message: ""

  @behaviour MongrelDB.Exceptions

  @impl true
  def kind, do: :auth

  @type t :: %__MODULE__{message: String.t()}

  @doc false
  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  @doc false
  def message(%__MODULE__{message: message}), do: message
end

defmodule MongrelDB.NotFoundException do
  @moduledoc "The requested resource does not exist (HTTP 404)."
  defstruct message: ""

  @behaviour MongrelDB.Exceptions

  @impl true
  def kind, do: :not_found

  @type t :: %__MODULE__{message: String.t()}

  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  def message(%__MODULE__{message: message}), do: message
end

defmodule MongrelDB.ConstraintException do
  @moduledoc """
  A database constraint was violated at commit time (HTTP 409).

  Carries the server's `error_code` (for example `UNIQUE_VIOLATION`) and,
  when reported, the `op_index` of the offending operation within the batch.
  """
  defstruct [:message, :error_code, :op_index]

  @behaviour MongrelDB.Exceptions

  @impl true
  def kind, do: :constraint

  @type t :: %__MODULE__{
          message: String.t() | nil,
          error_code: String.t() | nil,
          op_index: integer() | nil
        }

  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "Constraint violation")
    error_code = Keyword.get(opts, :error_code)
    op_index = Keyword.get(opts, :op_index)
    %__MODULE__{message: message, error_code: error_code, op_index: op_index}
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  def message(%__MODULE__{message: message}), do: message
end

defmodule MongrelDB.ConnectionException do
  @moduledoc """
  Network-level failure: connection refused, DNS error, broken socket, timeout.
  """
  defstruct [:message, :reason]

  @behaviour MongrelDB.Exceptions

  @impl true
  def kind, do: :connection

  @type t :: %__MODULE__{message: String.t(), reason: term()}

  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "Connection failure")
    reason = Keyword.get(opts, :reason)
    %__MODULE__{message: message, reason: reason}
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  def message(%__MODULE__{message: message}), do: message
end

defmodule MongrelDB.QueryException do
  @moduledoc """
  Any server-reported error without a more specific type (HTTP 400/500),
  malformed payloads, or JSON failures.
  """
  defstruct [:message, :reason]

  @behaviour MongrelDB.Exceptions

  @impl true
  def kind, do: :query

  @type t :: %__MODULE__{message: String.t(), reason: term()}

  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "Query error")
    reason = Keyword.get(opts, :reason)
    %__MODULE__{message: message, reason: reason}
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  def message(%__MODULE__{message: message}), do: message
end
