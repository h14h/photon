defmodule Photon do
  @moduledoc """
  The Photon hub: an always-on assistant that hands work to agent nodes on
  the user's machines, and the web UI to talk to it.

  The contexts (the APIs the web layer and nodes use):

    * `Photon.Assistant`: the assistant's conversation, memory and
      schedules, and its profile for the durable harness
    * `Photon.Durable`: the durable agent harness the assistant runs on
    * `Photon.NodeSessions`: the hub's copy of each node session and the
      outbox of inputs for it
    * `Photon.Nodes`: which nodes are connected, and commands to them
    * `Photon.Settings`: the model and the assistant's instructions
    * `Photon.Provision`, `Photon.NodeDist`, `Photon.Hub`,
      `Photon.Tailnet`: putting nodes on machines, and how they reach the hub
    * `Photon.Auth`, `Photon.NodeKeys`: who may open the GUI (your devices
      on the tailnet, or a password), and each node's own key

  Layers, after *Designing Elixir Systems with OTP*: each context's
  moduledoc names its pure core and its processes. The pure modules are
  `Photon.Durable.{Context, Schema, Inbox, Policy, Turn, ToolCall,
  Changes, Queries}`, `Photon.Assistant.{Prompt, Memory, Report,
  Transcript, MockScript}`, `Photon.NodeSessions.Mirror`,
  `Photon.NodeTranscript`, `Photon.Provision.{Jobs, Script}`, and
  `Photon.Markdown`. `Photon.Application` holds the lifecycle plan.
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
      Assistant.Transcript,
      Auth,
      ChatGPT,
      Durable,
      Events,
      Hub,
      InstallScript,
      Markdown,
      NodeDist,
      NodeKeys,
      NodeSessions,
      NodeSessions.Session,
      NodeTranscript,
      Nodes,
      Paths,
      Provision,
      Settings,
      Tailnet
    ]
end
