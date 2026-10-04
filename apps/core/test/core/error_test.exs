defmodule PhotonCore.LLM.ErrorTest do
  use PhotonCore.Case, async: true

  test "can be raised like any exception" do
    assert_raise Error, "HTTP 503: down", fn ->
      raise Error, kind: :http, status: 503, message: "down"
    end
  end

  describe "new/3" do
    test "takes a kind and a message, and defaults to not retryable" do
      assert %Error{kind: :config, message: "no model", retryable: false, status: nil} =
               Error.new(:config, "no model")
    end

    test "sets the other fields it's given" do
      assert %Error{status: 429, retryable: true, retry_after: 1_000} =
               Error.new(:http, "slow down", status: 429, retryable: true, retry_after: 1_000)
    end

    test "rejects a field the error doesn't have" do
      assert_raise KeyError, fn -> Error.new(:http, "x", color: :red) end
    end
  end

  describe "message/1 and to_map/1" do
    test "the message names the status when there is one" do
      assert Exception.message(Error.new(:transport, "closed")) == "closed"

      assert Exception.message(Error.new(:http, "slow down", status: 429)) ==
               "HTTP 429: slow down"
    end

    test "to_map is a JSON-friendly summary" do
      assert Error.to_map(Error.new(:http, "slow down", status: 429)) ==
               %{"kind" => "http", "status" => 429, "message" => "HTTP 429: slow down"}
    end
  end
end
