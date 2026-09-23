defmodule PhotonNode.Runner do
  @moduledoc """
  Builds `unreal-agent-runner` invocations from the run config the GUI sends,
  and starts them under `PhotonNode.RunSupervisor`.

  Each GUI message is one runner invocation resuming the same `session_id`;
  the runner's session store on this node carries the conversation.
  """

  alias PhotonNode.{Config, EventLog}

  @provider_key_envs ~w(OPENAI_API_KEY OPENROUTER_API_KEY FIREWORKS_API_KEY)

  @doc "Provider API-key variables set in this node's environment (names only)."
  def key_envs, do: Enum.filter(@provider_key_envs, &(System.get_env(&1) not in [nil, ""]))

  @doc "Locates the runner binary, or returns nil."
  def executable(config \\ PhotonNode.config()) do
    [
      config.runner,
      System.get_env("UNREAL_AGENT_RUNNER"),
      Application.app_dir(:photon_node, "priv/bin/unreal-agent-runner"),
      System.find_executable("unreal-agent-runner")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&Path.expand/1)
    |> Enum.find(&executable?/1)
  end

  defp executable?(path) do
    match?(
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0,
      File.stat(path)
    )
  end

  def running_ids do
    PhotonNode.RunRegistry |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def start(session_id, prompt, run_config, attachments \\ []) do
    config = PhotonNode.config()

    with :ok <- validate_id(session_id),
         {:ok, exe} <- find(config),
         {:ok, workspace} <- ensure_workspace(config, run_config["workspace"]),
         :ok <- write_attachments(workspace, attachments) do
      spec = %{
        session_id: session_id,
        executable: exe,
        args: args(config, session_id, prompt, run_config, workspace),
        env: env(config, run_config),
        cd: workspace
      }

      case DynamicSupervisor.start_child(PhotonNode.RunSupervisor, {PhotonNode.Run, spec}) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, _}} ->
          {:error, "A run is already in progress for this session."}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  @doc """
  Writes images sent with a message into the workspace, where the message's
  note tells the agent to open them with ViewImage. Paths are checked here
  too, so nothing can be written outside `.attachments/`.
  """
  def write_attachments(workspace, attachments) do
    Enum.reduce_while(attachments, :ok, fn attachment, :ok ->
      with %{"path" => path, "data" => data} <- attachment,
           true <- path =~ ~r/\A\.attachments\/[A-Za-z0-9._-]{1,80}\z/,
           {:ok, bytes} <- Base.decode64(data),
           dest = Path.join(workspace, path),
           :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.write(dest, bytes) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "Couldn't save an attached image into the workspace."}}
      end
    end)
  end

  def stop(session_id) do
    case Registry.lookup(PhotonNode.RunRegistry, session_id) do
      [{pid, _}] -> PhotonNode.Run.interrupt(pid)
      [] -> :ok
    end
  end

  @doc "Removes the node's copy of a session: runner store, operations and event log."
  def delete(session_id) do
    with :ok <- validate_id(session_id) do
      stop(session_id)
      dir = Config.runner_sessions_dir(PhotonNode.config())
      File.rm(Path.join(dir, session_id <> ".session.jsonl"))
      File.rm_rf(Path.join([dir, "operations", session_id]))
      EventLog.delete(session_id)
    end
  end

  defp validate_id(id),
    do: if(EventLog.valid_id?(id), do: :ok, else: {:error, "invalid session id"})

  defp find(config) do
    case executable(config) do
      nil ->
        {:error,
         "unreal-agent-runner not found on node #{config.node_id}. Run `mix photon.build_runner` there, or set PHOTON_RUNNER."}

      exe ->
        {:ok, exe}
    end
  end

  defp ensure_workspace(config, requested) when requested in [nil, ""] do
    with :ok <- File.mkdir_p(config.workspace), do: {:ok, config.workspace}
  end

  defp ensure_workspace(config, requested) do
    workspace = Path.expand(requested)

    if File.dir?(workspace),
      do: {:ok, workspace},
      else: {:error, "Workspace #{workspace} is not a directory on node #{config.node_id}."}
  end

  @doc "The JSON request passed to the runner as its positional argument."
  def request(session_id, prompt, run_config) do
    %{
      "session_id" => session_id,
      "prompt" => prompt,
      "thinking_level" => run_config["thinking_level"] || "high"
    }
    |> put_present("model", model(run_config))
    |> put_present("system_prompt", run_config["system_prompt"])
    |> put_present("disallowed_tools", run_config["disallowed_tools"])
    |> put_present("max_attempts", parse_int(run_config["max_attempts"]))
  end

  def args(config, session_id, prompt, run_config, workspace) do
    [
      "-workspace",
      workspace,
      "-session-directory",
      Config.runner_sessions_dir(config),
      "-log-directory",
      Config.runner_logs_dir(config),
      Jason.encode!(request(session_id, prompt, run_config))
    ]
  end

  @doc """
  Environment overrides for the child process. `false` unsets a variable so a
  stale value in the node's own environment cannot leak into the run; a blank
  API key therefore falls back to the provider's own variable on this node.
  """
  def env(config, run_config), do: llm_env(config, run_config) ++ scrubbed_env(System.get_env())

  defp llm_env(config, %{"provider" => "mock"}) do
    [
      {"UNREAL_HARNESS_LLM_PROVIDER", "openai"},
      {"UNREAL_HARNESS_LLM_BASE_URL", Config.mock_base_url(config)},
      {"UNREAL_HARNESS_LLM_API_KEY", "mock"}
    ]
  end

  defp llm_env(_config, run_config) do
    [
      {"UNREAL_HARNESS_LLM_PROVIDER", run_config["provider"] || "openai"},
      {"UNREAL_HARNESS_LLM_BASE_URL", blank_to_false(run_config["base_url"])},
      {"UNREAL_HARNESS_LLM_API_KEY", blank_to_false(run_config["api_key"])}
    ]
  end

  # The node's own launch plumbing (release scripts, or the Burrito wrapper
  # of a packaged binary) would otherwise leak into every shell the agent runs.
  @burrito_lib_paths "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib"

  @doc false
  def scrubbed_env(env) do
    unset =
      for {name, _} <- env,
          name in ~w(__BURRITO __BURRITO_BIN_PATH _IS_TTY ROOTDIR BINDIR EMU PROGNAME) or
            String.starts_with?(name, "RELEASE_"),
          do: {name, false}

    library_path =
      case env["LD_LIBRARY_PATH"] do
        nil -> []
        @burrito_lib_paths -> [{"LD_LIBRARY_PATH", false}]
        path -> [{"LD_LIBRARY_PATH", String.replace_suffix(path, ":" <> @burrito_lib_paths, "")}]
      end

    if Map.has_key?(env, "__BURRITO"), do: unset ++ library_path, else: unset
  end

  defp model(%{"provider" => "mock"} = run_config) do
    if run_config["model"] in [nil, ""], do: "mock-model", else: run_config["model"]
  end

  defp model(run_config), do: run_config["model"]

  defp put_present(map, _key, value) when value in [nil, "", []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp blank_to_false(value) when value in [nil, ""], do: false
  defp blank_to_false(value), do: value
end
