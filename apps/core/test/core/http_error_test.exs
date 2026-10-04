defmodule PhotonCore.HTTPErrorTest do
  @moduledoc "Failed requests, read into errors."

  use PhotonCore.Case, async: true

  test "keeps the API's message and status" do
    error = HTTPError.from_response(400, ~s({"error":{"message":"bad input"}}), [])
    assert %Error{kind: :http, status: 400, message: "bad input", retryable: false} = error
  end

  test "rate limits and server errors are retryable, with the API's wait" do
    assert %Error{retryable: true, retry_after: 3000} =
             HTTPError.from_response(429, ~s({"error":{"message":"slow"}}), ["3"])

    assert %Error{retryable: true, retry_after: nil} = HTTPError.from_response(503, "", ["soon"])
  end

  test "ignores a negative retry-after, which no wait can honor" do
    assert %Error{retryable: true, retry_after: nil} = HTTPError.from_response(429, "", ["-3"])
  end

  test "a spent plan isn't retryable, whatever the status says" do
    for code <-
          ~w(subscription_sharing_usage_limit_exceeded insufficient_quota usage_limit_reached) do
      body = Jason.encode!(%{"error" => %{"code" => code, "message" => "limit"}})
      assert %Error{retryable: false} = HTTPError.from_response(429, body, [])
    end
  end

  test "ChatGPT's own codes are said plainly" do
    limit = ~s({"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}})
    assert HTTPError.from_response(429, limit, []).message =~ "chatgpt.com/settings/usage"

    ineligible = ~s({"error":{"code":"subscription_sharing_user_not_eligible","message":"x"}})
    assert HTTPError.from_response(403, ineligible, []).message =~ "can't be used in other apps"
  end

  test "an error sent as a detail before the stream opens keeps it" do
    assert %Error{message: "Unauthorized"} =
             HTTPError.from_response(401, ~s({"detail":"Unauthorized"}), [])
  end

  test "reads the other shapes errors come in" do
    assert %Error{message: "nope"} = HTTPError.from_response(400, ~s({"error":"nope"}), [])
    assert %Error{message: "hm"} = HTTPError.from_response(400, ~s({"message":"hm"}), [])

    quota = ~s({"error":{"type":"insufficient_quota","message":"out"}})
    assert %Error{retryable: false} = HTTPError.from_response(429, quota, [])
  end

  test "a body that isn't JSON is quoted, and an empty one says so" do
    assert %Error{message: "Bad Gateway"} = HTTPError.from_response(502, " Bad Gateway \n", [])
    assert %Error{message: "no details"} = HTTPError.from_response(500, "", [])
  end
end
