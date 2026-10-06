defmodule Photon do
  @moduledoc """
  The Photon hub: an always-on assistant that runs commands on the user's
  machines through the nodes there, and the web UI to talk to it.

  The contexts (the APIs the web layer and nodes use):

    * `Photon.Assistant`: the assistant's conversation, memory and
      schedules, the page the user has open under it, and its profile for
      the durable harness
    * `Photon.Durable`: the durable agent harness the assistant and threads
      run on
    * `Photon.Machines`: the machines the hub knows, which are connected,
      and the operations (shell commands, image reads) it runs on them
    * `Photon.Projects`: projects (a purpose, for any body of work) and
      their context files, the Markdown notes the user and the project's
      threads share
    * `Photon.Threads`: threads, the durable agent conversations inside a
      project, and their `"thread"` profile for the durable harness
    * `Photon.Settings`: the model and the assistant's instructions
    * `Photon.Provision`, `Photon.NodeDist`, `Photon.Hub`,
      `Photon.Tailnet`: putting nodes on machines, and how they reach the hub
    * `Photon.Auth`, `Photon.NodeKeys`: who may open the GUI (your devices
      on the tailnet, or a password), and each node's own key

  Layers, after *Designing Elixir Systems with OTP*: each context's
  moduledoc names its pure core and its processes. The pure modules are
  `Photon.Durable.{Context, Schema, Inbox, Policy, Turn, ToolCall,
  Changes, Queries}`, `Photon.Assistant.{Prompt, Memory, Notice,
  MockScript}`, `Photon.Transcript` (what a conversation page shows),
  `Photon.Machines.{Rules, Roster}`, `Photon.Projects.Rules`,
  `Photon.Threads.{Rules, Prompt, MockScript}`,
  `Photon.MachineTools.{Translate, Wait, Guide, MockPhrases}`,
  `Photon.Provision.{Jobs, Script}`, and `Photon.Markdown`. `Photon.Application` holds the lifecycle plan.
  `PhotonWeb` is the boundary for browsers and nodes: its LiveViews,
  channel and controllers call the contexts above and hold no business
  logic.
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
      Settings,
      Tailnet,
      Threads,
      Threads.Thread,
      Transcript
    ]
end
