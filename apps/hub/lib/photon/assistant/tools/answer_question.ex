defmodule Photon.Assistant.Tools.AnswerQuestion do
  @moduledoc """
  Blip's `answer_question` tool (sections 4.4 and 5.3 of
  `docs/plans/step-4-blip-as-coordinator.md`): answers a thread's
  `ask_blip` question (`Photon.Questions.answer_tx/4`), which wakes the
  thread's waiting call with the answer. It answers inside the commit
  that records the call's result, so a rerun after a restart answers
  once.

  Who answers depends on the run making the call
  (`Photon.Assistant.origin_tx/2`, read in the same commit): a question
  Blip still has is Blip's to answer from what it knows. One already
  passed to the owner takes Blip's answer only when the owner wrote to
  Blip in this run, and is then recorded as the owner's, since Blip is
  passing on what they said; otherwise it is refused, so a guess of
  Blip's never passes as the owner's decision.

  Its result's details name the question and the thread, and carry the
  answer, which the question's card in Blip's panel shows.

  A refusal is Blip's words for it (`Photon.Assistant.question_refusal/2`);
  an unknown ID lists the open questions.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Questions}
  alias Photon.Questions.Rules

  @impl true
  def name, do: "answer_question"

  @impl true
  def description,
    do:
      "Answer a thread's question (a message starting with \"[Question q_...]\"). " <>
        "The answer goes straight to the thread. Answer only when your memory settles it, " <>
        "or to pass on what the user just told you."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "question_id" => %{"type" => "string", "description" => "The question's ID, like q_456."},
        "answer" => %{
          "type" => "string",
          "description" => "The answer, with what the thread needs to act on it."
        }
      },
      "required" => ["question_id", "answer"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"question_id" => id, "answer" => answer}, api) do
    with {:ok, text} <- Rules.answer(answer),
         do: {:commit, &answer(&1, api, String.trim(id), text)}
  end

  defp answer(tx, api, id, text) do
    origin = Assistant.origin_tx(tx, api.task)

    case Questions.answer_tx(tx, id, text, {:blip, origin.owner_wrote?}) do
      {:ok, question} ->
        {:ok, ~s{Sent your answer to "#{question.thread_title}".},
         %{
           "question_id" => question.id,
           "thread_id" => question.thread_id,
           "title" => question.thread_title,
           "project_id" => question.project_id,
           "slug" => question.project_slug,
           "answered_by" => question.answered_by,
           "answer" => question.answer
         }}

      {:error, reason} ->
        {:error, Assistant.question_refusal(reason, id)}
    end
  end
end
