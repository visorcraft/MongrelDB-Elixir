defmodule MongrelDB.JSON do
  @moduledoc """
  Minimal JSON encoder/decoder.

  MongrelDB talks JSON, and the client promises no external runtime
  dependencies. Elixir gained a stdlib `JSON` module in 1.18, but to support
  1.14+ this module ships a small, dependency-free encoder and decoder.

  The encoder rejects NaN and Infinity (no valid JSON representation) by
  raising `ArgumentError`; `encode/1` catches that and returns
  `{:error, reason}`. The decoder accepts the daemon's responses: objects,
  arrays, strings, numbers, booleans, and null.
  """

  # -- Encoding --------------------------------------------------------------

  @doc "Encode an Elixir term to a JSON binary."
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    {:ok, IO.iodata_to_binary(do_encode(value))}
  rescue
    e in [ArgumentError] ->
      {:error, Exception.message(e)}
  end

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"

  defp do_encode(n) when is_integer(n), do: Integer.to_string(n)

  defp do_encode(n) when is_float(n) do
    # credo:disable-for-next-line Credo.Check.Warning.OperationOnSameValues
    if n != n do
      raise ArgumentError, "cannot JSON-encode NaN"
    else
      :erlang.float_to_binary(n, [:compact, {:decimals, 17}])
    end
  end

  defp do_encode(s) when is_binary(s) do
    [?", encode_string(s), ?"]
  end

  defp do_encode(list) when is_list(list) do
    inner =
      list
      |> Enum.map_join(",", &do_encode/1)

    ["[", inner, "]"]
  end

  defp do_encode(%{__struct__: _} = struct) do
    raise ArgumentError,
          "cannot JSON-encode struct #{inspect(struct.__struct__)}"
  end

  defp do_encode(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} ->
        # Keys must be JSON strings: "key":value. encode_string/1 only
        # escapes content, so the surrounding quotes are added here.
        [?", encode_string(to_string(k)), "\":", do_encode(v)]
      end)

    ["{", inner, "}"]
  end

  defp do_encode(other) do
    raise ArgumentError, "cannot JSON-encode value #{inspect(other)}"
  end

  defp encode_string(s) do
    s
    |> :binary.bin_to_list()
    |> Enum.reduce([], fn byte, acc -> [escape_byte(byte) | acc] end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp escape_byte(0x22), do: "\\\""
  defp escape_byte(0x5C), do: "\\\\"
  defp escape_byte(0x0A), do: "\\n"
  defp escape_byte(0x0D), do: "\\r"
  defp escape_byte(0x09), do: "\\t"
  defp escape_byte(0x08), do: "\\b"
  defp escape_byte(0x0C), do: "\\f"
  defp escape_byte(b) when b < 0x20, do: :io_lib.format("\\u~4.16.0b", [b])
  defp escape_byte(b), do: <<b>>

  # -- Decoding --------------------------------------------------------------

  @doc "Decode a JSON binary into an Elixir term."
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case decode_value(binary, 0) do
      {:ok, value, _pos} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp decode_value(s, pos) do
    pos = skip_ws(s, pos)

    if pos >= byte_size(s) do
      {:error, "unexpected end of input"}
    else
      dispatch_value(s, pos, :binary.at(s, pos))
    end
  end

  defp dispatch_value(s, pos, c) when c == ?- or (c >= ?0 and c <= ?9),
    do: decode_number(s, pos)

  defp dispatch_value(s, pos, ?{), do: decode_object(s, pos + 1)
  defp dispatch_value(s, pos, ?[), do: decode_array(s, pos + 1)
  defp dispatch_value(s, pos, ?"), do: decode_string(s, pos + 1)
  defp dispatch_value(s, pos, ?t), do: decode_literal(s, pos, "true", true)
  defp dispatch_value(s, pos, ?f), do: decode_literal(s, pos, "false", false)
  defp dispatch_value(s, pos, ?n), do: decode_literal(s, pos, "null", nil)
  defp dispatch_value(_s, pos, _c), do: {:error, "unexpected character at position #{pos}"}

  defp skip_ws(s, pos) do
    if pos < byte_size(s) do
      case :binary.at(s, pos) do
        ws when ws in [?\s, ?\t, ?\n, ?\r] -> skip_ws(s, pos + 1)
        _ -> pos
      end
    else
      pos
    end
  end

  defp decode_object(s, pos) do
    pos = skip_ws(s, pos)

    if pos < byte_size(s) and :binary.at(s, pos) == ?} do
      {:ok, %{}, pos + 1}
    else
      decode_object_members(s, pos, %{})
    end
  end

  defp decode_object_members(s, pos, acc) do
    # The key starts with a double quote; decode_string_raw expects to be
    # positioned just past it (it scans until the closing quote).
    with :ok <- expect_open_quote(s, pos),
         {:ok, key, pos} <- decode_string_raw(s, pos + 1),
         :ok <- expect_colon(s, skip_ws(s, pos)),
         {:ok, value, pos} <- decode_value(s, skip_ws(s, pos + 1)) do
      consume_object_separator(s, skip_ws(s, pos), Map.put(acc, key, value))
    end
  end

  defp expect_open_quote(s, pos) do
    if pos < byte_size(s) and :binary.at(s, pos) == ?" do
      :ok
    else
      {:error, "expected string key in object at #{pos}"}
    end
  end

  defp expect_colon(s, pos) do
    if pos < byte_size(s) and :binary.at(s, pos) == ?: do
      :ok
    else
      {:error, "expected ':' in object at #{pos}"}
    end
  end

  defp consume_object_separator(s, pos, acc) do
    if pos >= byte_size(s) do
      {:error, "unexpected end of object"}
    else
      case :binary.at(s, pos) do
        ?} -> {:ok, acc, pos + 1}
        ?, -> decode_object_members(s, skip_ws(s, pos + 1), acc)
        _ -> {:error, "expected ',' or '}' in object at #{pos}"}
      end
    end
  end

  defp decode_array(s, pos) do
    pos = skip_ws(s, pos)

    if pos < byte_size(s) and :binary.at(s, pos) == ?] do
      {:ok, [], pos + 1}
    else
      decode_array_elements(s, pos, [])
    end
  end

  defp decode_array_elements(s, pos, acc) do
    case decode_value(s, pos) do
      {:ok, value, pos} ->
        pos = skip_ws(s, pos)
        consume_array_separator(s, pos, acc ++ [value])

      {:error, _} = err ->
        err
    end
  end

  defp consume_array_separator(s, pos, acc) do
    if pos >= byte_size(s) do
      {:error, "unexpected end of array"}
    else
      case :binary.at(s, pos) do
        ?] -> {:ok, acc, pos + 1}
        ?, -> decode_array_elements(s, skip_ws(s, pos + 1), acc)
        _ -> {:error, "expected ',' or ']' in array at #{pos}"}
      end
    end
  end

  defp decode_string(s, pos), do: decode_string_raw(s, pos)

  defp decode_string_raw(s, pos) do
    decode_string_chars(s, pos, [])
  end

  defp decode_string_chars(s, pos, acc) do
    cond do
      pos >= byte_size(s) ->
        {:error, "unterminated string"}

      :binary.at(s, pos) == ?" ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc)), pos + 1}

      :binary.at(s, pos) == ?\\ ->
        decode_escape(s, pos, acc)

      true ->
        decode_string_chars(s, pos + 1, [<<:binary.at(s, pos)>> | acc])
    end
  end

  @escape_chars %{
    ?" => ?",
    ?\\ => ?\\,
    ?/ => ?/,
    ?n => ?\n,
    ?r => ?\r,
    ?t => ?\t,
    ?b => ?\b,
    ?f => ?\f
  }

  defp decode_escape(s, pos, acc) do
    if pos + 1 >= byte_size(s) do
      {:error, "unterminated escape"}
    else
      decode_escape_char(s, pos, acc, :binary.at(s, pos + 1))
    end
  end

  defp decode_escape_char(s, pos, acc, ?u), do: decode_unicode_escape(s, pos, acc)

  defp decode_escape_char(s, pos, acc, c) when is_map_key(@escape_chars, c) do
    decode_string_chars(s, pos + 2, [<<@escape_chars[c]>> | acc])
  end

  defp decode_escape_char(_s, pos, _acc, other),
    do: {:error, "invalid escape \\#{<<other>>} at #{pos}"}

  defp decode_unicode_escape(s, pos, acc) do
    if pos + 5 >= byte_size(s) do
      {:error, "truncated \\u escape"}
    else
      <<_::binary-size(^pos), ?u, hex::binary-size(4), _rest::binary>> = s
      cp = String.to_integer(hex, 16)
      decode_string_chars(s, pos + 6, [<<cp::utf8>> | acc])
    end
  end

  defp decode_literal(s, pos, literal, value) do
    len = byte_size(literal)

    if pos + len <= byte_size(s) and :binary.part(s, pos, len) == literal do
      {:ok, value, pos + len}
    else
      {:error, "invalid literal at position #{pos}"}
    end
  end

  defp decode_number(s, pos) do
    {digits, rest_pos} = collect_number(s, pos, [])
    digit_string = IO.iodata_to_binary(Enum.reverse(digits))

    if String.contains?(digit_string, ".") or
         String.contains?(digit_string, "e") or
         String.contains?(digit_string, "E") do
      case Float.parse(digit_string) do
        {n, ""} -> {:ok, n, rest_pos}
        _ -> {:error, "invalid number at position #{pos}"}
      end
    else
      case Integer.parse(digit_string) do
        {n, ""} -> {:ok, n, rest_pos}
        _ -> {:error, "invalid number at position #{pos}"}
      end
    end
  end

  defp collect_number(s, pos, acc) do
    if pos >= byte_size(s) do
      {acc, pos}
    else
      case :binary.at(s, pos) do
        c when c in [?-, ?+, ?., ?e, ?E] -> collect_number(s, pos + 1, [c | acc])
        c when c >= ?0 and c <= ?9 -> collect_number(s, pos + 1, [c | acc])
        _ -> {acc, pos}
      end
    end
  end
end
