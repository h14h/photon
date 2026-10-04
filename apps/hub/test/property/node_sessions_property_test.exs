defmodule Photon.Property.NodeSessionsTest do
  @moduledoc """
  The hub mirrors a node's session log by offset. Under any mix of
  duplicated, reordered and dropped deliveries, plus the resyncs the hub asks
  for, its copy is always a prefix of the node's log and, after a reconnect,
  exactly the log. The outbox then settles exactly as the log says.
  """

  use Photon.DataCase, async: false
  use ExUnitProperties

  alias Photon.NodeSessions

  @moduletag :durable
  @node "n1"

  defp runs(default), do: String.to_integer(System.get_env("PHOTON_PROPERTY_RUNS", "#{default}"))

  ## Generators

  defp text, do: string(:utf8, max_length: 12)

  defp noise do
    tree(
      one_of([constant(nil), boolean(), integer(), float(), text()]),
      fn leaf ->
        one_of([
          list_of(leaf, max_length: 3),
          map(list_of({string(:alphanumeric, max_length: 4), leaf}, max_length: 3), &Map.new/1)
        ])
      end
    )
  end

  defp record(input_ids) do
    frequency([
      {3,
       map(member_of(input_ids ++ ["hb_other"]), fn id ->
         %{
           "kind" => "input",
           "data" => %{
             "id" => id,
             "kind" => "external",
             "payload" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
           }
         }
       end)},
      {2, constant(%{"kind" => "state", "data" => %{"state" => "running"}})},
      {2,
       gen all(
             state <- member_of(~w(idle stopped)),
             answer <- one_of([constant(nil), text()]),
             failure <-
               one_of([constant(nil), map(text(), &%{"kind" => "http", "message" => &1})])
           ) do
         %{
           "kind" => "state",
           "data" => %{"state" => state, "answer" => answer, "failure" => failure}
         }
       end},
      {3,
       map({member_of(~w(turn model_response tool_call_status operation)), noise()}, fn {kind,
                                                                                         data} ->
         %{"kind" => kind, "data" => %{"x" => data}}
       end)}
    ])
  end

  defp node_log(input_ids) do
    gen all(body <- list_of(record(input_ids), max_length: 14)) do
      header = %{"kind" => "session", "data" => %{"version" => 1, "config" => %{}}}

      [header | body]
      |> Enum.with_index()
      |> Enum.map(fn {r, i} -> Map.merge(r, %{"seq" => i, "at" => "2026-10-03T00:00:00Z"}) end)
    end
  end

  defp action do
    frequency([
      {6, map(non_negative_integer(), &{:deliver, &1})},
      {3, map(integer(1..6), &{:resync, &1})},
      {1, map(non_negative_integer(), &{:other_node, &1})}
    ])
  end

  ## Model

  defp failure_text(%{"message" => message}), do: message
  defp failure_text(message) when is_binary(message), do: message
  defp failure_text(_), do: nil

  # The outbox as the log says it should be: queued until accepted, then
  # done with the answer of the first idle or stop after that.
  defp expected_inputs(log, ids) do
    Enum.reduce(log, Map.new(ids, &{&1, {"queued", nil, nil}}), fn
      %{"kind" => "input", "data" => %{"id" => id}}, acc ->
        if match?(%{^id => {"queued", _, _}}, acc),
          do: Map.put(acc, id, {"accepted", nil, nil}),
          else: acc

      %{"kind" => "state", "data" => %{"state" => state} = d}, acc
      when state in ~w(idle stopped) ->
        answer =
          if state == "stopped", do: d["answer"] || "Stopped before finishing.", else: d["answer"]

        failure = if state == "stopped", do: "stopped", else: failure_text(d["failure"])

        Map.new(acc, fn
          {id, {"accepted", _, _}} -> {id, {"done", answer, failure}}
          other -> other
        end)

      _, acc ->
        acc
    end)
  end

  ## Properties

  property "the hub's copy is a prefix of the node log and converges to it" do
    check all(
            n_inputs <- integer(1..3),
            run <- constant(System.unique_integer([:positive])),
            ids = for(i <- 1..n_inputs, do: "in_#{run}_#{i}"),
            log <- node_log(ids),
            actions <- list_of(action(), max_length: 40),
            max_runs: runs(80)
          ) do
      sid = "ns_#{run}"
      {:ok, _session, _input} = NodeSessions.start(@node, "go", id: sid, input_id: hd(ids))
      for id <- tl(ids), do: {:ok, _} = NodeSessions.send_input(sid, "more", input_id: id)

      json = log |> Jason.encode!() |> Jason.decode!()
      size = length(log)

      prefix_holds = fn ->
        session = NodeSessions.get(sid)
        assert NodeSessions.events(sid) == Enum.take(json, session.next_offset)
        session.next_offset
      end

      ingest = fn offset -> NodeSessions.ingest(sid, @node, offset, Enum.at(log, offset)) end

      # The node replays from wherever the hub last said it was missing records.
      Enum.reduce(actions, 0, fn
        {:deliver, i}, from ->
          offset = rem(i, size)

          from =
            case ingest.(offset) do
              :ok -> from
              :duplicate -> from
              {:gap, expected} -> expected
            end

          prefix_holds.()
          from

        {:resync, k}, from ->
          for offset <- from..min(from + k - 1, size - 1)//1, do: ingest.(offset)
          prefix_holds.()

        {:other_node, i}, from ->
          offset = rem(i, size)

          assert NodeSessions.ingest(sid, "intruder", offset, %{
                   "kind" => "state",
                   "data" => %{"state" => "idle"}
                 }) == :ignored

          prefix_holds.()
          from
      end)

      # Reconnect: the join reply says where to resume.
      from = NodeSessions.sync_for(@node)[sid]
      for offset <- from..(size - 1)//1, do: assert(ingest.(offset) == :ok)

      assert prefix_holds.() == size
      assert NodeSessions.events(sid) == json

      for {id, {state, answer, failure}} <- expected_inputs(json, ids) do
        input = NodeSessions.input(id)

        assert {input.state, input.answer, input.failure} == {state, answer, failure},
               "input #{id}"

        if state == "done" do
          assert Photon.Durable.signal_payload("node_input:" <> id) ==
                   %{"session_id" => sid, "answer" => answer, "failure" => failure}
        end
      end

      last_state = json |> Enum.filter(&(&1["kind"] == "state")) |> List.last()

      assert NodeSessions.get(sid).status ==
               if(last_state, do: last_state["data"]["state"], else: "pending")
    end
  end

  # A record the hub can't store must not crash the channel: it would crash
  # again on every replay and stall the session's mirror for good.
  property "ingest never raises on a record of arbitrary JSON" do
    check all(
            kind <- member_of(~w(input state turn)),
            data <-
              one_of([
                noise(),
                optional_map(%{
                  "id" => noise(),
                  "state" => one_of([member_of(~w(running idle stopped)), noise()]),
                  "answer" => noise(),
                  "failure" => noise()
                })
              ]),
            max_runs: 200
          ) do
      sid = "ns_fuzz_#{System.unique_integer([:positive])}"
      {:ok, _, _} = NodeSessions.start(@node, "go", id: sid)
      result = NodeSessions.ingest(sid, @node, 0, %{"seq" => 0, "kind" => kind, "data" => data})
      assert result == :ok
    end
  end
end
