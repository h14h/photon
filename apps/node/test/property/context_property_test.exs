defmodule PhotonNode.Property.ContextTest do
  @moduledoc """
  `Context.build/1` must always produce a conversation Chat Completions
  accepts: every assistant tool call directly followed by exactly one result
  per call, and no tool message anywhere else. It must also lose nothing:
  every user input and every finished result shows up exactly once.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PhotonCore.Message
  alias PhotonNode.Harness.Context

  ## Generators

  # Operations the coordinator performs on a context. Calls are numbered as
  # they are made; results refer to a call by index (or to an unknown call).
  defp op do
    frequency([
      {3, map(string(:alphanumeric, max_length: 4), &{:user, &1})},
      {3, map(integer(0..3), &{:response, &1})},
      {5, map({integer(0..20), boolean()}, fn {i, running} -> {:result, i, running} end)},
      {1, constant({:orphan_result})},
      {3, constant(:commit)}
    ])
  end

  defp ops, do: list_of(op(), max_length: 30)

  # Applies ops, tracking what the model must eventually see. Each call gets
  # running results freely but at most one finished result, as in the
  # coordinator. `reuse?` makes responses reuse earlier call IDs, as some
  # providers do across turns.
  defp run(ops, reuse? \\ false) do
    init = %{
      ctx: Context.new("sys"),
      calls: [],
      finished: MapSet.new(),
      users: [],
      results: %{},
      n: 0
    }

    Enum.reduce(ops, init, &apply_op(&1, &2, reuse?))
  end

  defp apply_op({:user, text}, s, _reuse?) do
    text = "u#{s.n}:" <> text
    %{s | ctx: Context.add_user(s.ctx, text), users: s.users ++ [text], n: s.n + 1}
  end

  defp apply_op({:response, k}, s, reuse?) do
    ids = for i <- 1..k//1, do: response_call_id(s, i, reuse?)
    calls = for id <- ids, do: %{"id" => id, "name" => "Bash", "arguments" => "{}"}
    ctx = Context.add_response(s.ctx, Message.assistant("a#{s.n}", calls))
    %{s | ctx: ctx, calls: s.calls ++ Enum.uniq(ids), n: s.n + 1}
  end

  defp apply_op({:result, _i, _running}, %{calls: []} = s, _reuse?), do: s

  defp apply_op({:result, i, running}, s, _reuse?) do
    id = Enum.at(s.calls, rem(i, length(s.calls)))

    cond do
      MapSet.member?(s.finished, id) -> s
      running -> %{s | ctx: Context.add_tool_result(s.ctx, id, "Bash", [], true)}
      true -> finish_call(s, id)
    end
  end

  defp apply_op({:orphan_result}, s, _reuse?) do
    ctx = Context.add_tool_result(s.ctx, "ghost#{s.n}", "Bash", [Message.text("ghost")], false)
    %{s | ctx: ctx, n: s.n + 1}
  end

  defp apply_op(:commit, s, _reuse?), do: %{s | ctx: Context.commit(s.ctx)}

  # With `reuse?`, every other call reuses an earlier call's ID.
  defp response_call_id(%{calls: [_ | _]} = s, i, true = _reuse?) when rem(s.n + i, 2) == 0,
    do: Enum.at(s.calls, rem(s.n * 7 + i, length(s.calls)))

  defp response_call_id(s, i, _reuse?), do: "call#{s.n}_#{i}"

  defp finish_call(s, id) do
    text = "r#{s.n}:#{id}"
    ctx = Context.add_tool_result(s.ctx, id, "Bash", [Message.text(text)], false)

    %{
      s
      | ctx: ctx,
        finished: MapSet.put(s.finished, id),
        results: Map.put(s.results, id, text),
        n: s.n + 1
    }
  end

  ## Checks

  # Walks the conversation; returns :ok or {:error, why, index}.
  defp well_formed(messages), do: walk(messages, 0)

  defp walk([], _i), do: :ok

  defp walk([%{"role" => "assistant"} = a | rest], i) do
    ids = for c <- Message.tool_calls(a), do: c["id"]
    {results, rest} = Enum.split(rest, length(ids))
    result_ids = for r <- results, do: r["role"] == "tool" && r["tool_call_id"]

    cond do
      result_ids != ids -> {:error, "calls #{inspect(ids)} answered by #{inspect(result_ids)}", i}
      match?([%{"role" => "tool"} | _], rest) -> {:error, "extra tool message", i}
      true -> walk(rest, i + 1 + length(ids))
    end
  end

  defp walk([%{"role" => "tool"} | _], i), do: {:error, "orphan tool message", i}
  defp walk([%{"role" => "user"} | rest], i), do: walk(rest, i + 1)

  defp texts(messages),
    do: Enum.flat_map(messages, &for(%{"type" => "text", "text" => t} <- &1["content"], do: t))

  ## Properties

  property "build always yields well-formed tool pairing" do
    check all(ops <- ops(), max_runs: 300) do
      messages = Context.build(run(ops).ctx)
      assert well_formed(messages) == :ok, inspect(messages, pretty: true)
    end
  end

  property "build pairs well even when providers reuse call IDs across turns" do
    check all(ops <- ops(), max_runs: 300) do
      messages = Context.build(run(ops, true).ctx)
      assert well_formed(messages) == :ok, inspect(messages, pretty: true)
    end
  end

  property "every user input and every finished result appears exactly once" do
    check all(ops <- ops(), max_runs: 300) do
      s = run(ops)
      all = texts(Context.build(s.ctx))

      for text <- s.users, do: assert(Enum.count(all, &(&1 == text)) == 1, "user #{text}")

      for {_id, text} <- s.results,
          do: assert(Enum.count(all, &(&1 == text)) == 1, "result #{text} in #{inspect(all)}")

      # User inputs keep their order.
      assert Enum.filter(all, &(String.starts_with?(&1, "u") and &1 in s.users)) == s.users
    end
  end

  property "build is a pure function of the context" do
    check all(ops <- ops(), max_runs: 100) do
      ctx = run(ops).ctx
      assert Context.build(ctx) == Context.build(ctx)
    end
  end
end
