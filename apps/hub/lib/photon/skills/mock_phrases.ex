defmodule Photon.Skills.MockPhrases do
  @moduledoc """
  The skill phrasings that Blip's scripted model
  (`Photon.Assistant.MockScript`) and a thread's
  (`Photon.Threads.MockScript`) share (section 4 of
  `docs/plans/step-3-skills-and-schedules.md`):

    * `skills` (or `list skills`) says which skills the request's system
      prompt lists, with their versions, without a tool call, so tests and
      a hub on the scripted model can see what the prompt listed
    * `load skill <name>` calls `load_skill` with `name`

  After a `load_skill` result, the scripts' usual relay prints it.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]

  alias PhotonCore.LLM.Mock
  alias PhotonCore.Message

  # One listed skill in the prompt's Skills section (`Photon.Skills.Prompt`).
  @listed ~r{<skill><name>([^<]*)</name><version>(\d+)</version>}

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
    case Regex.scan(@listed, system, capture: :all_but_first) do
      [] ->
        Message.assistant("No skills are turned on here.")

      skills ->
        names =
          Enum.map_join(skills, ", ", fn [name, version] -> "#{name} (version #{version})" end)

        Message.assistant("Skills turned on here: #{names}.")
    end
  end

  defp load([name]),
    do:
      Message.assistant("Loading the #{name} skill.", [
        Mock.call("load_skill", %{"name" => name})
      ])
end
