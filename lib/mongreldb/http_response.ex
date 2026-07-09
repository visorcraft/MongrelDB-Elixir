defmodule MongrelDB.HTTPResponse do
  @moduledoc """
  Raw HTTP response from the daemon.

  A thin wrapper around the status code and body. Helpers on `MongrelDB`
  decode the body into JSON as needed.
  """

  @type t :: %__MODULE__{status: non_neg_integer(), body: binary()}

  defstruct status: 0, body: ""

  @doc "Whether the status code is in the 2xx success range."
  @spec successful?(t()) :: boolean()
  def successful?(%__MODULE__{status: status}), do: status >= 200 and status < 300
end
