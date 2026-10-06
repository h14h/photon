defmodule Photon.MachineTools.MockPhrases do
  @moduledoc """
  The machine tool phrasings that Blip's scripted model
  (`Photon.Assistant.MockScript`) and a thread's share, so both answer the
  same words the same way (section 3.6 of
  `docs/plans/step-2-projects-and-threads.md`):

    * `machines` (or `list machines`) lists machines (`list_machines`)
    * `on <machine>: $ <command>` runs a command (`shell`)
    * `on <machine>: look at <path>` looks at an image (`view_image`)

  and how a script relays a tool's result (`relay_result/1`).
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  @typedoc "A phrasing: the pattern a message must match, and the reply its captures make."
  @type phrasing :: {Regex.t(), ([String.t()] -> Message.t())}

  @doc """
  The machine phrasings, in the order a script tries them, each with the
  reply (an assistant message with one tool call) that its captures make.
  """
  @spec phrasings() :: [phrasing()]
  def phrasings do
    [
      {~r/\A(?:list )?machines\z/, &list_machines/1},
      {~r/\Aon\s+([\w.-]+)\s*:\s*\$(.+)\z/s, &shell/1},
      {~r/\Aon\s+([\w.-]+)\s*:\s*look at (.+)\z/s, &view_image/1}
    ]
  end

  defp list_machines([]), do: call("list_machines", %{}, "Checking your machines.")

  defp shell([machine, command]),
    do:
      call(
        "shell",
        %{"machine" => machine, "command" => String.trim(command)},
        "Running that on #{machine}."
      )

  defp view_image([machine, path]),
    do:
      call(
        "view_image",
        %{"machine" => machine, "path" => String.trim(path)},
        "Looking at it on #{machine}."
      )

  defp call(tool, args, intro), do: Message.assistant(intro, [Mock.call(tool, args)])

  @doc """
  What a script says after a tool result: the result's text, with
  "Error: ..." turned into "That didn't work: ...", or for an image
  "Here it is." and its line of size and path.
  """
  @spec relay_result(Message.t()) :: String.t()
  def relay_result(result) do
    case Message.images(result) do
      [] -> result |> Message.text_of() |> relay()
      _images -> "Here it is.\n\n" <> Message.text_of(result)
    end
  end

  defp relay("Error: " <> error), do: "That didn't work: " <> error
  defp relay(text), do: text
end
