defmodule Photon.DataCase do
  @moduledoc """
  Tests that use the database run synchronously against a real database
  file, emptied before each test, so the harness's processes work as they do
  in production. Tag a test or module `@moduletag :durable` to start the
  assistant's harness for it.

  Settings are reset to the mock model, so nothing calls a real provider.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  using do
    quote do
      import Photon.DataCase
      alias Photon.{Durable, Repo}
    end
  end

  setup tags do
    Photon.DataCase.setup_sandbox(tags)
    :ok
  end

  @tables ~w(digest_items activity questions schedules threads project_files skill_enablements skills projects conversations entries docs tasks submissions signals node_keys machine_ops)

  def setup_sandbox(tags) do
    # One transaction, so SQLite syncs once rather than once per table.
    {:ok, _} =
      Photon.Repo.transaction(fn ->
        for table <- @tables, do: Photon.Repo.query!("DELETE FROM #{table}")
      end)

    File.rm(Photon.Paths.settings_file())
    Photon.Settings.save(%{"provider" => "mock"})

    if tags[:durable] do
      for child <- Photon.Durable.Supervisor.children(), do: start_supervised!(child)
    end

    :ok
  end

  @doc """
  Waits for a conversation commit whose changes satisfy `fun`, for at most
  `timeout` ms in all, however many other commits arrive first. Call
  `Photon.Durable.subscribe/1` first.
  """
  def await_change(conversation_id, fun, timeout \\ 5_000),
    do: await_change_by(conversation_id, fun, System.monotonic_time(:millisecond) + timeout)

  # Checks the deadline before each receive, so a mailbox of commits that
  # don't match can't keep it waiting past the deadline.
  defp await_change_by(conversation_id, fun, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: ExUnit.Assertions.flunk("no matching commit for #{conversation_id}")

    receive do
      {:durable, ^conversation_id, changes} ->
        if fun.(changes), do: changes, else: await_change_by(conversation_id, fun, deadline)
    after
      remaining -> ExUnit.Assertions.flunk("no matching commit for #{conversation_id}")
    end
  end

  @doc "Waits for an entry matching `fun`, whether it is already stored or still to come."
  def await_entry(conversation_id, fun, timeout \\ 5_000) do
    case Enum.find(Photon.Durable.entries(conversation_id), fun) do
      nil ->
        changes = await_change(conversation_id, &Enum.any?(&1.entries, fun), timeout)
        Enum.find(changes.entries, fun)

      entry ->
        entry
    end
  end

  @doc "Waits until the submission settles; returns it."
  def await_settled(conversation_id, submission_id, timeout \\ 5_000) do
    changes =
      await_change(
        conversation_id,
        fn changes ->
          Enum.any?(
            changes.submissions,
            &(&1.id == submission_id and &1.status in ["done", "unanswered"])
          )
        end,
        timeout
      )

    Enum.find(changes.submissions, &(&1.id == submission_id))
  end

  def entry_kinds(conversation_id),
    do: conversation_id |> Photon.Durable.entries() |> Enum.map(& &1.kind)

  def texts(conversation_id, kind) do
    for %{kind: ^kind} = e <- Photon.Durable.entries(conversation_id),
        do: PhotonCore.Message.text_of(e.data["message"])
  end
end
