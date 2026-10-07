defmodule Photon do
  @moduledoc """
  The Photon hub: Blip, an always-on assistant, and projects whose threads
  do the work, all running commands on the user's machines through the
  nodes there; and the web UI for all of it.

  The contexts (the APIs the web layer and nodes use):

    * `Photon.Assistant`: Blip's conversation and memory, its tools over
      its own skills and schedules, the page the user has open under it,
      and its `"assistant"` profile for the durable harness
    * `Photon.Projects`: projects (a purpose, for any body of work) and
      their context files, the Markdown notes the user and the project's
      threads share
    * `Photon.Threads`: threads, the durable agent conversations inside a
      project, their state (worked out from stored facts), and their
      `"thread"` profile for the durable harness
    * `Photon.Signals`: what reaches Blip unasked, such as how the threads
      it started end, posted into Blip's conversation by code; used by
      the other contexts, not the web layer
    * `Photon.Skills`: skills, the instructions an agent loads when a task
      calls for them, written or installed by the user and turned on for
      Blip or per project
    * `Photon.Schedules`: schedules, prompts that fire at set times: a
      project's start or wake its threads, and Blip's post to Blip
    * `Photon.Durable`: the durable agent harness Blip and threads run on
    * `Photon.Machines`: the machines the hub knows, which are connected,
      and the operations (shell commands, image reads) it runs on them;
      `Photon.MachineTools` are the durable tools Blip and threads share
      to start them
    * `Photon.Settings`, `Photon.ChatGPT`: the model every conversation
      uses, Blip's instructions, and the ChatGPT account
    * `Photon.Provision`, `Photon.NodeDist`, `Photon.Hub`,
      `Photon.Tailnet`: putting nodes on machines, and how they reach the hub
    * `Photon.Auth`, `Photon.NodeKeys`: who may open the GUI (your devices
      on the tailnet, or a password), and each node's own key

  None of them adds a process for a project, a thread, a skill, a
  schedule, a signal or an operation: projects, context files and skills
  are rows, a thread is a conversation in the durable harness, a signal
  is a message in Blip's, a schedule is a row and a durable task waiting
  for its time, and an operation is a row its tool call waits on.

  Layers, after *Designing Elixir Systems with OTP*: each context's
  moduledoc names its pure core and its processes. The pure modules are
  `Photon.Durable.{Context, Schema, Inbox, Policy, Turn, ToolCall,
  Changes, Queries}`, `Photon.Assistant.{Prompt, Memory, Notice, Page,
  MockScript}`, `Photon.Transcript` (what a conversation page shows),
  `Photon.Projects.Rules`, `Photon.Threads.{Rules, State, Prompt, MockScript}`,
  `Photon.Signals.{Rules, Text}`,
  `Photon.Skills.{Rules, SkillMd, Source, Prompt, MockPhrases}`,
  `Photon.Schedules.Rules`,
  `Photon.Machines.{Rules, Roster}`,
  `Photon.MachineTools.{Translate, Wait, Guide, MockPhrases}`,
  `Photon.Provision.{Jobs, Script}`, and `Photon.Markdown`.
  `Photon.Application` holds the lifecycle plan. `PhotonWeb` is the
  boundary for browsers and nodes: its LiveViews, channel and controllers
  call the contexts above and hold no business logic; its pure
  `PhotonWeb.{ProjectText, ScheduleText, SkillText}` only put the pages'
  words together.
  """

  # The hub's contexts, each a boundary of its own; this root exports
  # their APIs (and the data they return) to the web layer. They never call
  # the node app; only `Photon.Application` starts an embedded node.
  use Boundary,
    deps: [PhotonCore, PhotonCore.LLM, PhotonCore.LLM.Error, Ecto, EEx, Jason, MDEx, Req],
    check: [apps: [:photon_node]],
    exports: [
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
      Schedules,
      Schedules.Schedule,
      Settings,
      Skills,
      Skills.Skill,
      Tailnet,
      Threads,
      Threads.State,
      Threads.Thread,
      Transcript
    ]
end
