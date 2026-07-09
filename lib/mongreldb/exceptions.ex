defmodule MongrelDB.Exceptions do
  @moduledoc """
  Exception hierarchy for the MongrelDB Elixir client.

  Every client error is raised as a struct that implements the
  `Exception` behaviour and the `MongrelDB.Exceptions` callback, so
  callers can match on the specific kind (auth, not found, constraint,
  connection, query) or on the common base.

      try do
        MongrelDB.put(db, "orders", %{1 => 1})
      rescue
        e in MongrelDB.ConstraintException ->
          "constraint: \#{e.error_code}"
        e in MongrelDB.AuthException ->
          "not authorized: \#{e.message}"
        e in MongrelDB.QueryException ->
          "query error: \#{e.message}"
      end
  """

  @doc """
  Behaviour shared by all MongrelDB exceptions. Lets callers pattern match on
  the common `%{__exception__: true, kind: kind, message: message}` shape.
  """
  @callback kind() :: atom()
end

defmodule MongrelDB.AuthException do
  @moduledoc "Authentication or authorization failure (HTTP 401/403)."

  @behaviour MongrelDB.Exceptions

  defexception [:message]

  @impl MongrelDB.Exceptions
  def kind, do: :auth

  @impl true
  def message(%__MODULE__{message: message}), do: message
end

defmodule MongrelDB.NotFoundException do
  @moduledoc "The requested resource does not exist (HTTP 404)."

  @behaviour MongrelDB.Exceptions

  defexception [:message]

  @impl MongrelDB.Exceptions
  def kind, do: :not_found

  @impl true
  def message(%__MODULE__{message: message}), do: message
end

defmodule MongrelDB.ConstraintException do
  @moduledoc """
  A database constraint was violated at commit time (HTTP 409).

  Carries the server's `error_code` (for example `UNIQUE_VIOLATION`) and,
  when reported, the `op_index` of the offending operation within the batch.
  """

  @behaviour MongrelDB.Exceptions

  defexception [:message, :error_code, :op_index]

  @type t :: %__MODULE__{
          message: String.t() | nil,
          error_code: String.t() | nil,
          op_index: integer() | nil
        }

  @impl MongrelDB.Exceptions
  def kind, do: :constraint

  @impl true
  def message(%__MODULE__{message: message}), do: message

  @impl true
  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "Constraint violation")
    error_code = Keyword.get(opts, :error_code)
    op_index = Keyword.get(opts, :op_index)
    %__MODULE__{message: message, error_code: error_code, op_index: op_index}
  end
end

defmodule MongrelDB.ConnectionException do
  @moduledoc """
  Network-level failure: connection refused, DNS error, broken socket, timeout.
  """

  @behaviour MongrelDB.Exceptions

  defexception [:message, :reason]

  @type t :: %__MODULE__{message: String.t(), reason: term()}

  @impl MongrelDB.Exceptions
  def kind, do: :connection

  @impl true
  def message(%__MODULE__{message: message}), do: message

  @impl true
  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "Connection failure")
    reason = Keyword.get(opts, :reason)
    %__MODULE__{message: message, reason: reason}
  end
end

defmodule MongrelDB.QueryException do
  @moduledoc """
  Any server-reported error without a more specific type (HTTP 400/500),
  malformed payloads, or JSON failures.
  """

  @behaviour MongrelDB.Exceptions

  defexception [:message, :reason]

  @type t :: %__MODULE__{message: String.t(), reason: term()}

  @impl MongrelDB.Exceptions
  def kind, do: :query

  @impl true
  def message(%__MODULE__{message: message}), do: message

  @impl true
  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "Query error")
    reason = Keyword.get(opts, :reason)
    %__MODULE__{message: message, reason: reason}
  end
end
