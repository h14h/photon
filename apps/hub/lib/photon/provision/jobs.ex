defmodule Photon.Provision.Jobs do
  @moduledoc """
  The provisioning job table, as pure functions: one job per machine,
  keyed by machine name, with its log newest first (the last 300 lines).
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @max_log 300

  @type job :: %{
          action: :install | :uninstall,
          status: :running | :ok | :error,
          log: [String.t()],
          node_id: String.t() | nil,
          started_at: DateTime.t()
        }

  @type t :: %{String.t() => job()}

  @type event :: {:log, String.t()} | {:done, :ok | :error, String.t()}

  @doc "Checks a job's options: the host, SSH user and node name, if given, must be plain names."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(opts) do
    cond do
      not valid?(opts[:host], ~r/\A[A-Za-z0-9.\-]{1,253}\z/) ->
        {:error, "invalid host"}

      opts[:ssh_user] not in [nil, ""] and
          not valid?(opts[:ssh_user], ~r/\A[A-Za-z_][A-Za-z0-9_.\-]{0,31}\z/) ->
        {:error, "invalid SSH user"}

      opts[:node_id] && not valid?(opts[:node_id], ~r/\A[\w.\-]{1,64}\z/) ->
        {:error, "invalid node name"}

      opts[:node_id] == "local" ->
        {:error, "local is the built-in node's name"}

      true ->
        :ok
    end
  end

  defp valid?(value, regex), do: is_binary(value) and value =~ regex

  @doc "`:ok` if `machine` has no job running, so a new one may start."
  @spec idle(t(), String.t()) :: :ok | {:error, String.t()}
  def idle(jobs, machine) do
    if match?(%{status: :running}, jobs[machine]), do: {:error, "already busy"}, else: :ok
  end

  @doc "A job that just started."
  @spec new(:install | :uninstall, map(), DateTime.t()) :: job()
  def new(action, opts, now) do
    %{action: action, status: :running, log: [], node_id: opts[:node_id], started_at: now}
  end

  @doc "A job after an event its task reported."
  @spec apply_event(job(), event()) :: job()
  def apply_event(job, {:log, line}), do: %{job | log: Enum.take([line | job.log], @max_log)}
  def apply_event(job, {:done, :ok, message}), do: %{job | status: :ok, log: [message | job.log]}

  def apply_event(job, {:done, :error, message}),
    do: %{job | status: :error, log: [message | job.log]}

  @doc """
  A job whose task went down with `reason` before it reported an end: it
  failed. A job that had already ended is left as it was.
  """
  @spec task_down(job(), term()) :: job()
  def task_down(%{status: :running} = job, reason) do
    apply_event(job, {:done, :error, "Failed: the job stopped unexpectedly (#{inspect(reason)})"})
  end

  def task_down(job, _reason), do: job
end
