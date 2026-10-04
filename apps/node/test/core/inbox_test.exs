defmodule PhotonNode.Harness.InboxTest do
  use PhotonNode.Case, async: true

  defp control(payload), do: %{"id" => "x", "kind" => "control", "payload" => payload}

  # node-inbox-heartbeat-parameters (spec 5.1)
  test "a heartbeat with parameters is rejected, like a hard stop" do
    assert {:error, "control mode \"heartbeat\" does not accept parameters"} =
             Inbox.validate(
               control(%{"mode" => "heartbeat", "reason" => "a", "parameters" => %{}})
             )

    assert {:error, _} =
             Inbox.validate(control(%{"mode" => "hard", "reason" => "a", "parameters" => %{}}))

    assert :ok = Inbox.validate(control(%{"mode" => "heartbeat", "reason" => "a"}))
    assert :ok = Inbox.validate(control(%{"mode" => "settings", "parameters" => %{}}))
  end

  # node-inbox-poison-content
  test "external content must be text or well-formed parts" do
    assert :ok = Inbox.validate(external("hi"))
    assert :ok = Inbox.validate(external([%{"type" => "text", "text" => "hi"}]))

    assert :ok =
             Inbox.validate(
               external([%{"type" => "image", "mime" => "image/png", "data" => "QQ"}])
             )

    assert {:error, _} = Inbox.validate(external([%{"type" => "text", "text" => [nil]}]))
    assert {:error, _} = Inbox.validate(external([%{"type" => "image"}]))
    assert {:error, _} = Inbox.validate(external([3]))
  end
end
