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
    {:ok, do_encode(value)}
  rescue
    e in [ArgumentError] ->
      {:error, Exception.message(e)}
  end

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"

  defp do_encode(n) when is_integer(n), do: Integer.to_string(n)

  defp do_encode(n) when is_float(n) do
    cond do
      n != n ->
        raise ArgumentError, "cannot JSON-encode NaN"

      n == :infinity or n == :negative_infinity ->
        raise ArgumentError, "cannot JSON-encode Infinity"

      true ->
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
        [encode_string(to_string(k)), ":", do_encode(v)]
      end)

    ["{", inner, "}"]
  end

  defp do_encode(other) do
    raise ArgumentError, "cannot JSON-encode value #{inspect(other)}"
  end

  defp encode_string(s) do
    chars =
      for <<byte <- s>>, reduce: [] do
        acc ->
          case byte do
            0x22 -> ['\\"' | acc]
            0x5C -> ['\\\\' | acc]
            0x0A -> ['\\n' | acc]
            0x0D -> ['\\r' | acc]
            0x09 -> ['\\t' | acc]
            0x08 -> ['\\b' | acc]
            0x0C -> ['\\f' | acc]
            b when b < 0x20 -> [:io_lib.format("\\u~4.16.0b", [b]) | acc]
            b -> [<<b>> | acc]
          end
      end

    chars |> Enum.reverse() |> IO.iodata_to_binary()
  end

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
      case :binary.at(s, pos) do
        ?{ -> decode_object(s, pos + 1)
        ?[ -> decode_array(s, pos + 1)
        ?" -> decode_string(s, pos + 1)
        ?t -> decode_literal(s, pos, "true", true)
        ?f -> decode_literal(s, pos, "false", false)
        ?n -> decode_literal(s, pos, "null", nil)
        c when c == ?- or (c >= ?0 and c <= ?9) -> decode_number(s, pos)
        _ -> {:error, "unexpected character at position #{pos}"}
      end
    end
  end

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
    with {:ok, key, pos} <- decode_string_raw(s, pos),
         pos = skip_ws(s, pos),
         :ok <- expect_colon(s, pos),
         {:ok, value, pos} <- decode_value(s, skip_ws(s, pos + 1)),
         pos = skip_ws(s, pos),
         {:ok, acc, pos} <- consume_object_separator(s, pos, Map.put(acc, key, value)) do
      {:ok, acc, pos}
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
    with {:ok, value, pos} <- decode_value(s, pos),
         pos = skip_ws(s, pos) do
      consume_array_separator(s, pos, acc ++ [value])
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

  defp decode_string(s, pos) do
    with {:ok, str, pos} <- decode_string_raw(s, pos) do
      {:ok, str, pos}
    end
  end

  defp decode_string_raw(s, pos) do
    decode_string_chars(s, pos, [])
  end

  defp decode_string_chars(s, pos, acc) do
    if pos >= byte_size(s) do
      {:error, "unterminated string"}
    else
      case :binary.at(s, pos) do
        ?" ->
          {:ok, IO.iodata_to_binary(Enum.reverse(acc)), pos + 1}

        ?\\ ->
          if pos + 1 >= byte_size(s) do
            {:error, "unterminated escape"}
          else
            case :binary.at(s, pos + 1) do
              ?" ->
                decode_string_chars(s, pos + 2, [?" | acc])

              ?\\ ->
                decode_string_chars(s, pos + 2, [?\\ | acc])

              ?/ ->
                decode_string_chars(s, pos + 2, [?/ | acc])

              ?n ->
                decode_string_chars(s, pos + 2, ["\n" | acc])

              ?r ->
                decode_string_chars(s, pos + 2, ["\r" | acc])

              ?t ->
                decode_string_chars(s, pos + 2, ["\t" | acc])

              ?b ->
                decode_string_chars(s, pos + 2, ["\b" | acc])

              ?f ->
                decode_string_chars(s, pos + 2, ["\f" | acc])

              ?u ->
                if pos + 5 >= byte_size(s) do
                  {:error, "truncated \\u escape"}
                else
                  <<_::binary-size(pos), ?u, hex::binary-size(4), _rest::binary>> = s
                  cp = String.to_integer(hex, 16)
                  decode_string_chars(s, pos + 6, [<<cp::utf8>> | acc])
                end

              other ->
                {:error, "invalid escape \\#{<<other>>} at #{pos}"}
            end
          end

        byte ->
          decode_string_chars(s, pos + 1, [<<byte>> | acc])
      end
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

    cond do
      String.contains?(digit_string, ".") or
        String.contains?(digit_string, "e") or
          String.contains?(digit_string, "E") ->
        case Float.parse(digit_string) do
          {n, ""} -> {:ok, n, rest_pos}
          _ -> {:error, "invalid number at position #{pos}"}
        end

      true ->
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
