defmodule PhotonNode.TestScript do
  @moduledoc """
  A mock model for harness tests that need answers `PhotonCore.LLM.MockAgent`
  doesn't give: `"quiet"` gets an empty answer with no tool calls, and
  `"block"` holds its request open (telling the process in the
  `:test_llm_listener` app env which task it is) until that task gets
  `:release`.
  Anything else goes to `MockAgent`.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour PhotonCore.LLM.Mock

  alias PhotonCore.LLM.{Mock, MockAgent}
  alias PhotonCore.Message

  @impl true
  def respond(request) do
    case Mock.last_user_text(request) do
      "quiet" ->
        Message.assistant("")

      "block" ->
        if pid = Application.get_env(:photon_node, :test_llm_listener),
          do: send(pid, {:llm_request, self()})

        receive do
          :release -> Message.assistant("released")
        end

      _ ->
        MockAgent.respond(request)
    end
  end

  @doc "Uses this script for the rest of the test; blocked requests report to the caller."
  def use_script do
    previous = Application.get_env(:photon_node, :llm)
    Application.put_env(:photon_node, :llm, %{provider: "mock", script: __MODULE__})
    Application.put_env(:photon_node, :test_llm_listener, self())

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:photon_node, :llm, previous)
      Application.delete_env(:photon_node, :test_llm_listener)
    end)
  end
end
