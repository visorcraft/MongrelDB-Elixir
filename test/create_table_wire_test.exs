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

  setup_all do
    server = start_http_capture!()
    on_exit(fn -> stop_http_capture(server) end)
    {:ok, server: server}
  end

  test "create_table forwards enum_variants and default_value on the column map",
       %{server: server} do
    IO.puts("TEST port=#{server.port}")

    # Verify the listener accepts raw TCP before exercising :httpc.
    case :gen_tcp.connect(~c"127.0.0.1", server.port, [:binary, active: false]) do
      {:ok, c} ->
        :gen_tcp.close(c)
        IO.puts("TEST raw connect OK")

      err ->
        IO.puts("TEST raw connect FAILED: #{inspect(err)}")
    end

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
                 "name" => "status",
                 "ty" => "varchar",
                 "primary_key" => false,
                 "nullable" => false,
                 "enum_variants" => ["a", "b", "c"],
                 "default_value" => "a"
               }
             ])

    drain_diagnostics()
    body = receive_capture()
    {:ok, decoded} = JSON.decode(body)

    assert decoded["name"] == "orders"
    assert is_list(decoded["columns"])

    [id_col, status_col] = decoded["columns"]

    # The status column carries the new keys verbatim.
    assert status_col["enum_variants"] == ["a", "b", "c"]
    assert status_col["default_value"] == "a"

    # Wire-shape guarantee: the keys must appear in the exact textual form
    # the daemon's Kit API documents. Bypass Elixir map literal printing.
    assert body =~ ~s("enum_variants":["a","b","c"])
    assert body =~ ~s("default_value":"a")

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

    drain_diagnostics()
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
      {:ok, body} ->
        send(parent, {:http_capture, body})
        _ = send_200(sock)

      {:error, reason} ->
        send(parent, {:http_capture_error, reason})
    end

    :gen_tcp.close(sock)
  end

  # Reads the HTTP request line, headers, and body off the socket. Robust to
  # partial reads by accumulating until both the header terminator and the
  # full Content-Length payload are in hand.
  defp read_request(sock) do
    case recv_until(sock, "\r\n\r\n", 16) do
      {:ok, head} ->
        [head_only, body_so_far] = String.split(head, "\r\n\r\n", parts: 2)
        content_length = content_length_from_headers(head_only)
        read_body(sock, content_length, body_so_far)

      {:error, _} = err ->
        err
    end
  end

  defp read_body(_sock, 0, acc), do: {:ok, acc}

  defp read_body(sock, remaining, acc) do
    case :gen_tcp.recv(sock, remaining, 5_000) do
      {:ok, chunk} -> {:ok, acc <> chunk}
      {:error, _} = err -> err
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

        if String.ends_with?(acc, terminator) do
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
    |> Enum.find_value(0, fn line ->
      case String.split(line, ": ", parts: 2) do
        [k, v] ->
          if String.downcase(k) == "content-length", do: String.to_integer(v), else: nil

        _ ->
          nil
      end
    end)
  end

  defp send_200(sock) do
    response_body = ~s({"table_id":0})
    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(response_body)}\r\n" <>
        "Connection: close\r\n\r\n" <> response_body

    :gen_tcp.send(sock, response)
  end

  defp drain_diagnostics do
    receive do
      msg ->
        IO.inspect(msg, label: "diag")
        drain_diagnostics()
    after
      50 -> :ok
    end
  end

  defp receive_capture do
    receive do
      {:http_capture, body} -> body
    after
      2_000 -> flunk("no http_capture message received; diag: #{inspect(:erlang.process_info(self(), :messages))}")
    end
  end
end