defmodule PhotonNode.Property.StoreTest do
  @moduledoc """
  A session log survives a crash that tears its last line at any byte:
  reopening keeps every complete record, drops the torn tail, and later
  appends continue the sequence so `seq` always equals the line index.
  """

  use PhotonNode.HarnessCase, async: false
  use ExUnitProperties

  alias PhotonNode.Harness.Store

  defp record_data do
    one_of([
      fixed_map(%{
        "id" => string(:alphanumeric, max_length: 6),
        "kind" => constant("external"),
        "payload" => fixed_map(%{"content" => string(:utf8, max_length: 12)})
      }),
      fixed_map(%{
        "state" => member_of(~w(running idle stopped)),
        "answer" => one_of([constant(nil), string(:utf8, max_length: 16)])
      }),
      fixed_map(%{
        "turn_id" => string(:alphanumeric, max_length: 6),
        "text" => string(:utf8, max_length: 30)
      })
    ])
  end

  defp record do
    gen all(
          kind <- member_of(~w(input state turn model_response operation)),
          data <- record_data()
        ) do
      {kind, data}
    end
  end

  property "a log torn at any byte reopens to its complete records and keeps appending" do
    check all(
            records <- list_of(record(), min_length: 1, max_length: 5),
            cut <- non_negative_integer(),
            {kind, data} <- record(),
            max_runs: 80
          ) do
      id = "torn" <> Integer.to_string(System.unique_integer([:positive]))
      {store, header} = Store.create(id, %{"model" => "m"})

      store =
        Enum.reduce(records, store, fn {kind, data}, store ->
          {store, _record} = Store.append(store, kind, data)
          store
        end)

      Store.close(store)
      before = Store.read(id)
      assert length(before) == length(records) + 1

      # Tear the file anywhere after the header line.
      body = File.read!(Store.path(id))
      header_end = elem(:binary.match(body, "\n"), 0) + 1
      size = header_end + rem(cut, byte_size(body) - header_end + 1)
      File.write!(Store.path(id), binary_part(body, 0, size))

      complete = body |> binary_part(0, size) |> String.split("\n") |> length() |> Kernel.-(1)
      assert {:ok, store, reopened} = Store.open(id)
      assert reopened == Enum.take(before, complete)
      assert hd(reopened)["data"] == header["data"]

      {store, appended} = Store.append(store, kind, data)
      Store.close(store)

      after_append = Store.read(id)
      assert after_append == reopened ++ [appended]
      assert Enum.map(after_append, & &1["seq"]) == Enum.to_list(0..(length(after_append) - 1))
      Store.delete(id)
    end
  end

  property "read never raises on a log with a torn tail" do
    check all(
            records <- list_of(record(), max_length: 3),
            garbage <- binary(max_length: 20),
            max_runs: 40
          ) do
      id = "garbage" <> Integer.to_string(System.unique_integer([:positive]))
      {store, _} = Store.create(id, %{})

      store =
        Enum.reduce(records, store, fn {kind, data}, store ->
          elem(Store.append(store, kind, data), 0)
        end)

      Store.close(store)
      # A torn tail has no newline (records never contain a raw one).
      tail = String.replace(garbage, "\n", "")
      File.write!(Store.path(id), tail, [:append])

      assert length(Store.read(id)) == length(records) + 1
      Store.delete(id)
    end
  end
end
