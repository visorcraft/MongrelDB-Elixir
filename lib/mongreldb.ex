defmodule MongrelDB do
  @moduledoc """
  Pure Elixir HTTP client for MongrelDB.

  Connect to a running `mongreldb-server` daemon and run typed CRUD, batch
  transactions, native index queries, and SQL. Built on the Erlang/OTP
  `:inets` application's `:httpc`, so there are no external runtime
  dependencies beyond Elixir itself.

  ## Quick example

      db = MongrelDB.connect("http://127.0.0.1:8453")

      MongrelDB.create_table(db, "orders", [
        %{"id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false},
      ])

      MongrelDB.put(db, "orders", %{1 => 1, 2 => "Alice", 3 => 99.5})
      MongrelDB.count(db, "orders")
  """

  alias MongrelDB.{
    AuthException,
    ConnectionException,
    ConstraintException,
    NotFoundException,
    QueryBuilder,
    QueryException,
    Transaction
  }

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          headers: [{String.t(), String.t()}],
          timeout: timeout()
        }

  @enforce_keys [:base_url]
  defstruct [:base_url, :token, :username, :password, :headers, :timeout]

  @doc """
  Connect to a running `mongreldb-server` daemon.

  ## Options

    * `:token` - Bearer token for `--auth-token` mode.
    * `:username` / `:password` - credentials for `--auth-users` (HTTP Basic) mode.
      If both `:token` and `:username` are supplied, `:token` wins.
    * `:timeout` - per-request timeout (default `30_000` ms).
  """
  @spec connect(String.t(), keyword()) :: t()
  def connect(base_url, opts \\ []) do
    base_url = String.trim_trailing(base_url, "/")
    token = Keyword.get(opts, :token)
    username = Keyword.get(opts, :username)
    password = Keyword.get(opts, :password)
    timeout = Keyword.get(opts, :timeout, 30_000)

    auth_header =
      cond do
        token != nil ->
          [{"Authorization", "Bearer " <> token}]

        username != nil ->
          creds = Base.encode64("#{username}:#{password || ""}")
          [{"Authorization", "Basic " <> creds}]

        true ->
          []
      end

    headers = [{"Accept", "application/json"} | auth_header]

    %__MODULE__{
      base_url: base_url,
      token: token,
      username: username,
      password: password,
      headers: headers,
      timeout: timeout
    }
  end

  # -- Convenience API -------------------------------------------------------

  @doc "Check daemon health. Returns `{:ok, true}` on success, `{:ok, false}` on failure."
  @spec health(t()) :: {:ok, boolean()} | {:error, term()}
  def health(db) do
    case get(db, "/health") do
      {:ok, _resp} -> {:ok, true}
      {:error, _reason} -> {:ok, false}
    end
  end

  @doc "List all table names."
  @spec table_names(t()) :: {:ok, [String.t()]} | {:error, term()}
  def table_names(db) do
    with {:ok, body} <- get_json(db, "/tables") do
      {:ok, List.wrap(body)}
    end
  end

  @doc """
  Create a table. `columns` is a list of column descriptor maps.

  Returns `{:ok, table_id}` on success, where `table_id` is the daemon-reported
  table id (0 if none was reported).
  """
  @spec create_table(t(), String.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def create_table(db, name, columns) do
    create_table(db, name, columns, nil)
  end

  @doc "Create a table with the daemon's native constraints block."
  @spec create_table(t(), String.t(), [map()], map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def create_table(db, name, columns, constraints) do
    request = %{"name" => name, "columns" => columns}
    request = if constraints, do: Map.put(request, "constraints", constraints), else: request

    with {:ok, body} <-
           post_json(db, "/kit/create_table", request) do
      {:ok, Map.get(body, "table_id", 0)}
    end
  end

  @doc "Drop a table by name."
  @spec drop_table(t(), String.t()) :: :ok | {:error, term()}
  def drop_table(db, name) do
    with {:ok, _} <- delete(db, "/tables/#{encode_segment(name)}"), do: :ok
  end

  @doc "Row count for a table."
  @spec count(t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(db, table) do
    with {:ok, body} <- get_json(db, "/tables/#{encode_segment(table)}/count") do
      {:ok, Map.get(body, "count", 0)}
    end
  end

  @doc """
  Insert a row. `cells` maps column id to value (`%{1 => 1, 2 => "Alice"}`).

  Returns `{:ok, result}` where `result` is the per-op result map, or an empty
  map if none was reported.
  """
  @spec put(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(db, table, cells, opts \\ []) do
    payload = %{
      "ops" => [%{"put" => %{"table" => table, "cells" => cells_to_flat(cells)}}]
    }

    payload = maybe_add_idempotency(payload, opts[:idempotency_key])

    with {:ok, body} <- post_json(db, "/kit/txn", payload) do
      {:ok, first_result(body)}
    end
  end

  @doc """
  Upsert a row (insert or update on PK conflict).

  `update_cells` (optional) sets the values to apply on conflict; omit it for
  DO NOTHING semantics.
  """
  @spec upsert(t(), String.t(), map(), map() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def upsert(db, table, cells, update_cells \\ nil, opts \\ []) do
    op = %{"table" => table, "cells" => cells_to_flat(cells)}

    op =
      if update_cells,
        do: Map.put(op, "update_cells", cells_to_flat(update_cells)),
        else: op

    payload = %{"ops" => [%{"upsert" => op}]}
    payload = maybe_add_idempotency(payload, opts[:idempotency_key])

    with {:ok, body} <- post_json(db, "/kit/txn", payload) do
      {:ok, first_result(body)}
    end
  end

  @doc "Delete a row by its internal row id."
  @spec delete(t(), String.t(), integer()) :: :ok | {:error, term()}
  def delete(db, table, row_id) do
    payload = %{"ops" => [%{"delete" => %{"table" => table, "row_id" => row_id}}]}

    with {:ok, _} <- post_json(db, "/kit/txn", payload), do: :ok
  end

  @doc "Delete a row by its primary key value."
  @spec delete_by_pk(t(), String.t(), term()) :: :ok | {:error, term()}
  def delete_by_pk(db, table, pk) do
    payload = %{"ops" => [%{"delete_by_pk" => %{"table" => table, "pk" => pk}}]}

    with {:ok, _} <- post_json(db, "/kit/txn", payload), do: :ok
  end

  @doc """
  Execute SQL against the daemon's DataFusion-backed `/sql` endpoint.

  Requests the JSON result format, so a SELECT returns a JSON array of row
  objects keyed by column name. Returns `{:ok, rows}` for SELECTs, or
  `{:ok, []}` for statements like INSERT/UPDATE that produce no rows.
  """
  @spec sql(t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def sql(db, statement) do
    with {:ok, body} <- post_json(db, "/sql", %{"sql" => statement, "format" => "json"}) do
      rows = if is_list(body), do: body, else: []
      {:ok, rows}
    end
  end

  @doc """
  Start a fluent query builder.

      MongrelDB.query(db, "orders")
      |> QueryBuilder.where("pk", %{"value" => 1})
      |> QueryBuilder.execute()
  """
  @spec query(t(), String.t()) :: QueryBuilder.t()
  def query(db, table), do: %QueryBuilder{db: db, table: table}

  @doc "Full schema catalog (table name to descriptor)."
  @spec schema(t()) :: {:ok, map()} | {:error, term()}
  def schema(db) do
    with {:ok, body} <- get_json(db, "/kit/schema") do
      {:ok, Map.get(body, "tables", %{})}
    end
  end

  @doc "Descriptor for a single table."
  @spec schema_for(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def schema_for(db, table), do: get_json(db, "/kit/schema/#{encode_segment(table)}")

  @doc "Compact all tables (merge sorted runs)."
  @spec compact(t()) :: {:ok, map()} | {:error, term()}
  def compact(db), do: post_json(db, "/compact", %{})

  @doc "Return the full history-retention response map from the daemon."
  @spec history_retention(t()) :: {:ok, map()} | {:error, term()}
  def history_retention(db), do: get_json(db, "/history/retention")

  @doc "Return the configured history retention window in epochs."
  @spec history_retention_epochs(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def history_retention_epochs(db) do
    with {:ok, body} <- get_json(db, "/history/retention") do
      extract_retention_integer(body, "history_retention_epochs")
    end
  end

  @doc "Return the earliest epoch that is still readable via `AS OF EPOCH`."
  @spec earliest_retained_epoch(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def earliest_retained_epoch(db) do
    with {:ok, body} <- get_json(db, "/history/retention") do
      extract_retention_integer(body, "earliest_retained_epoch")
    end
  end

  @doc """
  Set the history retention window to `epochs` epochs.

  Returns `{:ok, history_retention_epochs}` on success, where the value is the
  daemon-confirmed retention window. Validates the response shape and integer
  values; non-2xx responses are mapped through the usual typed exceptions.
  """
  @spec set_history_retention_epochs(t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def set_history_retention_epochs(db, epochs) when is_integer(epochs) and epochs >= 0 do
    with {:ok, body} <-
           put_json(db, "/history/retention", %{"history_retention_epochs" => epochs}) do
      extract_retention_integer(body, "history_retention_epochs")
    end
  end

  @doc "Begin a batch transaction."
  @spec begin_transaction(t()) :: Transaction.t()
  def begin_transaction(db), do: %Transaction{db: db}

  # -- HTTP plumbing ---------------------------------------------------------

  @doc false
  # Performs a GET request and returns the raw `MongrelDB.HTTPResponse`.
  def get(db, path) do
    request(db, :get, path, nil)
  end

  @doc false
  def post(db, path, body) do
    encoded = encode_json!(body)
    request(db, :post, path, encoded)
  end

  defp http_put(db, path, body), do: request(db, :put, path, encode_json!(body))

  @doc false
  def delete(db, path) do
    request(db, :delete, path, nil)
  end

  defp get_json(db, path) do
    with {:ok, resp} <- get(db, path) do
      {:ok, decode_json!(resp.body)}
    end
  end

  defp post_json(db, path, body) do
    with {:ok, resp} <- post(db, path, body) do
      {:ok, decode_json!(resp.body)}
    end
  end

  defp put_json(db, path, body) do
    with {:ok, resp} <- http_put(db, path, body), do: {:ok, decode_json!(resp.body)}
  end

  # Core request helper. Uses :inets :httpc and maps status codes to typed
  # exceptions.
  defp request(db, method, path, body) do
    url = db.base_url <> "/" <> String.trim_leading(path, "/")
    http_method = method_to_atom(method)
    cl_headers = build_charlist_headers(db.headers)
    content_type = ~c"application/json"

    # :httpc wants the request tuple as {url, headers, content_type, body} when
    # a body is present, and {url, headers} when it is not.
    request_tuple =
      if body do
        {String.to_charlist(url), cl_headers, content_type, body}
      else
        {String.to_charlist(url), cl_headers}
      end

    # {:autoredirect, false} stops :httpc from following redirects, which
    # would otherwise leak the Authorization header to redirect targets.
    # The :ssl options are left at :httpc's defaults so the bundled CA
    # store is used for peer verification (overriding {:verify,
    # :verify_peer} alone drops the CA bundle and breaks verification).
    http_opts = [
      {:timeout, db.timeout},
      {:autoredirect, false}
    ]

    result =
      :httpc.request(
        http_method,
        request_tuple,
        http_opts,
        [{:body_format, :binary}]
      )

    case result do
      {:ok, {{_http, status, _}, headers, resp_body}} when status >= 200 and status < 300 ->
        handle_success(status, headers, resp_body)

      {:ok, {{_http, status, _}, _headers, resp_body}} ->
        {:error, status_to_exception(status, to_string(resp_body || ""))}

      {:error, {:failed_connect, _}} ->
        {:error,
         %ConnectionException{
           message: "Cannot reach MongrelDB daemon at #{db.base_url}"
         }}

      {:error, reason} ->
        {:error, %ConnectionException{message: "HTTP request failed", reason: reason}}
    end
  end

  defp method_to_atom(:get), do: :get
  defp method_to_atom(:post), do: :post
  defp method_to_atom(:put), do: :put
  defp method_to_atom(:delete), do: :delete

  defp build_charlist_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  # Build a success response, enforcing a 256 MB body size cap.
  #
  # :httpc buffers the whole body before returning, so a true streaming cap is
  # not possible without rewriting the transport. As an early guard we reject
  # responses whose declared Content-Length already exceeds the cap, before we
  # touch the body. The post-check on the materialized body remains as a
  # belt-and-suspenders guard for chunked/missing Content-Length responses.
  defp handle_success(status, headers, resp_body) do
    max_bytes = 256 * 1024 * 1024

    case content_length(headers) do
      {:ok, len} when len > max_bytes ->
        {:error,
         %QueryException{
           message: "response body exceeds #{max_bytes} bytes (Content-Length: #{len})"
         }}

      _ ->
        body = to_string(resp_body || "")

        if byte_size(body) > max_bytes do
          {:error,
           %QueryException{
             message: "response body exceeds #{max_bytes} bytes (#{byte_size(body)} bytes)"
           }}
        else
          {:ok, %MongrelDB.HTTPResponse{status: status, body: body}}
        end
    end
  end

  # :httpc returns headers as a list of {charlist_key, charlist_value} tuples.
  # Find the Content-Length header (case-insensitive) and parse its integer
  # value. Returns {:ok, integer} or :error when absent/invalid.
  defp content_length(headers) do
    headers
    |> Enum.find(:error, fn {key, _} ->
      String.downcase(to_string(key)) == "content-length"
    end)
    |> case do
      :error ->
        :error

      {_, value} ->
        case Integer.parse(to_string(value)) do
          {len, _} -> {:ok, len}
          :error -> :error
        end
    end
  end

  defp status_to_exception(status, body) do
    {message, error_code, op_index} = parse_error_envelope(body)
    message = if message == "", do: "Server error (#{status})", else: message

    case {status, message} do
      {_, "not found:" <> _} ->
        %NotFoundException{message: message}

      {s, _} when s in [401, 403] ->
        %AuthException{message: message}

      {404, _} ->
        %NotFoundException{message: message}

      {409, _} ->
        %ConstraintException{
          message: message,
          error_code: error_code,
          op_index: op_index
        }

      _ ->
        %QueryException{message: message}
    end
  end

  defp parse_error_envelope(body) do
    case decode_json!(body) do
      %{"error" => err} when is_map(err) ->
        {Map.get(err, "message", body), Map.get(err, "code"), Map.get(err, "op_index")}

      _ ->
        {body, nil, nil}
    end
  end

  # JSON encode. Rejects NaN/Infinity (Jason-free: use Erlang's term_to_binary
  # guard plus a manual encoder is overkill; Elixir ships no JSON in stdlib, so
  # we lean on the tiny encoder below).
  defp encode_json!(value) do
    case MongrelDB.JSON.encode(value) do
      {:ok, json} ->
        json

      {:error, reason} ->
        raise QueryException,
          message:
            "Request payload cannot be JSON-encoded. " <>
              "INF, NaN, and recursive structures have no JSON representation.",
          reason: reason
    end
  end

  defp decode_json!(""), do: %{}
  defp decode_json!("[" <> _ = body), do: decode_list!(body)

  defp decode_json!(body) when is_binary(body) do
    case MongrelDB.JSON.decode(body) do
      {:ok, value} -> value
      {:error, _} -> %{}
    end
  end

  defp decode_list!(body) do
    case MongrelDB.JSON.decode(body) do
      {:ok, value} when is_list(value) -> value
      _ -> []
    end
  end

  defp first_result(%{"results" => [first | _]}) when is_map(first), do: first
  defp first_result(_), do: %{}

  # The frozen /history/retention contract returns exactly these two integer
  # keys. Reject unexpected shapes so callers cannot be silently confused by a
  # daemon that changed its response format.
  defp extract_retention_integer(body, key) when is_map(body) do
    expected = ["history_retention_epochs", "earliest_retained_epoch"]

    with true <-
           Enum.all?(expected, &Map.has_key?(body, &1)) ||
             {:error, unexpected_retention_body(body)},
         {:ok, value} <- Map.fetch(body, key),
         true <-
           (is_integer(value) and value >= 0) || {:error, invalid_retention_value(key, value)} do
      {:ok, value}
    end
  end

  defp extract_retention_integer(body, _key), do: {:error, unexpected_retention_body(body)}

  defp unexpected_retention_body(body) do
    %QueryException{
      message: "unexpected /history/retention response: #{inspect(body)}",
      reason: :unexpected_retention_shape
    }
  end

  defp invalid_retention_value(key, value) do
    %QueryException{
      message: "expected non-negative integer for #{key}, got: #{inspect(value)}",
      reason: :invalid_retention_value
    }
  end

  defp maybe_add_idempotency(payload, nil), do: payload

  defp maybe_add_idempotency(payload, key),
    do: Map.put(payload, "idempotency_key", key)

  defp cells_to_flat(cells) do
    cells
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.flat_map(fn {k, v} -> [k, v] end)
  end

  # Percent-encode a single URL path segment so a table name containing '/',
  # '?', '#', or spaces cannot inject extra segments or break routing.
  defp encode_segment(segment) do
    URI.encode_www_form(to_string(segment))
  end
end
