defmodule Photon.Skills.MockPhrases do
  @moduledoc """
  The skill phrasings that Blip's scripted model
  (`Photon.Assistant.MockScript`) and a thread's
  (`Photon.Threads.MockScript`) share:

    * `skills` (or `list skills`) says which skills the request's system
      prompt lists, with their versions, without a tool call, so tests and a
      hub on the scripted model can see what the prompt listed: the agent's
      own, then, when the prompt lists any, each machine's
    * `load skill <name>` calls `load_skill` with `name`

  After a `load_skill` result, the scripts' usual relay prints it.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  # One listed skill in the prompt's Skills section (`Photon.Skills.Prompt`).
  @listed ~r{<skill><name>([^<]*)</name><version>(\d+)</version>}

  # Where the machines' skills start in that section, and one machine's group.
  @machine_skills "<machine_skills>"
  @machine ~r{<machine name="([^"]*)">(.*?)</machine>}s

  @typedoc "A phrasing: the pattern a message must match, and the reply its captures make."
  @type phrasing :: {Regex.t(), ([String.t()] -> Message.t())}

  @doc """
  The skill phrasings, in the order a script tries them, each with the
  reply its captures make. `request` is the model request, whose `system`
  text the `skills` reply reads.
  """
  @spec phrasings(map()) :: [phrasing()]
  def phrasings(request) do
    system = request[:system] || ""

    [
      {~r/\A(?:list )?skills\z/, fn [] -> list(system) end},
      {~r/\Aload skill\s+(\S+)\z/, &load/1}
    ]
  end

  defp list(system) do
    {own, machines} =
      case String.split(system, @machine_skills, parts: 2) do
        [own, machines] -> {own, machines}
        [own] -> {own, ""}
      end

    Message.assistant(own_sentence(listed(own)) <> machines_sentence(machines))
  end

  defp own_sentence([]), do: "No skills are turned on here."
  defp own_sentence(skills), do: "Skills turned on here: #{names(skills)}."

  # Nothing when the prompt lists no machine skills, so the reply is what
  # it was before machines had skills.
  defp machines_sentence(text) do
    case Regex.scan(@machine, text, capture: :all_but_first) do
      [] ->
        ""

      groups ->
        " For machines: " <>
          Enum.map_join(groups, "; ", fn [id, group] -> "#{id}: #{names(listed(group))}" end) <>
          "."
    end
  end

  defp listed(text), do: Regex.scan(@listed, text, capture: :all_but_first)

  defp names(skills),
    do: Enum.map_join(skills, ", ", fn [name, version] -> "#{name} (version #{version})" end)

  defp load([name]),
    do:
      Message.assistant("Loading the #{name} skill.", [
        Mock.call("load_skill", %{"name" => name})
      ])
end
