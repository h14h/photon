# Credo for apps/node (`mix credo --strict`, part of `mix precommit`).
#
# The shared checks are in tools/credo_checks/shared_checks.exs; this file
# adds the ones that need the node's own module lists. Rule numbers refer to
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
                 allowed: []
               ]},
              # 28, 29: the harness's functional core does no I/O and touches no
              # processes. New turns, settings inputs, heartbeats and operations get
              # IDs from the clock and the RNG on purpose (tests match on prefixes).
              {PhotonCredo.Check.FunctionalCore,
               [
                 files: lib_only,
                 core_modules: [
                   "PhotonNode.Harness.Session",
                   "PhotonNode.Harness.Context",
                   "PhotonNode.Harness.Inbox",
                   "PhotonNode.Harness.Operation",
                   "PhotonNode.Harness.Output",
                   "PhotonNode.Harness.Image",
                   "PhotonNode.Harness.SkillPrompt",
                   "PhotonNode.Harness.Tools.*"
                 ],
                 nondeterministic_extra: ["PhotonCore.ID.new"],
                 allowed: [
                   {"PhotonNode.Harness.Session", ["PhotonCore.ID.new"]},
                   {"PhotonNode.Harness.Operation", ["PhotonCore.ID.new"]}
                 ]
               ]},
              # 30: server callbacks hand their message to the core and stay short.
              {PhotonCredo.Check.ThinCallbacks,
               [
                 files: lib_only,
                 callbacks: [
                   :handle_call,
                   :handle_cast,
                   :handle_info,
                   :handle_continue,
                   :handle_connect,
                   :handle_join,
                   :handle_message,
                   :handle_topic_close,
                   :handle_disconnect
                 ]
               ]},
              # 55, 96: no sleeping.
              {PhotonCredo.Check.NoSleep,
               [
                 allowed: [
                   {"PhotonNode.Harness.Ops.Shell",
                    "terminate/2 waits in place for a killed process group: a stopping process can't take messages; the running process polls with send_after"},
                   {"PhotonNode.CLI",
                    "the packaged executable's at_exit hook never returns, which keeps the VM up for the node"}
                 ]
               ]},
              # 62, 83: process names stay with their owners; the API hands out none.
              {PhotonCredo.Check.ProcessNameOwnership,
               [
                 files: lib_only,
                 api_modules: ["PhotonNode.Harness"],
                 names: [
                   {"PhotonNode.AppSupervisor", ["PhotonNode.Application"]},
                   {"PhotonNode.SessionRegistry",
                    ["PhotonNode", "PhotonNode.Harness.Coordinator"]},
                   {"PhotonNode.OpRegistry", ["PhotonNode", "PhotonNode.Harness.Ops"]},
                   {"PhotonNode.Harness.TaskSupervisor",
                    ["PhotonNode", "PhotonNode.Harness.ModelRequest"]},
                   {"PhotonNode.Harness.OpSupervisor", ["PhotonNode", "PhotonNode.Harness.Ops"]},
                   {"PhotonNode.Harness.SessionSupervisor",
                    ["PhotonNode", "PhotonNode.Harness.Coordinator"]}
                 ]
               ]},
              # 72: call, not cast; the deliberate sends say why.
              {PhotonCredo.Check.PreferCall,
               [
                 files: lib_only,
                 allowed: [
                   {"PhotonNode.Connection",
                    "log records and live output for the hub link: a lost record is recovered (the hub resyncs gaps, every join replays) and live output is never stored; producers are bounded (see its moduledoc)"},
                   {"PhotonNode.Harness.Coordinator",
                    "report_op/2: a lost snapshot is recovered, since Ops.add/2 makes a live operation resend it to a restarted coordinator"},
                   {"PhotonNode.Harness.Ops",
                    ":resend and :cancel to a local operation process, which the coordinator monitors: a process that exits instead of answering is seen there"}
                 ]
               ]},
              # 80, 91, 16: processes start under supervisors.
              {PhotonCredo.Check.SupervisedProcesses, [files: lib_only]}
            ]
      }
    }
  ]
}
