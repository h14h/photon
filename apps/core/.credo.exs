# Credo for apps/core (`mix credo --strict`, part of `mix precommit`).
#
# The shared checks are in tools/credo_checks/shared_checks.exs; this file
# adds the ones that need core's own module lists. Rule numbers refer to
# docs/otp-design-guide.md. The custom checks (`PhotonCredo.Check.*`) live in
# tools/credo_checks/lib and are tested by this app's suite.
{shared_checks, _binding} =
  Code.eval_file(Path.expand("../../tools/credo_checks/shared_checks.exs", __DIR__))

lib_only = %{excluded: [~r"/_build/", ~r"/deps/", ~r"(^|/)test/"]}

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          ".dialyzer_ignore.exs",
          "lib/",
          "test/",
          "../../tools/credo_checks/lib/",
          "../../tools/credo_checks/test/"
        ],
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
              # 28, 29: the functional core does no I/O and touches no processes.
              # `PhotonCore.ID.new/1` is the one place that reads the clock and the RNG.
              {PhotonCredo.Check.FunctionalCore,
               [
                 files: lib_only,
                 core_modules: [
                   "PhotonCore.ID",
                   "PhotonCore.Message",
                   "PhotonCore.LLM.Error",
                   "PhotonCore.LLM.SSE",
                   "PhotonCore.LLM.Retry",
                   "PhotonCore.LLM.HTTPError",
                   "PhotonCore.LLM.Responses.Request",
                   "PhotonCore.LLM.Responses.Response",
                   "PhotonCore.Output",
                   "PhotonCore.Operation",
                   "PhotonCore.Operation.Wire"
                 ],
                 nondeterministic_extra: ["PhotonCore.ID.new"],
                 allowed: [
                   {"PhotonCore.ID", ["System.system_time", ":crypto.strong_rand_bytes"]}
                 ]
               ]},
              # 30: callbacks stay thin (core has none; kept for new code).
              {PhotonCredo.Check.ThinCallbacks, []},
              # 55, 96: no sleeping.
              {PhotonCredo.Check.NoSleep,
               [
                 allowed: [
                   {"PhotonCore.LLM",
                    "waits between retries in the caller's process; callers run requests in tasks, never in a server callback (see its moduledoc)"}
                 ]
               ]},
              # 62, 83: the API takes data and hands out no processes.
              {PhotonCredo.Check.ProcessNameOwnership,
               [files: lib_only, api_modules: ["PhotonCore.LLM"]]},
              # 72: call, not cast.
              {PhotonCredo.Check.PreferCall, [files: lib_only]},
              # 80, 91, 16: processes start under supervisors.
              {PhotonCredo.Check.SupervisedProcesses, [files: lib_only]}
            ]
      }
    }
  ]
}
