defmodule MongrelDB.JSONTest do
  use ExUnit.Case, async: true

  alias MongrelDB.JSON

  describe "encode/1" do
    test "encodes a string" do
      assert {:ok, "\"hello\""} = JSON.encode("hello")
    end

    test "escapes quotes and control characters" do
      assert {:ok, "\"a\\\"b\\nc\""} = JSON.encode("a\"b\nc")
    end

    test "encodes an integer" do
      assert {:ok, "42"} = JSON.encode(42)
    end

    test "encodes a float" do
      assert {:ok, json} = JSON.encode(3.14)
      assert json =~ "3.14"
    end

    test "encodes booleans" do
      assert {:ok, "true"} = JSON.encode(true)
      assert {:ok, "false"} = JSON.encode(false)
    end

    test "encodes nil" do
      assert {:ok, "null"} = JSON.encode(nil)
    end

    test "encodes a list" do
      assert {:ok, json} = JSON.encode([1, 2, 3])
      assert json == "[1,2,3]"
    end

    test "encodes a map" do
      assert {:ok, json} = JSON.encode(%{"a" => 1})
      assert json == "{\"a\":1}"
    end

    test "encodes an empty map as an object" do
      assert {:ok, "{}"} = JSON.encode(%{})
    end

    test "rejects NaN" do
      nan = :math.sqrt(-1)
      assert {:error, _} = JSON.encode(nan)
    end

    test "rejects Infinity" do
      assert {:error, _} = JSON.encode(:math.pow(10, 1000))
    end
  end

  describe "decode/1" do
    test "decodes a string" do
      assert {:ok, "hi"} = JSON.decode("\"hi\"")
    end

    test "decodes a number" do
      assert {:ok, 3.14} = JSON.decode("3.14")
    end

    test "decodes an integer" do
      assert {:ok, 42} = JSON.decode("42")
    end

    test "decodes an array" do
      assert {:ok, [1, 2, 3]} = JSON.decode("[1,2,3]")
    end

    test "decodes an object" do
      assert {:ok, %{"a" => 1, "b" => 2}} = JSON.decode("{\"a\":1,\"b\":2}")
    end

    test "decodes nested structures" do
      assert {:ok, %{"a" => [1, 2]}} = JSON.decode("{\"a\":[1,2]}")
    end

    test "decodes null" do
      assert {:ok, %{"a" => nil}} = JSON.decode("{\"a\":null}")
    end

    test "decodes booleans" do
      assert {:ok, true} = JSON.decode("true")
      assert {:ok, false} = JSON.decode("false")
    end

    test "tolerates surrounding whitespace" do
      assert {:ok, %{"a" => 1}} = JSON.decode("  {\"a\": 1}  ")
    end

    test "decodes escaped characters in strings" do
      assert {:ok, "line1\nline2"} = JSON.decode("\"line1\\nline2\"")
      assert {:ok, "quote\"end"} = JSON.decode("\"quote\\\"end\"")
    end
  end

  describe "roundtrip" do
    test "object roundtrips through encode then decode" do
      original = %{"id" => 1, "name" => "Alice", "active" => true}
      {:ok, json} = JSON.encode(original)
      {:ok, decoded} = JSON.decode(json)
      assert decoded == original
    end

    test "array roundtrips through encode then decode" do
      original = [1, "two", false, nil]
      {:ok, json} = JSON.encode(original)
      {:ok, decoded} = JSON.decode(json)
      assert decoded == original
    end
  end
end
