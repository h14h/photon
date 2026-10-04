defmodule Photon.Durable.ToolCall do
  @moduledoc """
  The pure half of a tool call (`Photon.Durable.ToolTask`): whether a call
  runs at all, and the `"tool_result"` entry that records how it ended.

  A call doesn't run when its tool is gone, when its arguments don't decode
  or don't fit the tool's schema, or when it was interrupted by a hub
  restart and its tool isn't safe to run again (`Photon.Durable.Tool`'s
  `replay/0`). Each of those ends the call with a result the model reads.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Durable.Schema, PhotonCore]

  alias Photon.Durable.{Schema, Tx}
  alias PhotonCore.Message

  @typedoc "How a call ended: a tool's result, or one of the harness's own endings."
  @type result ::
          {:ok, term()}
          | {:ok, term(), map()}
          | {:error, String.t()}
          | {:interrupted, String.t()}
          | {:aborted, String.t()}

  @typedoc "What the call's tool declares: its replay safety and argument schema."
  @type tool_facts :: {:safe | :unsafe, map()}

  @doc """
  What a `"run"` step does: `{:execute, args}`, or `{:finish, result}`
  without running the tool. `tool` is nil when the conversation's profile
  no longer has a tool by the call's name.
  """
  @spec plan(Message.tool_call(), non_neg_integer(), tool_facts() | nil) ::
          {:execute, map()} | {:finish, result()}
  def plan(call, _runs, nil = _tool),
    do: {:finish, {:error, "There is no tool named #{inspect(call["name"])}."}}

  def plan(_call, runs, {replay, _parameters}) when runs > 1 and replay != :safe do
    {:finish,
     {:interrupted,
      "The hub restarted while this call was running, so its result is unknown. Check before retrying."}}
  end

  def plan(call, _runs, {_replay, parameters}) do
    with {:ok, args} <- Message.arguments(call),
         :ok <- Schema.validate(args, parameters) do
      {:execute, args}
    else
      {:error, reason} -> {:finish, {:error, "Invalid arguments: #{reason}"}}
    end
  end

  @doc "The result of a `\"resume\"` step whose tool has gone away."
  @spec tool_gone() :: result()
  def tool_gone, do: {:error, "This tool is no longer available."}

  @doc "The result of a call stopped by the user."
  @spec stopped() :: result()
  def stopped, do: {:aborted, "Stopped by the user before it finished."}

  @doc "The transition that parks a call until `waiting` holds, to resume with `state`."
  @spec park(map(), map()) :: Tx.transition()
  def park(waiting, state), do: {:wait, waiting, "resume", %{"state" => state}}

  @doc "The transition that finishes a call whose result had `status`."
  @spec done(String.t()) :: Tx.transition()
  def done(status), do: {:done, %{"result" => status}}

  @doc "The tool module named `name` among a profile's `tools`, if any."
  @spec find_tool([module()], String.t()) :: module() | nil
  def find_tool(tools, name), do: Enum.find(tools, &(&1.name() == name))

  @doc "The status and `\"tool_result\"` entry data that record `result` for `call`."
  @spec result_entry(Message.tool_call(), result()) :: {String.t(), map()}
  def result_entry(call, result) do
    # A case rather than function heads: a tool that returns something else
    # fails its call with the same CaseClauseError message as before.
    {status, content, details} =
      case result do
        {:ok, content} -> {"ok", content, %{}}
        {:ok, content, details} -> {"ok", content, details}
        {:error, message} -> {"error", "Error: " <> message, %{}}
        {:interrupted, message} -> {"interrupted", message, %{}}
        {:aborted, message} -> {"aborted", message, %{}}
      end

    {status,
     %{
       "message" => Message.tool_result(call["id"], content),
       "name" => call["name"],
       "status" => status,
       "details" => details
     }}
  end
end
