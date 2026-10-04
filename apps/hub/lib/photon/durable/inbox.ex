defmodule Photon.Durable.Inbox do
  @moduledoc """
  The rules for input to a conversation, as pure functions:

    * a submission with a request ID that was seen before returns the
      earlier one
    * on an idle conversation, input is placed in the transcript and starts
      a run (a generation task)
    * on a busy one it waits `queued`, unless it asked to be rejected
    * when a run moves on, the inbox's next input is every queued steer, or
      else the oldest follow-up

  `Photon.Durable` and the generation apply these inside commits.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [Photon.Durable.Submission, PhotonCore]

  alias Photon.Durable.Submission
  alias PhotonCore.Message

  @type action :: {:existing, Submission.t()} | :reject | :queue | :start_run

  @doc """
  What a submission does, given the earlier submission with its request ID
  (if any), whether the conversation is busy, and its `when_busy` mode.
  """
  @spec submit_action(Submission.t() | nil, boolean(), String.t()) :: action()
  def submit_action(%Submission{} = existing, _busy?, _when_busy), do: {:existing, existing}
  def submit_action(nil, true = _busy?, "reject"), do: :reject
  def submit_action(nil, true = _busy?, _when_busy), do: :queue
  def submit_action(nil, false = _busy?, _when_busy), do: :start_run

  @doc "The stored fields of a new, queued submission."
  @spec submission(String.t(), Message.content(), keyword()) :: map()
  def submission(conversation_id, content, opts) do
    %{
      conversation_id: conversation_id,
      request_id: opts[:request_id],
      mode: Keyword.get(opts, :when_busy, "follow_up"),
      content: %{"parts" => Message.parts(content), "source" => opts[:source]},
      status: "queued"
    }
  end

  @doc "The data of the user entry that places a submission in the transcript."
  @spec user_entry(Submission.t()) :: map()
  def user_entry(%Submission{} = submission) do
    %{
      "message" => Message.user(submission.content["parts"]),
      "submission_id" => submission.id,
      "source" => submission.content["source"]
    }
  end

  @doc "The attributes of the generation task that answers `placed` submissions."
  @spec run(String.t(), [String.t()]) :: map()
  def run(conversation_id, placed) do
    %{
      kind: "generation",
      conversation_id: conversation_id,
      phase: "request",
      checkpoint: %{"submissions" => placed}
    }
  end

  @doc "The inbox's next input: every queued steer, else the oldest follow-up."
  @spec next_input([Submission.t()]) :: [Submission.t()]
  def next_input(queued) do
    case Enum.filter(queued, &(&1.mode == "steer")) do
      [] -> Enum.take(queued, 1)
      steers -> steers
    end
  end

  @doc "Whether a submission can still be withdrawn: only while it is queued."
  @spec withdrawable?(Submission.t() | nil) :: boolean()
  def withdrawable?(%Submission{status: "queued"}), do: true
  def withdrawable?(_submission), do: false
end
