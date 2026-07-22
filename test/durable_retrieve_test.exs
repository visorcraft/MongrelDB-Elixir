defmodule MongrelDB.DurableRetrieveTest do
  use ExUnit.Case, async: true

  alias MongrelDB.{CommitHlc, QueryStatus, SearchBuilder}

  @fixture %{
    "query_id" => "abcdefabcdefabcdefabcdefabcdefab",
    "status" => "committed",
    "state" => "completed",
    "server_state" => "completed",
    "terminal_state" => "committed",
    "operation" => "INSERT",
    "committed" => true,
    "committed_statements" => 1,
    "last_commit_epoch" => 17,
    "last_commit_epoch_text" => "17",
    "last_commit_hlc" => %{
      "physical_micros" => 1_700_000_000_000_000,
      "logical" => 3,
      "node_tiebreaker" => 7
    },
    "first_commit_statement_index" => 0,
    "last_commit_statement_index" => 0,
    "completed_statements" => 1,
    "statement_index" => 0,
    "cancel_outcome" => nil,
    "cancellation_reason" => "none",
    "retryable" => false,
    "outcome" => %{
      "committed" => true,
      "committed_statements" => 1,
      "last_commit_epoch" => 17,
      "last_commit_epoch_text" => "17",
      "last_commit_hlc" => %{
        "physical_micros" => 1_700_000_000_000_000,
        "logical" => 3,
        "node_tiebreaker" => 7
      },
      "first_commit_statement_index" => 0,
      "last_commit_statement_index" => 0,
      "completed_statements" => 1,
      "statement_index" => 0,
      "serialization" => "succeeded",
      "serialization_state" => "succeeded",
      "terminal_state" => "committed"
    },
    "durable" => %{
      "committed" => true,
      "committed_statements" => 1,
      "last_commit_epoch" => 17,
      "last_commit_epoch_text" => "17",
      "last_commit_hlc" => %{
        "physical_micros" => 1_700_000_000_000_000,
        "logical" => 3,
        "node_tiebreaker" => 7
      },
      "first_commit_statement_index" => 0,
      "last_commit_statement_index" => 0,
      "completed_statements" => 1,
      "statement_index" => 0,
      "serialization" => "succeeded",
      "serialization_state" => "succeeded",
      "terminal_state" => "committed"
    },
    "terminal_error" => nil
  }

  test "query_status parses structural HLC without string-status parsing" do
    status = QueryStatus.from_map(@fixture)

    assert status.committed == true
    assert status.query_id == "abcdefabcdefabcdefabcdefabcdefab"
    assert status.status == "committed"

    hlc = QueryStatus.commit_hlc(status)
    assert %CommitHlc{} = hlc
    assert hlc.physical_micros == 1_700_000_000_000_000
    assert hlc.logical == 3
    assert hlc.node_tiebreaker == 7

    assert QueryStatus.serialization_state(status) == "succeeded"
    # Structural access — no string-parsing of free-form status text.
    assert status.outcome.last_commit_epoch == 17
    assert status.durable.last_commit_hlc.physical_micros == 1_700_000_000_000_000
  end

  test "commit_hlc prefers durable over outcome over top-level" do
    fixture = %{
      "last_commit_hlc" => %{
        "physical_micros" => 1,
        "logical" => 0,
        "node_tiebreaker" => 0
      },
      "outcome" => %{
        "last_commit_hlc" => %{
          "physical_micros" => 2,
          "logical" => 0,
          "node_tiebreaker" => 0
        },
        "serialization" => "from_outcome"
      },
      "durable" => %{
        "last_commit_hlc" => %{
          "physical_micros" => 3,
          "logical" => 1,
          "node_tiebreaker" => 2
        },
        "serialization_state" => "from_durable"
      }
    }

    status = QueryStatus.from_map(fixture)
    assert QueryStatus.commit_hlc(status).physical_micros == 3
    assert QueryStatus.serialization_state(status) == "from_durable"
  end

  test "build_retrieve_text_request shapes POST /kit/retrieve_text body" do
    assert {:ok, payload} =
             MongrelDB.build_retrieve_text_request("docs", 3, "cat sat", k: 5)

    assert payload["table"] == "docs"
    assert payload["embedding_column"] == 3
    assert payload["text"] == "cat sat"
    assert payload["k"] == 5

    # Round-trip through the JSON encoder used by the HTTP client.
    assert {:ok, json} = MongrelDB.JSON.encode(payload)
    assert {:ok, decoded} = MongrelDB.JSON.decode(json)
    assert decoded["embedding_column"] == 3

    assert {:error, %MongrelDB.QueryException{}} =
             MongrelDB.build_retrieve_text_request("", 3, "x")

    assert {:error, %MongrelDB.QueryException{}} =
             MongrelDB.build_retrieve_text_request("docs", 3, "")
  end

  test "multi-retriever SearchBuilder wire includes two retrievers and fusion" do
    db = MongrelDB.connect("http://127.0.0.1:9")

    payload =
      MongrelDB.search(db, "docs")
      |> SearchBuilder.ann_retriever("ann", 3, [0.1, 0.2], k: 10, weight: 1.0)
      |> SearchBuilder.sparse_retriever("sparse", 4, [{1, 0.5}, {2, 0.25}], k: 10, weight: 0.5)
      |> SearchBuilder.fusion(60)
      |> SearchBuilder.limit(5)
      |> SearchBuilder.build()

    assert length(payload["retrievers"]) == 2
    assert Map.has_key?(payload, "fusion")
    assert payload["limit"] == 5
    assert get_in(payload, ["fusion", "reciprocal_rank", "constant"]) == 60
  end
end
