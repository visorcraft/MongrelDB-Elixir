defmodule MongrelDB.CreateTableWireTest do
  @moduledoc """
  Wire-shape conformance for `MongrelDB.create_table/3`.

  The client forwards the column map unchanged to the `/kit/create_table`
  endpoint as JSON. These tests boot a tiny in-process HTTP listener so the
  request body can be inspected without a running daemon, and so we can
  pin down which keys survive the trip (T5.2).
  """
  use ExUnit.Case, async: false

  alias MongrelDB.JSON

  test "static default matrix preserves JSON scalar types and literal now", %{server: server} do
    db = MongrelDB.connect("http://127.0.0.1:#{server.port}")

    columns =
      [
        {"draft_col", %{"default_value" => "draft"}},
        {"seven_col", %{"default_value" => 7}},
        {"true_col", %{"default_value" => true}},
        {"nil_col", %{"default_value" => nil}},
        {"now_literal_col", %{"default_value" => "now"}},
        {"now_expr_col", %{"default_expr" => "now"}}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, extra}, id} ->
        Map.merge(
          %{
            "id" => id,
            "name" => name,
            "ty" => "varchar",
            "primary_key" => false,
            "nullable" => false
          },
          extra
        )
      end)

    assert {:ok, 0} = MongrelDB.create_table(db, "defaults_matrix", columns)

    body = receive_capture()
    {:ok, decoded} = JSON.decode(body)
    cols = decoded["columns"]

    # Literal default_values preserve their JSON scalar type through the wire.
    assert col_by_name(cols, "draft_col")["default_value"] === "draft"
    assert col_by_name(cols, "seven_col")["default_value"] === 7
    assert col_by_name(cols, "true_col")["default_value"] === true
    assert col_by_name(cols, "nil_col")["default_value"] === nil
    assert col_by_name(cols, "now_literal_col")["default_value"] === "now"

    # default_expr is a separate key and never collapses into default_value.
    assert col_by_name(cols, "now_expr_col")["default_expr"] === "now"
    refute Map.has_key?(col_by_name(cols, "now_expr_col"), "default_value")

    # Wire-shape guarantee: the keys and JSON types survive unchanged.
    assert body =~ ~s("default_value":"draft")
    assert body =~ ~s("default_value":7)
    assert body =~ ~s("default_value":true)
    assert body =~ ~s("default_value":null)
    assert body =~ ~s("default_value":"now")
    assert body =~ ~s("default_expr":"now")
  end

  setup do
    server = start_http_capture!()
    on_exit(fn -> stop_http_capture(server) end)
    {:ok, server: server}
  end

  test "create_table forwards all indexes and embedding source", %{server: server} do
    db = MongrelDB.connect("http://127.0.0.1:#{server.port}")

    columns = [
      %{"id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true},
      %{
        "id" => 2,
        "name" => "embedding",
        "ty" => "embedding(384)",
        "embedding_source" => %{
          "kind" => "configured_model",
          "provider_id" => "docs",
          "model_id" => "model",
          "model_version" => "1"
        }
      }
    ]

    indexes = [
      %{"name" => "bm", "column_id" => 1, "kind" => "bitmap"},
      %{"name" => "fm", "column_id" => 1, "kind" => "fm_index"},
      %{
        "name" => "ann",
        "column_id" => 2,
        "kind" => "ann",
        "predicate" => "embedding IS NOT NULL",
        "options" => %{
          "ann" => %{
            "m" => 24,
            "ef_construction" => 96,
            "ef_search" => 48,
            "quantization" => "dense",
            "algorithm" => "diskann",
            "diskann" => %{"r" => 64, "l" => 128, "beam_width" => 8, "alpha" => 120}
          }
        }
      },
      %{"name" => "range", "column_id" => 1, "kind" => "learned_range"},
      %{"name" => "minhash", "column_id" => 1, "kind" => "minhash"},
      %{"name" => "sparse", "column_id" => 1, "kind" => "sparse"}
    ]

    assert {:ok, 0} = MongrelDB.create_table(db, "search_docs", columns, nil, indexes)
    body = receive_capture()
    {:ok, decoded} = JSON.decode(body)

    assert get_in(decoded, ["columns", Access.at(1), "embedding_source", "kind"]) ==
             "configured_model"

    assert Enum.map(decoded["indexes"], & &1["kind"]) ==
             ["bitmap", "fm_index", "ann", "learned_range", "minhash", "sparse"]

    assert get_in(decoded, ["indexes", Access.at(2), "options", "ann", "quantization"]) ==
             "dense"

    assert get_in(decoded, ["indexes", Access.at(2), "options", "ann", "algorithm"]) ==
             "diskann"

    assert get_in(decoded, ["indexes", Access.at(2), "options", "ann", "diskann", "r"]) == 64

    assert get_in(decoded, ["indexes", Access.at(2), "predicate"]) ==
             "embedding IS NOT NULL"
  end

  test "create_table forwards enum_variants and default_value on the column map",
       %{server: server} do
    db = MongrelDB.connect("http://127.0.0.1:#{server.port}")

    assert {:ok, 0} =
             MongrelDB.create_table(
               db,
               "orders",
               [
                 %{
                   "id" => 1,
                   "name" => "id",
                   "ty" => "int64",
                   "primary_key" => true,
                   "nullable" => false
                 },
                 %{
                   "id" => 2,
                   "name" => "status",
                   "ty" => "varchar",
                   "primary_key" => false,
                   "nullable" => false,
                   "enum_variants" => ["a", "b", "c"],
                   "default_value" => 3,
                   "default_expr" => "uuid"
                 }
               ],
               %{
                 "checks" => [
                   %{
                     "id" => 1,
                     "name" => "known_status",
                     "expr" => %{
                       "Eq" => [%{"Col" => 2}, %{"Lit" => %{"Bytes" => "a"}}]
                     }
                   }
                 ]
               }
             )

    body = receive_capture()
    {:ok, decoded} = JSON.decode(body)

    assert decoded["name"] == "orders"
    assert is_list(decoded["columns"])

    [id_col, status_col] = decoded["columns"]

    # The status column carries the new keys verbatim.
    assert status_col["enum_variants"] == ["a", "b", "c"]
    assert status_col["default_value"] == 3
    assert status_col["default_expr"] == "uuid"

    assert get_in(decoded, ["constraints", "checks", Access.at(0), "name"]) ==
             "known_status"

    # Wire-shape guarantee: the keys must appear in the exact textual form
    # the daemon's Kit API documents. Bypass Elixir map literal printing.
    assert body =~ ~s("enum_variants":["a","b","c"])
    assert body =~ ~s("default_value":3)
    assert body =~ ~s("default_expr":"uuid")
    assert body =~ ~s("constraints":{"checks":[)

    # The id column is NOT polluted by the new keys.
    refute Map.has_key?(id_col, "enum_variants")
    refute Map.has_key?(id_col, "default_value")
  end

  test "create_table omits enum_variants and default_value when unset (regression)",
       %{server: server} do
    db = MongrelDB.connect("http://127.0.0.1:#{server.port}")

    assert {:ok, 0} =
             MongrelDB.create_table(db, "orders", [
               %{
                 "id" => 1,
                 "name" => "id",
                 "ty" => "int64",
                 "primary_key" => true,
                 "nullable" => false
               },
               %{
                 "id" => 2,
                 "name" => "label",
                 "ty" => "varchar",
                 "primary_key" => false,
                 "nullable" => false
               }
             ])

    assert_receive {:http_capture, body}, 1_000
    {:ok, decoded} = JSON.decode(body)

    # No enum_variants or default_value key on any column, in either the
    # decoded map or the raw wire text. Guards against accidental key
    # injection if `MongrelDB.create_table/3` ever gains normalization.
    Enum.each(decoded["columns"], fn col ->
      refute Map.has_key?(col, "enum_variants")
      refute Map.has_key?(col, "default_value")
    end)

    refute body =~ "enum_variants"
    refute body =~ "default_value"
  end

  test "history retention uses exact method, path, and body shape" do
    server = start_history_capture!()
    on_exit(fn -> stop_http_capture(server) end)
    db = MongrelDB.connect("http://127.0.0.1:#{server.port}")

    assert {:ok, 10} = MongrelDB.history_retention_epochs(db)

    assert_receive {:history_capture, "GET", "/history/retention", ""}, 1_000

    assert {:ok, 3} = MongrelDB.earliest_retained_epoch(db)
    assert_receive {:history_capture, "GET", "/history/retention", ""}, 1_000

    assert {:ok, 20} = MongrelDB.set_history_retention_epochs(db, 20)

    assert_receive {:history_capture, "PUT", "/history/retention", body}, 1_000
    assert {:ok, %{"history_retention_epochs" => 20}} = JSON.decode(body)
  end

  test "history retention propagates 403 as AuthException" do
    server = start_history_capture!(403, ~s({"error":{"message":"forbidden"}}))
    on_exit(fn -> stop_http_capture(server) end)
    db = MongrelDB.connect("http://127.0.0.1:#{server.port}")

    assert {:error, %MongrelDB.AuthException{}} = MongrelDB.history_retention_epochs(db)
    assert {:error, %MongrelDB.AuthException{}} = MongrelDB.earliest_retained_epoch(db)

    assert {:error, %MongrelDB.AuthException{}} = MongrelDB.set_history_retention_epochs(db, 5)
  end

  test "history retention rejects malformed 2xx responses" do
    for body <- [
          ~s({"unexpected": 1}),
          ~s({"history_retention_epochs": -1, "earliest_retained_epoch": 0}),
          ~s({"history_retention_epochs": "100", "earliest_retained_epoch": 0}),
          ~s({"history_retention_epochs": 100}),
          ~s({"history_retention_epochs": 100, "earliest_retained_epoch": 0, "extra": true})
        ] do
      server = start_history_capture!(200, body)
      on_exit(fn -> stop_http_capture(server) end)
      db = MongrelDB.connect("http://127.0.0.1:#{server.port}")

      assert {:error, %MongrelDB.QueryException{}} = MongrelDB.history_retention_epochs(db)
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Boots a single-shot HTTP listener on 127.0.0.1:<random> that captures the
  # raw request body of each POST and replies with a canned 200 OK + JSON
  # {"table_id": 0}. Implemented with :gen_tcp only; no Hex deps.
  #
  # Each accepted connection is handed off to a worker process via
  # :gen_tcp.controlling_process/2 so the worker's :inet.setopts and recv
  # messages are routed to the right mailbox (the controlling process is
  # set at accept time, and active-mode TCP messages only go there).
  defp start_http_capture! do
    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        packet: :raw,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(lsock)
    parent = self()
    pid = spawn_link(fn -> accept_loop(lsock, parent) end)
    %{socket: lsock, pid: pid, port: port}
  end

  defp stop_http_capture(%{socket: lsock, pid: pid}) do
    Process.exit(pid, :kill)
    _ = :gen_tcp.close(lsock)
    :ok
  end

  defp accept_loop(lsock, parent) do
    send(parent, {:debug_accept_waiting, self()})

    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        send(parent, {:debug_accept_returned, self()})
        # Handle the request synchronously in this loop process; the test
        # only issues a handful of requests, so blocking accept is fine.
        # Doing it here avoids the controlling-process handoff dance that
        # would otherwise be required for active-mode messages.
        serve(sock, parent)
        accept_loop(lsock, parent)

      {:error, reason} ->
        send(parent, {:debug_accept_error, reason})
        :ok
    end
  end

  defp serve(sock, parent) do
    send(parent, {:debug_serve_called, self()})

    case read_request(sock) do
      {:ok, _method, _path, body} ->
        send(parent, {:http_capture, body})
        _ = send_response(sock, 200, ~s({"table_id":0}))

      {:error, reason} ->
        send(parent, {:http_capture_error, reason})
    end

    :gen_tcp.close(sock)
  end

  # Reads the HTTP request line, headers, and body off the socket. Robust to
  # partial reads by accumulating until both the header terminator and the
  # full Content-Length payload are in hand. Returns {method, path, body} so
  # path- and method-sensitive tests can assert on the wire shape.
  defp read_request(sock) do
    case recv_until(sock, "\r\n\r\n", 16) do
      {:ok, head} ->
        [request_line | _] = String.split(head, "\r\n", parts: 2)
        [method, path, _version] = String.split(request_line, " ", parts: 3)
        [head_only, body_so_far] = String.split(head, "\r\n\r\n", parts: 2)
        content_length = content_length_from_headers(head_only)

        case read_body(sock, max(content_length - byte_size(body_so_far), 0), body_so_far) do
          {:ok, body} -> {:ok, method, path, body}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp read_body(_sock, 0, acc), do: {:ok, acc}

  defp read_body(sock, remaining, acc) do
    case :gen_tcp.recv(sock, remaining, 5_000) do
      {:ok, chunk} ->
        read_body(sock, max(remaining - byte_size(chunk), 0), acc <> chunk)

      {:error, _} = err ->
        err
    end
  end

  defp recv_until(sock, terminator, max_iters) do
    recv_until(sock, terminator, "", 0, max_iters)
  end

  defp recv_until(_sock, _terminator, acc, iter, max_iters) when iter >= max_iters,
    do: {:ok, acc}

  defp recv_until(sock, terminator, acc, iter, max_iters) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        if String.contains?(acc, terminator) do
          {:ok, acc}
        else
          recv_until(sock, terminator, acc, iter + 1, max_iters)
        end

      {:error, _} = err ->
        err
    end
  end

  defp content_length_from_headers(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, &content_length/1)
  end

  defp content_length(line) do
    case String.split(line, ": ", parts: 2) do
      [k, v] when k in ["Content-Length", "content-length"] -> String.to_integer(v)
      _ -> nil
    end
  end

  defp send_response(sock, status, body) do
    status_line =
      case status do
        200 -> "HTTP/1.1 200 OK"
        403 -> "HTTP/1.1 403 Forbidden"
        _ -> "HTTP/1.1 #{status}"
      end

    response =
      status_line <>
        "\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    :gen_tcp.send(sock, response)
  end

  # Boots a tiny HTTP listener that mimics the daemon's /history/retention
  # endpoints. Captures {method, path, body} as :history_capture messages so
  # the retention tests can assert exact wire shape without a running server.
  defp start_history_capture!(
         status \\ 200,
         body \\ ~s({"history_retention_epochs":10,"earliest_retained_epoch":3})
       ) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        packet: :raw,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(lsock)
    parent = self()
    pid = spawn_link(fn -> history_accept_loop(lsock, parent, status, body) end)
    %{socket: lsock, pid: pid, port: port}
  end

  defp history_accept_loop(lsock, parent, status, body) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        history_serve(sock, parent, status, body)
        history_accept_loop(lsock, parent, status, body)

      {:error, _reason} ->
        :ok
    end
  end

  defp history_serve(sock, parent, status, body) do
    case read_request(sock) do
      {:ok, method, path, req_body} ->
        send(parent, {:history_capture, method, path, req_body})
        response_body = retention_response_body(method, status, req_body, body)
        _ = send_response(sock, status, response_body)

      {:error, reason} ->
        send(parent, {:history_capture_error, reason})
    end

    :gen_tcp.close(sock)
  end

  # For successful PUTs, mirror the requested history_retention_epochs back so
  # the typed setter can validate the daemon-confirmed value.
  defp retention_response_body("PUT", 200, req_body, default_body) do
    with {:ok, decoded} <- JSON.decode(req_body),
         epochs when is_integer(epochs) and epochs >= 0 <- decoded["history_retention_epochs"],
         {:ok, default} <- JSON.decode(default_body),
         earliest when is_integer(earliest) and earliest >= 0 <-
           default["earliest_retained_epoch"] do
      ~s({"history_retention_epochs":#{epochs},"earliest_retained_epoch":#{earliest}})
    else
      _ -> default_body
    end
  end

  defp retention_response_body(_method, _status, _req_body, default_body), do: default_body

  defp receive_capture do
    receive do
      {:http_capture, body} -> body
    after
      2_000 ->
        flunk(
          "no http_capture message received; diag: #{inspect(:erlang.process_info(self(), :messages))}"
        )
    end
  end

  defp col_by_name(columns, name) do
    Enum.find(columns, fn col -> col["name"] == name end)
  end
end
