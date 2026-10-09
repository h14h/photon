defmodule PhotonWeb.ThreadText do
  @moduledoc """
  The words the pages use for threads' states: a state's label
  ("Waiting on you", "Asking Blip"), the home page's summary
  ("3 things need you."), "and 4 more" under a cut list, what Mark all read
  did, a gone quiet thread's line, and a question squeezed onto one line.

  The labels are `Photon.Threads.State.label/2`'s, so the pages and
  Blip's tools say the same. Pure: times are never formatted here; the
  pages render them with `PhotonWeb.TimeComponents.local_time/1`.
  """

  alias Photon.Threads.State

  @doc """
  A state's words, from a board entry (`Photon.Threads.board/1`, whose
  thread row says why an idle thread is idle) or a bare state.
  """
  @spec state(%{state: State.t(), thread: map()} | State.t()) :: String.t()
  def state(%{state: state, thread: thread}), do: State.label(state, thread)
  def state(state) when is_atom(state), do: State.label(state, %{})

  @doc ~S"""
  The home page's summary of how many threads need the owner: "Nothing
  needs you right now.", "1 thing needs you.", "3 things need you."
  """
  @spec summary(non_neg_integer()) :: String.t()
  def summary(0), do: "Nothing needs you right now."
  def summary(1), do: "1 thing needs you."
  def summary(count), do: "#{count} things need you."

  @doc ~S(Under a list cut short: "and 4 more".)
  @spec more(pos_integer()) :: String.t()
  def more(count), do: "and #{count} more"

  @doc ~S"""
  What Mark all read did: "Marked 4 threads read.", "Marked 1 thread
  read.", or "Nothing to mark read." when every thread was already read.
  """
  @spec marked_read(non_neg_integer()) :: String.t()
  def marked_read(0), do: "Nothing to mark read."
  def marked_read(1), do: "Marked 1 thread read."
  def marked_read(count), do: "Marked #{count} threads read."

  @doc ~S"""
  A gone quiet thread's line before its last activity: "Stopped" when its
  last run was stopped, else "Idle" (no run of it has ended).
  """
  @spec quiet(map()) :: String.t()
  def quiet(%{last_run_status: "stopped"}), do: "Stopped"
  def quiet(_thread), do: "Idle"

  @doc ~S"""
  Text on one line: its whitespace, line breaks included, collapsed to
  single spaces. The page cuts it to the row's width.
  """
  @spec one_line(String.t() | nil) :: String.t()
  def one_line(nil), do: ""
  def one_line(text), do: text |> String.split() |> Enum.join(" ")
end
