defmodule Photon.Assistant.Tools.AskOwner do
  @moduledoc """
  Blip's `ask_owner` tool (sections 4.4 and 5.3 of
  `docs/plans/step-4-blip-as-coordinator.md`): passes a thread's
  `ask_blip` question to the owner, in Blip's words
  (`Photon.Questions.pass_tx/4`), inside the commit that records the
  call's result. Its result's details name the question and the thread,
  so Blip's panel draws it as a question card the owner answers from.
  The owner's answer goes straight to the thread, by code; Blip sees it
  afterwards as a message of its own.

  A question already with the owner, or no longer open, is refused in
  Blip's words (`Photon.Assistant.question_refusal/2`); an unknown ID
  lists the open questions.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Questions}
  alias Photon.Questions.Rules

  @impl true
  def name, do: "ask_owner"

  @impl true
  def description,
    do:
      "Ask the user a thread's question (a message starting with \"[Question q_...]\") " <>
        "when your memory doesn't settle it. Their answer goes straight to the thread, " <>
        "and you see it here afterwards."

  @impl true
  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{
        "question_id" => %{"type" => "string", "description" => "The question's ID, like q_456."},
        "question" => %{
          "type" => "string",
          "description" =>
            "What to ask the user: one clear question, in your words. Say which thread is " <>
              "asking and why it matters if that helps them answer."
        }
      },
      "required" => ["question_id", "question"]
    }

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"question_id" => id, "question" => wording}, _api) do
    with {:ok, wording} <- Rules.question(wording),
         do: {:commit, &pass(&1, String.trim(id), wording)}
  end

  defp pass(tx, id, wording) do
    case Questions.pass_tx(tx, id, wording, :blip) do
      {:ok, question} ->
        {:ok,
         ~s{Asked the user. Their answer goes straight to "#{question.thread_title}"; you'll see it here.},
         %{
           "question_id" => question.id,
           "thread_id" => question.thread_id,
           "title" => question.thread_title,
           "project_id" => question.project_id,
           "slug" => question.project_slug,
           "project" => question.project_name
         }}

      {:error, reason} ->
        {:error, Assistant.question_refusal(reason, id)}
    end
  end
end
