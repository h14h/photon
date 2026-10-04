defmodule Photon.Property.DurableContextTest do
  @moduledoc """
  `Photon.Durable.Context.messages/1` must turn any transcript into a
  conversation the provider accepts: each assistant tool call directly
  followed by exactly one result per call, no tool message elsewhere, and
  nothing from before the newest reset.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Photon.Durable.{Context, Entry}
  alias PhotonCore.Message

  @ids ~w(c1 c2 c3 c4 c5)

  defp entry do
    frequency([
      {3,
       map(
         string(:alphanumeric, max_length: 4),
         &{"user", %{"message" => Message.user("u" <> &1)}}
       )},
      {3,
       gen all(
             text <- string(:alphanumeric, max_length: 4),
             ids <- map(list_of(member_of(@ids), max_length: 3), &Enum.uniq/1)
           ) do
         calls = for id <- ids, do: %{"id" => id, "name" => "wait", "arguments" => "{}"}
         {"assistant", %{"message" => Message.assistant("a" <> text, calls)}}
       end},
      {4,
       map(
         member_of(@ids),
         &{"tool_result", %{"message" => Message.tool_result(&1, "r:" <> &1), "status" => "ok"}}
       )},
      {1, constant({"error", %{"message" => "Stopped."}})},
      {1,
       map(
         one_of([
           constant(nil),
           constant(""),
           string(:alphanumeric, min_length: 1, max_length: 4)
         ]),
         &{"reset", %{"handoff" => &1}}
       )}
    ])
  end

  defp transcript do
    gen all(entries <- list_of(entry(), max_length: 25)) do
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {{kind, data}, seq} ->
        %Entry{id: "e#{seq}", conversation_id: "c", seq: seq, kind: kind, data: data}
      end)
    end
  end

  defp walk([]), do: :ok

  defp walk([%{"role" => "assistant"} = a | rest]) do
    ids = for c <- Message.tool_calls(a), do: c["id"]
    {results, rest} = Enum.split(rest, length(ids))

    cond do
      Enum.map(results, &(&1["role"] == "tool" && &1["tool_call_id"])) != ids ->
        {:error, "calls #{inspect(ids)} answered by #{inspect(results)}"}

      match?([%{"role" => "tool"} | _], rest) ->
        {:error, "extra tool message after #{inspect(ids)}"}

      true ->
        walk(rest)
    end
  end

  defp walk([%{"role" => "tool"} = t | _]), do: {:error, "orphan #{inspect(t)}"}
  defp walk([%{"role" => "user"} | rest]), do: walk(rest)
  defp walk([other | _]), do: {:error, "unexpected #{inspect(other)}"}

  property "messages always pair every tool call with exactly one result" do
    check all(entries <- transcript(), max_runs: 400) do
      messages = Context.messages(entries)
      assert walk(messages) == :ok, inspect(Enum.map(entries, &{&1.kind, &1.data}), pretty: true)
    end
  end

  property "the model sees nothing from before the newest reset" do
    check all(entries <- transcript(), max_runs: 300) do
      messages = Context.messages(entries)

      case List.last(Enum.filter(entries, &(&1.kind == "reset"))) do
        nil ->
          :ok

        reset ->
          older =
            for e <- entries,
                e.seq < reset.seq,
                e.kind in ~w(user assistant),
                do: Message.text_of(e.data["message"])

          newer =
            for e <- entries,
                e.seq > reset.seq,
                e.kind in ~w(user assistant),
                do: Message.text_of(e.data["message"])

          seen = Enum.map(messages, &Message.text_of/1)

          for text <- older,
              text not in newer,
              do: refute(text in seen, "#{text} survived the reset")
      end
    end
  end

  property "a result that directly follows its call is the one the model sees" do
    check all(entries <- transcript(), max_runs: 300) do
      messages = Context.messages(entries)

      # Results in the run right after an assistant entry, by call ID.
      for {%Entry{kind: "assistant"} = a, i} <- Enum.with_index(entries),
          calls = Message.tool_calls(a.data["message"]),
          calls != [] do
        run = entries |> Enum.drop(i + 1) |> Enum.take_while(&(&1.kind in ~w(tool_result error)))

        for %{"id" => id} <- calls do
          results =
            for %Entry{kind: "tool_result", data: %{"message" => %{"tool_call_id" => ^id} = r}} <-
                  run,
                do: r

          if results != [] and not reset_after?(entries, a) do
            assert Enum.any?(results, &(&1 in messages)), "the result for #{id} was replaced"
          end
        end
      end
    end
  end

  defp reset_after?(entries, entry),
    do: Enum.any?(entries, &(&1.kind == "reset" and &1.seq > entry.seq))
end
