defmodule Photon.Threads.Tools.AskBlip do
  @moduledoc """
  A thread's `ask_blip` tool: the thread asks Blip one specific question and
  its call waits, durably, for the answer.

  `execute/2` posts the question to Blip (`Photon.Questions.ask/1`, in a
  commit that checks the call's task is still running and not being
  stopped) and parks on the question's signal.
  A rerun after a hub restart finds the question by its task and parks on
  it again.

  While Blip has the question the call also wakes every
  `Photon.Questions.check_ms/0`, and `Photon.Questions.escalate/1` passes
  it to the owner if Blip's run went past it. Once it is with the owner
  only an answer or a Stop moves it.

  A call that ends without an answer (a Stop, a failed task, or a raise
  here) withdraws its question in the commit that ends it
  (`on_interrupt/2`), so no question is left open with no call waiting
  for it.

  There is no process here: the wait is the tool task.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Durable.{ToolAPI, ToolSchema}
  alias Photon.Projects
  alias Photon.Projects.Project
  alias Photon.Questions
  alias Photon.Questions.{Question, Rules}
  alias Photon.Threads
  alias Photon.Threads.Thread

  @impl true
  def name, do: "ask_blip"

  @impl true
  def description do
    "Ask Blip, the user's assistant, for the user's judgement or preferences: which option they'd pick, " <>
      "how they like something done, a fact about them or their setup that isn't on any machine. " <>
      "Blip answers from what it knows, or asks the user and passes the answer back. " <>
      "You wait until the answer comes, which can take hours. Don't ask what you can find out yourself."
  end

  @impl true
  def parameters,
    do:
      ToolSchema.object(
        [
          question:
            {:string,
             "One specific question, with the context Blip needs to answer it. " <>
               "Blip knows the user but doesn't see this thread."}
        ],
        [:question]
      )

  # The question is found by the call's task, so a rerun asks nothing new.
  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, api) do
    with {:ok, text} <- Rules.question(args["question"]),
         {:ok, new} <- new(api, text) do
      case Questions.ask(new) do
        {:ok, question} -> check_later(question.id)
        {:error, :stopped} -> {:error, "The call was stopped before Blip got the question."}
      end
    end
  end

  # The thread and its project as they are now.
  defp new(api, text) do
    with %Thread{} = thread <- Threads.get(api.conversation_id),
         %Project{} = project <- Projects.get(thread.project_id) do
      {:ok,
       %{
         task_id: ToolAPI.task_id(api),
         thread_id: thread.id,
         thread_title: thread.title,
         project_id: project.id,
         project_slug: project.slug,
         project_name: project.name,
         question: text
       }}
    else
      nil -> {:error, "This thread's project is gone, so there's no one to ask."}
    end
  end

  @impl true
  def resume(%{"question_id" => id}, _api) do
    case Questions.get(id) do
      %Question{status: "asked"} -> id |> Questions.escalate() |> next(id)
      question -> next({:ok, question}, id)
    end
  end

  defp next({:ok, %Question{status: "answered"} = question}, id),
    do:
      {:ok, Rules.result(question), %{"question_id" => id, "answered_by" => question.answered_by}}

  defp next({:ok, %Question{status: "asked"}}, id), do: check_later(id)
  defp next({:ok, %Question{status: "with_owner"}}, id), do: wait(id, %{})

  # Only when a withdraw and a check race: the call is ending anyway.
  defp next({:ok, %Question{status: "withdrawn"}}, _id),
    do: {:error, "This question was withdrawn."}

  defp next(_missing, _id), do: {:error, "The hub has no record of this question."}

  defp check_later(id),
    do: wait(id, %{"until" => System.system_time(:millisecond) + Questions.check_ms()})

  defp wait(id, also),
    do: {:wait, Map.put(also, "signal", Questions.signal_key(id)), %{"question_id" => id}}

  @impl true
  def on_interrupt(api, tx), do: Questions.withdraw_tx(tx, ToolAPI.task_id(api))
end
