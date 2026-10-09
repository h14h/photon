defmodule Photon do
  @moduledoc """
  The Photon hub: Blip, an always-on assistant, and projects whose threads
  do the work, all running commands on the user's machines through the
  nodes there; and the web UI for all of it.

  The contexts (the APIs the web layer and nodes use):

    * `Photon.Assistant`: Blip's conversation, memory, page and tools
    * `Photon.Projects`: projects and their shared context files
    * `Photon.Threads`: threads, the durable agent conversations inside a
      project, and their derived state
    * `Photon.Questions`: a thread's `ask_blip` questions and their answers
    * `Photon.Activity`: the log of everything Blip did and who asked
    * `Photon.Signals`: what reaches Blip unasked; used by the other
      contexts, not the web layer
    * `Photon.Skills`: instructions an agent loads when a task calls for
      them
    * `Photon.Schedules`: prompts that fire at set times
    * `Photon.Ambient`: ambient mode, Blip's digests and daily reviews
    * `Photon.Durable`: the durable agent harness Blip and threads run on
    * `Photon.Machines`, `Photon.MachineTools`: the machines, their
      operations, and the durable tools that start them
    * `Photon.Settings`, `Photon.ChatGPT`: the model, Blip's instructions,
      and the ChatGPT account
    * `Photon.Provision`, `Photon.NodeDist`, `Photon.Hub`,
      `Photon.Tailnet`: putting nodes on machines, and how they reach the hub
    * `Photon.Auth`, `Photon.NodeKeys`: who may open the GUI, and each
      node's own key

  None of them adds a process for a project, a thread, a skill, a
  schedule, a signal, a question or an operation: those are rows,
  conversations in the durable harness, durable tasks, or messages in
  Blip's conversation. A thread's state is never stored:
  `Photon.Threads.State` derives it from facts on the thread's row when
  it is read.

  The pure cores are listed under `FunctionalCore` in `.credo.exs`.
  `Photon.Application` holds the lifecycle plan. `PhotonWeb` is the
  boundary for browsers and nodes: it calls the contexts above and holds
  no business logic.
  """

  # The hub's contexts, each a boundary of its own; this root exports
  # their APIs (and the data they return) to the web layer. They never call
  # the node app; only `Photon.Application` starts an embedded node.
  use Boundary,
    deps: [
      PhotonCore,
      PhotonCore.LLM,
      PhotonCore.LLM.Error,
      PhotonCore.LLM.Mock,
      # Pure modules other contexts' cores share, top-level so a core can
      # depend on them without being allowed to call their context.
      Photon.Durable.RunBoundary,
      Photon.MachineTools.Guide,
      Photon.MachineTools.MockPhrases,
      Photon.Skills.MockPhrases,
      Photon.Skills.Prompt,
      Photon.Text,
      Photon.Threads.State,
      Ecto,
      EEx,
      Jason,
      MDEx,
      Req
    ],
    check: [apps: [:photon_node]],
    exports: [
      Activity,
      Activity.Action,
      Activity.Rules,
      Ambient,
      Assistant,
      Assistant.Notice,
      Auth,
      ChatGPT,
      Durable,
      Events,
      Hub,
      InstallScript,
      Machines,
      Markdown,
      NodeDist,
      NodeKeys,
      Paths,
      Projects,
      Projects.ContextFile,
      Projects.Project,
      Provision,
      Questions,
      Questions.Question,
      Schedules,
      Schedules.Schedule,
      Settings,
      Skills,
      Skills.Skill,
      Tailnet,
      Threads,
      Threads.Thread,
      Transcript
    ]
end
