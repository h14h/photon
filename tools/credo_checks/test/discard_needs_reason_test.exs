defmodule PhotonCredo.Check.DiscardNeedsReasonTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.DiscardNeedsReason

  test "a bare discard with a reason above passes" do
    ~S"""
    defmodule App.Pusher do
      def push(socket, payload) do
        # A lost push is replayed on the next join.
        _ = Socket.push(socket, payload)
        :ok
      end
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason)
    |> refute_issues()
  end

  test "a bare discard with a trailing reason passes" do
    ~S"""
    defmodule App.Timer do
      def cancel(ref), do: _ = Process.cancel_timer(ref) # stale timers are ignored
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason)
    |> refute_issues()
  end

  test "a bare discard without a reason is reported" do
    ~S"""
    defmodule App.Files do
      def clean(path) do
        _ = File.rm(path)
        :ok
      end
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason)
    |> assert_issue(fn issue -> assert issue.line_no == 3 end)
  end

  test "a credo directive above doesn't count as a reason" do
    ~S"""
    defmodule App.Files do
      def clean(path) do
        # credo:disable-for-next-line
        _ = File.rm(path)
      end
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason)
    |> assert_issue()
  end

  test "a named discard of a call that may fail needs a reason" do
    ~S"""
    defmodule App.Files do
      def save(path, data) do
        _result = File.write(path, data)
        :ok
      end
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason)
    |> assert_issue()
  end

  test "a named discard of a raising call or an allow-listed module passes" do
    ~S"""
    defmodule App.Store do
      alias App.Durable.Tx

      def write(tx, path) do
        _removed = File.rm_rf!(path)
        _entry = Tx.append(tx, "c", "note", %{})
        :ok
      end
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason, allowed: [{"App.Durable.Tx", "writes raise on failure"}])
    |> refute_issues()
  end

  test "an allow-list entry without a reason allows nothing" do
    ~S"""
    defmodule App.Store do
      def write(tx), do: _entry = App.Durable.Tx.append(tx, "c", "note", %{})
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason, allowed: [{"App.Durable.Tx", ""}])
    |> assert_issue()
  end

  test "__MODULE__ matches are assertions, not discards" do
    ~S"""
    defmodule App.Cache do
      def init(nil) do
        __MODULE__ = :ets.new(__MODULE__, [:named_table])
        {:ok, nil}
      end
    end
    """
    |> to_source_file()
    |> run_check(DiscardNeedsReason)
    |> refute_issues()
  end
end
