# Credo for apps/hub (`mix credo --strict`, part of `mix precommit`).
#
# The shared checks are in tools/credo_checks/shared_checks.exs; this file
# adds the ones that need the hub's own module lists. Rule numbers refer to
# docs/otp-design-guide.md.
{shared_checks, _binding} =
  Code.eval_file(Path.expand("../../tools/credo_checks/shared_checks.exs", __DIR__))

lib_only = %{excluded: [~r"/_build/", ~r"/deps/", ~r"(^|/)test/"]}

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [".dialyzer_ignore.exs", "lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      requires: [
        "../../tools/credo_checks/lib/photon_credo/ast.ex",
        "../../tools/credo_checks/lib/"
      ],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled:
          shared_checks ++
            [
              # 72, 95: a dropped result says why; see PhotonCredo.Check.DiscardNeedsReason.
              {PhotonCredo.Check.DiscardNeedsReason,
               [
                 files: lib_only,
                 allowed: [
                   {"Photon.Durable",
                    "its writes go through the commit line and raise on failure; they return what they stored"},
                   {"Photon.Durable.Tx",
                    "writes inside a commit raise on failure (the commit rolls back); they return the stored rows"}
                 ]
               ]},
              # 28, 29: the functional core and the data modules do no I/O and
              # touch no processes (the modules from the architecture map's
              # functional core row, plus the Ecto schemas).
              {PhotonCredo.Check.FunctionalCore,
               [
                 files: lib_only,
                 core_modules: [
                   "Photon.Durable.Context",
                   "Photon.Durable.Schema",
                   "Photon.Durable.Inbox",
                   "Photon.Durable.Policy",
                   "Photon.Durable.Turn",
                   "Photon.Durable.ToolCall",
                   "Photon.Durable.Changes",
                   "Photon.Durable.Queries",
                   "Photon.Durable.Conversation",
                   "Photon.Durable.Entry",
                   "Photon.Durable.Doc",
                   "Photon.Durable.Signal",
                   "Photon.Durable.Submission",
                   "Photon.Durable.TaskRecord",
                   "Photon.Assistant.Prompt",
                   "Photon.ChatGPT.OAuth",
                   "Photon.Assistant.Memory",
                   "Photon.Transcript",
                   "Photon.Assistant.Notice",
                   "Photon.Assistant.MockScript",
                   "Photon.Machines.Op",
                   "Photon.Machines.Rules",
                   "Photon.Machines.Roster",
                   "Photon.MachineTools.Guide",
                   "Photon.MachineTools.MockPhrases",
                   "Photon.MachineTools.Translate",
                   "Photon.MachineTools.Wait",
                   "Photon.Projects.Project",
                   "Photon.Projects.ContextFile",
                   "Photon.Projects.Rules",
                   "Photon.Threads.Thread",
                   "Photon.Threads.Rules",
                   "Photon.Threads.Prompt",
                   "Photon.Threads.MockScript",
                   "Photon.Provision.Jobs",
                   "Photon.Provision.Script",
                   "Photon.Provision.Lines",
                   "Photon.InstallScript",
                   "Photon.Markdown",
                   "PhotonWeb.ProjectText"
                 ],
                 nondeterministic_extra: ["PhotonCore.ID.new"]
               ]},
              # 30: server and framework callbacks hand their message to a context
              # or the core and stay short.
              {PhotonCredo.Check.ThinCallbacks,
               [
                 files: lib_only,
                 callbacks: [
                   :handle_call,
                   :handle_cast,
                   :handle_info,
                   :handle_continue,
                   :join,
                   :handle_in,
                   :handle_event,
                   :handle_params
                 ]
               ]},
              # 11: LiveViews and channels call contexts; no persistence, I/O or
              # messaging infrastructure of their own.
              {PhotonCredo.Check.LiveViewLogic,
               [
                 files: lib_only,
                 uses: [
                   {"PhotonWeb", :live_view},
                   {"PhotonWeb", :live_component},
                   {"PhotonWeb", :channel},
                   "Phoenix.LiveView",
                   "Phoenix.LiveComponent",
                   "Phoenix.Channel"
                 ],
                 forbidden: [
                   "*.Repo",
                   "Ecto",
                   "Ecto.Query",
                   "Ecto.Changeset",
                   "Ecto.Multi",
                   "File",
                   "Port",
                   "System.cmd",
                   "System.shell",
                   "Req",
                   "Phoenix.PubSub",
                   "Registry",
                   "GenServer",
                   ":ets",
                   ":persistent_term",
                   ":gen_server"
                 ]
               ]},
              # 55, 96: no sleeping.
              {PhotonCredo.Check.NoSleep,
               [
                 allowed: [
                   {"Photon.Property.SlowProfile",
                    "simulates model latency inside a durable step task, which has no mailbox to serve"}
                 ]
               ]},
              # 62, 83: process names stay with their owners; the APIs hand out none.
              {PhotonCredo.Check.ProcessNameOwnership,
               [
                 files: lib_only,
                 api_modules: [
                   "Photon.Assistant",
                   "Photon.ChatGPT",
                   "Photon.Durable",
                   "Photon.Machines",
                   "Photon.Projects",
                   "Photon.Provision",
                   "Photon.Settings",
                   "Photon.Tailnet",
                   "Photon.Threads"
                 ],
                 names: [
                   {"Photon.Supervisor", ["Photon.Application"]},
                   {"Photon.PubSub", ["Photon.*"]},
                   {"Photon.MachineRegistry", ["Photon.Application", "Photon.Machines"]},
                   {"Photon.ProvisionTasks", ["Photon.Application", "Photon.Provision"]},
                   {"Photon.Durable.TaskSupervisor",
                    ["Photon.Durable.Supervisor", "Photon.Durable.Scheduler"]}
                 ]
               ]},
              # 72: call, not cast; the deliberate sends say why.
              {PhotonCredo.Check.PreferCall,
               [
                 files: lib_only,
                 allowed: [
                   {"Photon.Durable.Scheduler",
                    "notify/2: the Store must never wait on the scheduler; a burst collapses into one reconcile, which reads the database (see its moduledoc)"},
                   {"Photon.Machines",
                    "command/3, push_op/2 and register/2: callers must not wait on a node's connection; ops are rows, pushed again on every join and every minute while their call waits on an online machine. register/2 tells a replaced connection to stop, and waits for its exit (see its moduledoc)"},
                   {"Photon.Provision",
                    "progress from its own job tasks, a line at a time; a job that dies without reporting its end is failed by its monitor"}
                 ]
               ]},
              # 80, 91, 16: processes start under supervisors.
              {PhotonCredo.Check.SupervisedProcesses, [files: lib_only]}
            ]
      }
    }
  ]
}
