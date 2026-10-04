defmodule PhotonNode.Property.InboxTest do
  @moduledoc """
  The inbox accepts the first valid input with an ID and drops later ones,
  across a restart (seeded from the log), and validation never raises.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PhotonCore.LLM.Responses.Request
  alias PhotonNode.Harness.{Context, Inbox}

  defp json_value do
    tree(
      one_of([constant(nil), boolean(), integer(), string(:printable, max_length: 5)]),
      fn leaf ->
        one_of([
          list_of(leaf, max_length: 2),
          optional_map(%{
            "content" => leaf,
            "mode" => one_of([member_of(~w(hard heartbeat settings nap)), leaf]),
            "reason" => leaf,
            "parameters" => leaf
          })
        ])
      end
    )
  end

  defp valid_input(id) do
    one_of([
      map(
        one_of([
          string(:printable, max_length: 5),
          constant([%{"type" => "text", "text" => "hi"}])
        ]),
        fn content ->
          %{"id" => id, "kind" => "external", "payload" => %{"content" => content}}
        end
      ),
      constant(%{
        "id" => id,
        "kind" => "control",
        "payload" => %{"mode" => "hard", "reason" => "stop"}
      }),
      constant(%{
        "id" => id,
        "kind" => "control",
        "payload" => %{"mode" => "heartbeat", "reason" => "hb"}
      }),
      constant(%{
        "id" => id,
        "kind" => "control",
        "payload" => %{"mode" => "settings", "parameters" => %{}}
      }),
      constant(%{"id" => id, "kind" => "crash", "payload" => %{}})
    ])
  end

  defp invalid_input(id) do
    one_of([
      constant(%{"id" => id, "kind" => "external", "payload" => %{}}),
      constant(%{
        "id" => id,
        "kind" => "control",
        "payload" => %{"mode" => "heartbeat", "reason" => ""}
      }),
      constant(%{"id" => id, "kind" => "control", "payload" => %{"mode" => "nap"}}),
      constant(%{"id" => id, "kind" => "mystery"}),
      constant(%{"kind" => "external", "payload" => %{"content" => "no id"}})
    ])
  end

  defp input do
    gen all(
          id <- member_of(~w(a b c d)),
          valid? <- frequency([{4, constant(true)}, {1, constant(false)}]),
          input <- if(valid?, do: valid_input(id), else: invalid_input(id))
        ) do
      {valid?, input}
    end
  end

  property "the first valid input with an ID wins, before and after a restart" do
    check all(
            seed <- list_of(member_of(~w(a b c d)), max_length: 2),
            inputs <- list_of(input(), max_length: 20),
            max_runs: 300
          ) do
      {_inbox, seen, outcomes} =
        Enum.reduce(inputs, {Inbox.new(seed), MapSet.new(seed), []}, fn {valid?, input},
                                                                        {inbox, seen, acc} ->
          expected =
            cond do
              not valid? -> :error
              MapSet.member?(seen, input["id"]) -> :duplicate
              true -> :ok
            end

          case Inbox.accept(inbox, input) do
            {:ok, inbox} -> {inbox, MapSet.put(seen, input["id"]), [{expected, :ok} | acc]}
            :duplicate -> {inbox, seen, [{expected, :duplicate} | acc]}
            {:error, reason} when is_binary(reason) -> {inbox, seen, [{expected, :error} | acc]}
          end
        end)

      for {expected, got} <- outcomes, do: assert(expected == got)
      assert MapSet.subset?(MapSet.new(seed), seen)
    end
  end

  property "validate never raises, whatever the input" do
    check all(
            input <-
              one_of([
                json_value(),
                optional_map(%{
                  "id" => one_of([string(:alphanumeric, max_length: 3), json_value()]),
                  "kind" => one_of([member_of(~w(external control crash)), json_value()]),
                  "payload" => json_value()
                })
              ]),
            max_runs: 300
          ) do
      result = Inbox.validate(input)
      assert result == :ok or match?({:error, reason} when is_binary(reason), result)
    end
  end

  # Spec §5.1: "Only settings may have Parameters. Any other mode with
  # parameters -> control mode "X" does not accept parameters."
  property "only settings controls may carry parameters" do
    check all(
            mode <- member_of(~w(hard heartbeat)),
            reason <- string(:alphanumeric, min_length: 1, max_length: 4),
            params <-
              map(
                list_of({string(:alphanumeric, max_length: 3), integer()}, max_length: 2),
                &Map.new/1
              ),
            max_runs: 50
          ) do
      input = %{
        "id" => "x",
        "kind" => "control",
        "payload" => %{"mode" => mode, "reason" => reason, "parameters" => params}
      }

      assert {:error, _} = Inbox.validate(input)
    end
  end

  # An accepted input is persisted before it reaches the model, so one the
  # request encoder can't handle fails every later turn of the session.
  property "content the inbox accepts can always be encoded into a model request" do
    part =
      one_of([
        map(json_value(), &%{"type" => "text", "text" => &1}),
        optional_map(%{
          "type" => constant("image"),
          "mime" => json_value(),
          "data" => json_value()
        }),
        json_value()
      ])

    check all(content <- list_of(part, max_length: 3), max_runs: 300) do
      input = %{"id" => "x", "kind" => "external", "payload" => %{"content" => content}}

      if Inbox.validate(input) == :ok do
        messages = "sys" |> Context.new() |> Context.add_user(content) |> Context.build()
        assert is_list(Request.encode_messages(messages))
      end
    end
  end
end
