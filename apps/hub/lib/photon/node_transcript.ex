defmodule Photon.NodeTranscript do
  @moduledoc """
  Folds a node session's log records into display items, in order:

    * `:user` - a message the session was given
    * `:assistant` - the agent's text (and reasoning, when the model shares it)
    * `:tool` - a tool call; its status and output update in place as later
      records arrive (`:pending`, `:running`, `:done`, `:error`, `:canceled`)
    * `:notice` - heartbeats, settings changes, stops and model failures

  `fold/2` returns the new transcript and the items it added or changed,
  so a LiveView stream can insert just those.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Message

  defstruct items: %{}, order: [], calls: %{}, next: 0, usage: %{"input" => 0, "output" => 0}

  @typedoc "A display item: a map with `:id`, `:type` and the fields of its type."
  @type item :: %{
          required(:id) => String.t(),
          required(:type) => atom(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          items: %{String.t() => item()},
          order: [String.t()],
          calls: %{String.t() => String.t()},
          next: non_neg_integer(),
          usage: %{String.t() => non_neg_integer()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The transcript of a whole log."
  @spec build([map()]) :: t()
  def build(records) do
    Enum.reduce(records, new(), fn record, t -> t |> fold(record) |> elem(0) end)
  end

  @doc "The items, in order."
  @spec items(t()) :: [item()]
  def items(%__MODULE__{} = t), do: t.order |> Enum.reverse() |> Enum.map(&t.items[&1])

  @doc "Applies one record; returns `{transcript, changed_items}`."
  @spec fold(t(), map()) :: {t(), [item()]}
  def fold(
        t,
        %{
          "kind" => "input",
          "data" => %{"kind" => "external", "payload" => %{"content" => content}}
        } = r
      ) do
    parts = Message.parts(content)

    push(t, %{
      type: :user,
      text: Message.text_of(parts),
      images: length(Message.images(parts)),
      at: r["at"]
    })
  end

  def fold(t, %{"kind" => "input", "data" => %{"kind" => "control", "payload" => payload}} = r),
    do: control(t, payload["mode"], payload, r["at"])

  def fold(t, %{"kind" => "model_response", "data" => %{"response" => response}} = r) do
    t = %{t | usage: add_usage(t.usage, response["usage"])}
    response(t, response["message"], response, r["at"])
  end

  def fold(t, %{"kind" => "tool_call_status", "data" => %{"call_id" => call_id} = data}) do
    case t.calls do
      %{^call_id => id} -> update(t, id, &Map.merge(&1, status_fields(data)))
      _ -> {t, []}
    end
  end

  def fold(t, %{"kind" => "state", "data" => %{"state" => "stopped"}} = r) do
    push(t, %{type: :notice, kind: :stop, text: "Stopped", at: r["at"]})
  end

  def fold(t, _record), do: {t, []}

  defp control(t, "heartbeat", _payload, at) do
    push(t, %{
      type: :notice,
      kind: :heartbeat,
      text: "Heartbeat: still waiting on running commands",
      at: at
    })
  end

  defp control(t, "hard", _payload, at),
    do: push(t, %{type: :notice, kind: :stop, text: "Stop requested", at: at})

  defp control(t, "settings", payload, at) do
    push(t, %{
      type: :notice,
      kind: :settings,
      text: settings_text(payload["parameters"]),
      at: at
    })
  end

  defp control(t, _mode, _payload, _at), do: {t, []}

  # A response without a message is a failed model request.
  defp response(t, nil, response, at) do
    message = get_in(response, ["failure", "message"]) || "the model request failed"

    push(t, %{
      type: :notice,
      kind: :failure,
      text: "Couldn't reach the model: " <> message,
      at: at
    })
  end

  defp response(t, message, _response, at) do
    {t, changed} = assistant_text(t, message, Message.text_of(message), at)

    {t, changed} =
      Enum.reduce(Message.tool_calls(message), {t, Enum.reverse(changed)}, fn call, {t, acc} ->
        {t, [item]} = add_call(t, call, at)
        {t, [item | acc]}
      end)

    {t, Enum.reverse(changed)}
  end

  # Text or reasoning makes an assistant item; a response with only tool
  # calls doesn't.
  defp assistant_text(t, message, text, at) do
    if text != "" or message["reasoning"] not in [nil, ""],
      do: push(t, %{type: :assistant, text: text, reasoning: message["reasoning"], at: at}),
      else: {t, []}
  end

  defp add_call(t, call, at) do
    {t, [item]} =
      push(t, %{
        type: :tool,
        call_id: call["id"],
        name: call["name"],
        args: arguments(call),
        status: :pending,
        at: at
      })

    {%{t | calls: Map.put(t.calls, call["id"], item.id)}, [item]}
  end

  defp arguments(call) do
    case Message.arguments(call) do
      {:ok, args} -> args
      _ -> %{}
    end
  end

  defp status_fields(%{"status" => %{"error" => error}}) when error not in [nil, ""] do
    %{status: :error, output: error}
  end

  defp status_fields(%{"operations" => [op | _]}) do
    case op["status"] do
      status when status in ["ready", "awaiting", "canceling"] ->
        %{status: :running, op: op["id"]}

      status ->
        base = %{status: op_status(status), op: op["id"]}
        Map.merge(base, result_fields(op["type"], op["state"] || %{}))
    end
  end

  defp status_fields(_data), do: %{status: :running}

  defp result_fields("shell", state) do
    result = state["result"] || %{}

    %{
      output: result["out"],
      stderr: result["err"],
      exit_code: result["exit_code"],
      error: blank_nil(state["terminal_error"])
    }
  end

  defp result_fields("view_image", state) do
    case state["result"] || %{} do
      %{"content" => content} = result when content not in [nil, false] ->
        %{image: %{mime: result["mime"], data: content}, output: result["path"]}

      result ->
        %{error: result["error"]}
    end
  end

  defp result_fields("skill_use", state) do
    %{output: "Loaded the skill's instructions.", error: blank_nil(state["terminal_error"])}
  end

  defp result_fields(_type, _state), do: %{}

  defp op_status("completed"), do: :done
  defp op_status("canceled"), do: :canceled
  defp op_status(_), do: :error

  defp settings_text(params) do
    model = params["model"] && params["model"] |> String.split("/") |> List.last()

    "Model settings: #{model || "default"}" <>
      if(params["reasoning"], do: ", reasoning #{params["reasoning"]}", else: "")
  end

  defp push(t, item) do
    id = "i#{t.next}"
    item = Map.put(item, :id, id)
    {%{t | items: Map.put(t.items, id, item), order: [id | t.order], next: t.next + 1}, [item]}
  end

  defp update(t, id, fun) do
    item = fun.(t.items[id])
    {%{t | items: Map.put(t.items, id, item)}, [item]}
  end

  defp add_usage(acc, nil), do: acc

  defp add_usage(acc, usage) do
    %{
      "input" => acc["input"] + (usage["input"] || 0),
      "output" => acc["output"] + (usage["output"] || 0)
    }
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
