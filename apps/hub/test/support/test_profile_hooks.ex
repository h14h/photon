defmodule Photon.TestProfile.Hooks do
  @moduledoc """
  `Photon.TestProfile` with both profile hooks (`on_settled/3`,
  `on_tool_result/4`). Each hook announces what it got on the topic
  `"test:hooks"` through `Photon.Durable.Tx.announce/3`, so a subscriber
  hears of a hook only once the commit it ran in is stored:

    * `{:settled, conversation_id, settled}`
    * `{:tool_result, conversation_id, task, entry}`

  Its scripted model answers as `Photon.TestProfile`'s does, and also:

    * `"commit"` calls the `commit` tool, whose result is a `{:commit, fun}`
    * `"exit"` calls the `exit` tool, whose step exits, failing its task
    * `"crash"` crashes the generation's step, failing its task
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour Photon.Durable.Profile
  @behaviour PhotonCore.LLM.Mock

  alias Photon.Durable.Tx
  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @topic "test:hooks"

  @doc "The topic the hooks announce on."
  def topic, do: @topic

  @impl Photon.Durable.Profile
  def llm(_conversation),
    do: %{config: %{provider: "mock", script: __MODULE__}, model: "test", reasoning: nil}

  @impl Photon.Durable.Profile
  def system_prompt(_conversation), do: "test"

  @impl Photon.Durable.Profile
  def tools(_conversation),
    do: [
      Photon.TestProfile.Wait,
      Photon.TestProfile.Raise,
      Photon.TestProfile.Commit,
      Photon.TestProfile.Exit
    ]

  @impl Photon.Durable.Profile
  def on_settled(conversation, settled, tx),
    do: Tx.announce(tx, @topic, {:settled, conversation.id, settled})

  @impl Photon.Durable.Profile
  def on_tool_result(conversation, task, entry, tx),
    do: Tx.announce(tx, @topic, {:tool_result, conversation.id, task, entry})

  @impl PhotonCore.LLM.Mock
  def respond(request) do
    case List.last(request[:messages]) do
      %{"role" => "tool"} -> Message.assistant("waited")
      message -> reply(Message.text_of(message))
    end
  end

  defp reply("crash"), do: raise("the model crashed")

  defp reply(tool) when tool in ["wait", "raise", "commit", "exit"],
    do: Message.assistant("", [Mock.call(tool, %{})])

  defp reply("fail"), do: {:error, "model down"}
  defp reply(text), do: Message.assistant("echo: " <> text)
end
