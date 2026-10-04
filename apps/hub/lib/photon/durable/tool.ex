defmodule Photon.Durable.Tool do
  @moduledoc """
  A tool the model can call. Each call runs as its own durable task
  (`Photon.Durable.ToolTask`), with its intent committed before `execute/2`
  runs. If the hub dies mid-call, the call reruns on the next boot only when
  `replay/0` is `:safe`; otherwise the model gets an "interrupted" result.

  `execute/2` (and `resume/2`) return:

    * `{:ok, content}` or `{:ok, content, details}` - the result; `details`
      is a map kept with it for the UI
    * `{:error, message}` - an error result
    * `{:wait, waiting, state}` - park the call durably until `waiting` holds
      (see `Photon.Durable.Tx.transition/4`), then `resume(state, api)`
    * `{:commit, fun}` - decide the result inside the commit that records
      it: `fun.(tx)` returns one of the results above (but not `:wait` or
      `:commit`), and whatever else it writes with `tx` is kept only if the
      call's result is (not if the call was aborted meanwhile)

  Arguments are validated against `parameters/0` before `execute/2` runs.
  `on_interrupt/2`, if defined, runs in the commit that aborts or fails the
  call, so a tool can hand off work it already started.
  """

  # A contract (with its helpers), which the functional core may name.
  use Boundary, deps: [Photon.Durable]

  alias Photon.Durable.ToolAPI

  @type result ::
          {:ok, PhotonCore.Message.t() | String.t() | list()}
          | {:ok, String.t() | list(), map()}
          | {:error, String.t()}
          | {:wait, map(), map()}
          | {:commit, (Photon.Durable.Tx.t() -> result())}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map(), ToolAPI.t()) :: result()
  @callback resume(state :: map(), ToolAPI.t()) :: result()
  @callback replay() :: :safe | :unsafe
  @callback on_interrupt(ToolAPI.t(), Photon.Durable.Tx.t()) :: any()

  @optional_callbacks resume: 2, replay: 0, on_interrupt: 2

  @doc "The model-facing description of a tool module."
  @spec spec(module()) :: map()
  def spec(module) do
    %{
      "name" => module.name(),
      "description" => module.description(),
      "parameters" => module.parameters()
    }
  end

  @doc "Whether a tool is safe to run again after a hub restart (`:unsafe` unless it says so)."
  @spec replay(module()) :: :safe | :unsafe
  def replay(module) do
    if Photon.Durable.implements?(module, :replay, 0), do: module.replay(), else: :unsafe
  end

  @doc false
  @spec exports?(module(), atom(), arity()) :: boolean()
  defdelegate exports?(module, function, arity), to: Photon.Durable, as: :implements?
end
