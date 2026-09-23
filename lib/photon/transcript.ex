defmodule Photon.Transcript do
  @moduledoc """
  Folds runner events into a conversation view.

  Tool results arrive asynchronously: a call's `tool_call_status` may be
  recorded several times (running, then terminal) and after later model
  turns, so each result updates its originating tool entry in place.
  """

  @running ~w(ready awaiting canceling)

  defstruct entries: [],
            calls: %{},
            usage: %{input: 0, cached: 0, output: 0, reasoning: 0},
            turns: 0,
            responses: 0,
            next_id: 0

  def new, do: %__MODULE__{}

  def build(events), do: Enum.reduce(events, new(), &apply_event(&2, &1))

  @doc "Entries in display order."
  def entries(%__MODULE__{entries: entries}), do: Enum.reverse(entries)

  def apply_event(t, %{"type" => "error", "message" => message}),
    do: push(t, %{type: :error, text: message})

  def apply_event(t, %{"type" => "stderr", "message" => message}),
    do: push(t, %{type: :stderr, text: message})

  # Operations still in flight when the runner exits are shown as interrupted.
  # The harness may recover them on resume, which records a newer status.
  def apply_event(t, %{"type" => "exit", "status" => status}) do
    entries =
      Enum.map(t.entries, fn
        %{type: :tool, status: s} = e when s in [:pending, :running] ->
          %{e | status: :interrupted}

        e ->
          e
      end)

    push(%{t | entries: entries}, %{type: :exit, status: status})
  end

  def apply_event(t, %{"Kind" => kind, "Data" => data} = item) do
    apply_item(t, kind, data, item["RecordedAt"])
  end

  def apply_event(t, _unknown), do: t

  defp apply_item(t, "input", %{"Kind" => "external", "Payload" => payload}, at) do
    push(t, %{type: :user, text: payload_text(payload), at: at})
  end

  defp apply_item(t, "input", %{"Kind" => kind, "Payload" => payload}, at) do
    push(t, %{type: :control, text: control_text(kind, payload), at: at})
  end

  defp apply_item(t, "input", %{"Kind" => kind}, at),
    do: push(t, %{type: :control, text: kind, at: at})

  defp apply_item(t, "turn", _data, _at), do: %{t | turns: t.turns + 1}

  defp apply_item(t, "fork", data, at) do
    push(t, %{type: :control, text: "forked from #{data["ParentID"]}", at: at})
  end

  defp apply_item(t, "model_response", %{"Response" => response}, at) do
    t = %{t | responses: t.responses + 1, usage: add_usage(t.usage, response["Usage"] || %{})}
    meta = %{stop: response["Stop"], usage: response["Usage"], at: at}

    t =
      Enum.reduce(response["Output"] || [], t, fn
        %{"Type" => "message", "Data" => %{"Text" => text}}, t ->
          push(t, %{type: :assistant, text: text, meta: meta})

        %{"Type" => "reasoning", "Data" => data}, t ->
          case data["Summary"] || [] do
            [] -> t
            summary -> push(t, %{type: :reasoning, text: Enum.join(summary, "\n\n")})
          end

        %{"Type" => "tool_call", "Data" => call}, t ->
          push_call(t, call, at)

        other, t ->
          push(t, %{type: :control, text: "unhandled output #{other["Type"]}"})
      end)

    case response["Failure"] do
      %{"Message" => message} = failure ->
        push(t, %{type: :error, text: "#{failure["Code"]}: #{message}"})

      _ ->
        t
    end
  end

  defp apply_item(t, "tool_call_status", %{"CallID" => call_id} = data, at) do
    result = tool_result(data) |> Map.put(:updated_at, at)

    case t.calls do
      %{^call_id => id} ->
        update(t, id, &Map.merge(&1, result))

      _ ->
        push(
          t,
          Map.merge(%{type: :tool, call_id: call_id, name: "?", args: %{}, raw_args: ""}, result)
        )
    end
  end

  defp apply_item(t, kind, _data, _at),
    do: push(t, %{type: :control, text: "unhandled item #{kind}"})

  defp push_call(t, call, at) do
    raw = call["Arguments"] || ""

    args =
      case Jason.decode(raw) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    t =
      push(t, %{
        type: :tool,
        call_id: call["CallID"],
        name: call["Name"],
        args: args,
        raw_args: raw,
        status: :pending,
        at: at
      })

    %{t | calls: Map.put(t.calls, call["CallID"], t.next_id - 1)}
  end

  @doc false
  def tool_result(%{"Status" => status} = data) do
    ops = data["Operations"] || []

    cond do
      status["Error"] not in [nil, ""] and ops == [] ->
        %{status: :error, error: status["Error"]}

      op = List.first(ops) ->
        operation_result(op)

      (status["WaitingFor"] || []) != [] ->
        %{status: :running}

      true ->
        %{status: :completed}
    end
  end

  defp operation_result(%{"Status" => op_status} = op) when op_status in @running do
    %{status: :running, op_type: op["Type"]}
  end

  defp operation_result(%{"Type" => "shell", "Status" => op_status, "State" => state}) do
    result = state["Result"] || %{}

    %{
      status: String.to_atom(op_status),
      stdout: result["Out"],
      stderr: result["Err"],
      exit_code: result["ExitCode"],
      error: state["TerminalError"],
      out_path: state["OutPath"],
      err_path: state["ErrPath"]
    }
  end

  defp operation_result(%{"Type" => "view_image", "Status" => op_status, "State" => state}) do
    result = state["Result"] || %{}

    image =
      if result["Content"] not in [nil, ""],
        do: %{mime: result["EncodedMIMEType"], data: result["Content"]}

    %{
      status: String.to_atom(op_status),
      image: image,
      error: result["Error"],
      image_meta: %{
        original_mime: result["OriginalMIMEType"],
        width: result["OriginalWidth"],
        height: result["OriginalHeight"],
        scale: result["ScaleRatio"]
      }
    }
  end

  defp operation_result(%{"Status" => op_status, "State" => state} = op) do
    %{status: String.to_atom(op_status), op_type: op["Type"], state: state}
  end

  defp operation_result(op), do: %{status: :completed, op_type: op["Type"]}

  defp add_usage(acc, usage) do
    %{
      input: acc.input + (usage["InputTokens"] || 0),
      cached: acc.cached + (usage["CachedInputTokens"] || 0),
      output: acc.output + (usage["OutputTokens"] || 0),
      reasoning: acc.reasoning + (usage["ReasoningTokens"] || 0)
    }
  end

  defp payload_text(text) when is_binary(text), do: text
  defp payload_text(other), do: Jason.encode!(other)

  defp control_text("control", %{"Mode" => "settings", "Parameters" => params}) do
    "settings · reasoning #{params["ReasoningEffort"] || "default"}"
  end

  defp control_text("control", %{"Mode" => "when_idle"}), do: "stop when idle"
  defp control_text("control", %{"Mode" => "hard"} = p), do: "hard stop #{p["Reason"]}"
  defp control_text("control", %{"Mode" => "heartbeat"} = p), do: "heartbeat · #{p["Reason"]}"
  defp control_text(kind, payload), do: "#{kind} #{payload_text(payload)}"

  defp push(t, entry) do
    %{t | entries: [Map.put(entry, :id, t.next_id) | t.entries], next_id: t.next_id + 1}
  end

  defp update(t, id, fun) do
    entries = Enum.map(t.entries, fn e -> if e.id == id, do: fun.(e), else: e end)
    %{t | entries: entries}
  end
end
