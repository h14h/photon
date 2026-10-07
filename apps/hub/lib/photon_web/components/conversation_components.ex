defmodule PhotonWeb.ConversationComponents do
  @moduledoc """
  The pieces of a durable conversation on screen, shared by Blip's panel
  (`PhotonWeb.BlipLive`) and a project's thread page: the entries, each tool
  call as a line inside the answer that made it, web searches, the
  in-flight answer, the composer and what shows in its place until there's
  a model to talk to.

  Blip's panel and a thread page can be on one document, so every
  component that renders an ID takes an `id_prefix` (default `""`, which
  keeps Blip's IDs: `#composer`, `#stop`, `#action-<call id>`,
  `#live-output`). A thread page passes `"thread-"`. An image a call
  returned is loaded from the page's own image route, through the
  `image_path` function (`fn entry_id, index -> path end`), since the
  results a page keeps carry no image data.

  A call on a machine names the machine, `local` included, and says what
  it is doing until it ends: "Running `uptime` on mm1", then "Ran `uptime`
  on mm1", or "Stopped `uptime` on mm1" if the user stopped it
  (`Photon.Transcript.machine_action/4`). A long command is cut short on
  screen; the verb and the machine never are. A stopped call keeps the
  output it printed before the stop in view under its line, since its
  result only says it was stopped. The context-file calls
  read "Checked the context files", "Read notes.md", "Wrote notes.md" and
  "Edited notes.md", in the present while they run. Blip's read tools
  read "Looked over projects", "Looked over garden", "Checked threads"
  and `Read "Fix the pump"`, naming the project or thread from the
  result's details, or the arguments until there is a result.

  A message the user sent to Blip from a page inside a project shows only
  what they typed, with a small "About Garden / Fix the pump" line under
  it (`source["page"]`, see `Photon.Assistant.Page`); the note the model
  saw in front of it isn't shown.

  In Blip's conversation, what reached Blip from the threads (a signal
  message) shows as a compact block, a line per thread update or question
  linking the thread; the owner's answer to a thread's question shows as
  their bubble with an "Answer to Fix the pump" line under it. An
  `ask_owner` call that passed a question to the owner shows as the
  question's card, and so does the hub's notice that it passed on one
  Blip didn't get to; a refused `ask_owner` call stays a one-line action,
  so each question has one card. A withdrawn question's notice is a quiet
  line. A queued signal message's chip names the threads it is from.

  The events these components send (`send`, `toggle_mode`, `stop`,
  `withdraw`, and the card's `reply`) go to the LiveView that renders
  them; the socket side of the conversation is
  `PhotonWeb.ConversationView`.
  """

  use PhotonWeb, :html

  alias Photon.{Markdown, Transcript}
  alias PhotonCore.Message

  @file_tools ~w(list_context_files read_context_file write_context_file edit_context_file)
  @read_tools ~w(list_projects read_project list_threads read_thread)
  @work_tools ~w(start_project start_thread message_thread stop_thread answer_question ask_owner)
  @skill_tools ~w(list_skills set_project_skill)

  @doc "One entry of the conversation: a message, an answer with its calls, an error or a reset."
  attr :entry, :map, required: true
  attr :results, :map, required: true
  attr :outputs, :map, default: %{}, doc: "the tail of each running call's output"
  attr :id_prefix, :string, default: ""
  attr :image_path, :any, required: true, doc: "fn entry_id, index -> the image's path end"

  attr :questions, :map,
    default: %{},
    doc: "where each question put to the owner stands (`Photon.Transcript.questions/3`), by ID"

  @spec entry(map()) :: Phoenix.LiveView.Rendered.t()
  def entry(%{entry: %{kind: "user"}} = assigns) do
    source = assigns.entry.data["source"] || %{}

    assigns =
      assign(assigns,
        source: source,
        text: Transcript.typed(assigns.entry.data["message"], assigns.entry.data["source"]),
        about: get_in(source, ["page", "label"])
      )

    ~H"""
    <%= case @source["kind"] do %>
      <% "routine" -> %>
        <div class="flex items-start gap-3 text-sm">
          <span class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full bg-sunken text-ink-faint">
            <.icon name="hero-clock" class="size-4" />
          </span>
          <div class="min-w-0 pt-1">
            <span class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">Scheduled</span>
            <p class="mt-0.5 text-ink-soft">{String.replace_prefix(@text, "[Scheduled] ", "")}</p>
          </div>
        </div>
      <% "signal" -> %>
        <.signal_message id={"#{@id_prefix}message-#{@entry.id}"} data={@entry.data} />
      <% "answer" -> %>
        <%!-- The owner's answer to a thread's question: their bubble, and what it answered. --%>
        <div class="flex flex-col items-end gap-1 pl-10">
          <div class="max-w-full rounded-2xl rounded-br-md bg-sunken px-3.5 py-2 text-[14.5px] leading-relaxed text-ink ring-1 ring-line">
            <span
              id={"#{@id_prefix}message-#{@entry.id}"}
              phx-no-format
              class="whitespace-pre-wrap"
            >{@text}</span>
          </div>
          <p
            id={"#{@id_prefix}message-#{@entry.id}-about"}
            class="flex max-w-full items-center gap-1 pr-1 text-[11.5px] text-ink-faint"
            title="This answer went straight to the thread"
          >
            <.icon name="hero-arrow-uturn-right-micro" class="size-3 shrink-0" />
            <span class="min-w-0 truncate">
              Answer to
              <.thread_link
                title={@source["title"]}
                slug={@source["slug"]}
                thread_id={@source["thread_id"]}
                class="hover:text-ink-soft hover:underline"
              />
            </span>
          </p>
        </div>
      <% "blip" -> %>
        <%!-- Blip's words to a thread: a bubble like the owner's, tinted, and signed. --%>
        <div class="flex flex-col items-end gap-1 pl-10">
          <div class="max-w-full rounded-2xl rounded-br-md bg-accent-soft/60 px-3.5 py-2 text-[14.5px] leading-relaxed text-ink ring-1 ring-accent/20">
            <span
              id={"#{@id_prefix}message-#{@entry.id}"}
              phx-no-format
              class="whitespace-pre-wrap"
            >{@text}</span>
          </div>
          <p
            id={"#{@id_prefix}message-#{@entry.id}-about"}
            class="flex items-center gap-1 pr-1 text-[11.5px] text-ink-faint"
            title="Blip sent this message to the thread"
          >
            <.blip id={"#{@id_prefix}message-#{@entry.id}-blip"} size={13} still />
            <span>From Blip</span>
          </p>
        </div>
      <% _ -> %>
        <div class="flex flex-col items-end gap-1 pl-10">
          <div class="max-w-full rounded-2xl rounded-br-md bg-sunken px-3.5 py-2 text-[14.5px] leading-relaxed text-ink ring-1 ring-line">
            <span
              id={"#{@id_prefix}message-#{@entry.id}"}
              phx-no-format
              class="whitespace-pre-wrap"
            >{@text}</span>
          </div>
          <p
            :if={is_binary(@about)}
            id={"#{@id_prefix}message-#{@entry.id}-about"}
            class="flex max-w-full items-center gap-1 pr-1 text-[11.5px] text-ink-faint"
            title="Blip saw a note of this page with the message"
          >
            <.icon name="hero-eye-micro" class="size-3 shrink-0" />
            <span class="min-w-0 truncate">About {@about}</span>
          </p>
        </div>
    <% end %>
    """
  end

  def entry(%{entry: %{kind: "assistant"}} = assigns) do
    message = assigns.entry.data["message"]

    assigns =
      assign(assigns,
        text: Message.text_of(message),
        calls: Message.tool_calls(message),
        searches: Transcript.searches(message)
      )

    ~H"""
    <div class="min-w-0 space-y-2.5">
      <div :if={@searches != []} class="space-y-1">
        <.search :for={search <- @searches} action={search.action} />
      </div>
      <div :if={@text != ""} class="markdown-body text-ink">{raw(Markdown.to_html(@text))}</div>
      <div :if={@calls != []} class="space-y-1.5">
        <%= for call <- @calls do %>
          <%= case Transcript.question_card(@results[call["id"]]) do %>
            <% nil -> %>
              <.action
                call={call}
                result={@results[call["id"]]}
                tail={@outputs[call["id"]]}
                id_prefix={@id_prefix}
                image_path={@image_path}
              />
            <% question_id -> %>
              <.question_card
                id={question_id}
                card={card_of_call(call, @results[call["id"]])}
                question={@questions[question_id]}
              />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  def entry(%{entry: %{kind: "error"}} = assigns) do
    case Transcript.escalation(assigns.entry) do
      nil -> notice(assign(assigns, quiet: Transcript.quiet?(assigns.entry.data)))
      id -> escalation_card(assign(assigns, question_id: id))
    end
  end

  def entry(%{entry: %{kind: "reset"}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 py-2 text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
      <span class="h-px flex-1 bg-line" /> Fresh context <span class="h-px flex-1 bg-line" />
    </div>
    """
  end

  # The hub passed on a question Blip didn't get to: the question's card,
  # with the thread's own words.
  defp escalation_card(assigns) do
    ~H"""
    <.question_card
      id={@question_id}
      card={card_of_notice(@entry.data)}
      question={@questions[@question_id]}
    />
    """
  end

  # A failure, a stop, or a notice for the owner (a skipped schedule, a
  # withdrawn question).
  defp notice(assigns) do
    ~H"""
    <div class={[
      "flex items-start gap-2 rounded-xl px-3.5 py-2.5 text-sm",
      if(@quiet, do: "bg-sunken text-ink-soft", else: "bg-bad-soft text-ink")
    ]}>
      <.icon
        name={
          cond do
            @entry.data["question_notice"] -> "hero-no-symbol"
            @entry.data["notice"] -> "hero-clock"
            @quiet -> "hero-stop-circle"
            true -> "hero-exclamation-triangle"
          end
        }
        class={["mt-0.5 size-4 shrink-0", if(@quiet, do: "text-ink-faint", else: "text-bad")]}
      />
      <span class="leading-relaxed">{@entry.data["message"]}</span>
    </div>
    """
  end

  @doc """
  A signal message in Blip's conversation: what reached Blip from the
  threads, a line each (`#<id>-signal-<n>`): a bell for an update, a
  question mark for a question, the project and thread (linked) and what
  happened, or the question on one line.
  """
  attr :id, :string, required: true
  attr :data, :map, required: true, doc: "the user entry's data"

  @spec signal_message(map()) :: Phoenix.LiveView.Rendered.t()
  def signal_message(assigns) do
    assigns = assign(assigns, lines: Enum.with_index(Transcript.signal_lines(assigns.data)))

    ~H"""
    <div id={@id} class="flex items-start gap-3 text-sm">
      <span class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full bg-sunken text-ink-faint">
        <.icon name="hero-inbox-arrow-down" class="size-4" />
      </span>
      <div class="min-w-0 flex-1 pt-1">
        <span class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
          From your threads
        </span>
        <ul class="mt-1 space-y-1">
          <li
            :for={{line, n} <- @lines}
            id={"#{@id}-signal-#{n}"}
            data-kind={line.ref["kind"]}
            class="flex min-w-0 items-start gap-2 text-ink-soft"
          >
            <.icon
              name={
                if(line.ref["kind"] == "question",
                  do: "hero-question-mark-circle-micro",
                  else: "hero-bell-micro"
                )
              }
              class={[
                "mt-[3px] size-3.5 shrink-0",
                signal_tone(line.ref)
              ]}
            />
            <span class="min-w-0 leading-snug">
              <span :if={line.ref["project"]} class="text-ink-faint">{line.ref["project"]} /</span>
              <.thread_link
                title={line.ref["title"]}
                slug={line.ref["slug"]}
                thread_id={line.ref["thread_id"]}
                class="font-medium text-ink hover:underline"
              /> {signal_words(line)}
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp signal_tone(%{"kind" => "question"}), do: "text-accent-strong"
  defp signal_tone(%{"status" => "failed"}), do: "text-bad"
  defp signal_tone(%{"status" => "asking"}), do: "text-warn"
  defp signal_tone(_ref), do: "text-ink-faint"

  defp signal_words(%{ref: %{"kind" => "question"}, question: question}) do
    case truncate(question, 160) do
      "" -> "asks something"
      question -> "asks: " <> question
    end
  end

  defp signal_words(%{ref: %{"status" => "finished"}}), do: "finished"
  defp signal_words(%{ref: %{"status" => "failed"}}), do: "failed"
  defp signal_words(%{ref: %{"status" => "asking"}}), do: "is waiting on you"
  defp signal_words(_line), do: "changed"

  attr :title, :string, default: nil
  attr :slug, :string, default: nil
  attr :thread_id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  # A thread's title, linked to its page when the place is known.
  defp thread_link(assigns) do
    assigns = assign(assigns, title: thread_title(assigns.title))

    ~H"""
    <.link
      :if={is_binary(@slug) and is_binary(@thread_id)}
      navigate={~p"/projects/#{@slug}/threads/#{@thread_id}"}
      class={@class}
      {@rest}
    >{@title}</.link><span :if={!(is_binary(@slug) and is_binary(@thread_id))} class={@class} {@rest}>{@title}</span>
    """
  end

  defp thread_title(title) when is_binary(title) and title != "", do: title
  defp thread_title(_title), do: "A thread"

  @doc """
  A thread's question with the owner, as a card in Blip's panel
  (`#question-card-<id>`): the thread that asks (linked), the question
  (Blip's wording, or the thread's own words when the hub passed it on),
  and where it stands: while it is open, `Answer`, which puts the reply
  chip on the composer (`"reply"` with the question's ID); answered, the
  answer's first line; withdrawn, that the thread was stopped.
  """
  attr :id, :string, required: true, doc: "the question's ID"
  attr :card, :map, required: true, doc: "title, slug, thread_id, text and hub?"
  attr :question, :map, default: nil, doc: "where it stands (`Photon.Transcript.question()`)"

  @spec question_card(map()) :: Phoenix.LiveView.Rendered.t()
  def question_card(assigns) do
    question = assigns.question || %{status: :open, answer: nil}

    assigns =
      assign(assigns,
        dom_id: "question-card-#{assigns.id}",
        status: question.status,
        answer: first_line(question.answer)
      )

    ~H"""
    <div
      id={@dom_id}
      data-status={@status}
      class={[
        "rounded-xl border bg-surface px-3.5 py-3 shadow-xs transition-colors",
        if(@status == :open, do: "border-warn/40 shadow-warn/5", else: "border-line")
      ]}
    >
      <div class="flex items-start gap-2.5">
        <span class="mt-[5px] flex size-3.5 shrink-0 items-center justify-center">
          <.state_mark :if={@status == :open} state={:waiting} class="size-3.5" />
          <.icon :if={@status == :answered} name="hero-check-circle-micro" class="size-3.5 text-ok" />
          <.icon
            :if={@status == :withdrawn}
            name="hero-no-symbol-micro"
            class="size-3.5 text-ink-faint"
          />
        </span>
        <div class="min-w-0 flex-1">
          <p class="truncate text-[12.5px] text-ink-faint">
            <.thread_link
              id={"#{@dom_id}-thread"}
              title={@card.title}
              slug={@card.slug}
              thread_id={@card.thread_id}
              class="font-medium text-ink-soft hover:text-ink hover:underline"
            /> asks
          </p>
          <p
            id={"#{@dom_id}-text"}
            class={[
              "mt-1 text-[14px] leading-relaxed whitespace-pre-line",
              if(@status == :open, do: "text-ink", else: "text-ink-soft")
            ]}
          >
            {@card.text}
          </p>
          <p
            :if={@card.hub? and @status == :open}
            id={"#{@dom_id}-note"}
            class="mt-1 text-[12.5px] text-ink-faint"
          >
            In the thread's own words. Your answer goes straight to it.
          </p>
          <div :if={@status == :open} class="mt-2.5 flex items-center gap-2">
            <.button
              type="button"
              id={"#{@dom_id}-answer"}
              size="sm"
              phx-click={JS.push("reply", value: %{id: @id}) |> JS.focus(to: "#composer-input")}
            >
              <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> Answer
            </.button>
            <span class="text-[12px] text-ink-faint">Your answer goes straight to the thread.</span>
          </div>
          <p
            :if={@status == :answered}
            id={"#{@dom_id}-status"}
            class="mt-2 flex min-w-0 items-baseline gap-1.5 text-[13px]"
          >
            <span class="shrink-0 font-medium text-ok">Answered</span>
            <span :if={@answer} class="min-w-0 truncate text-ink-soft" title={@answer}>
              {@answer}
            </span>
          </p>
          <p
            :if={@status == :withdrawn}
            id={"#{@dom_id}-status"}
            class="mt-2 text-[13px] text-ink-faint"
          >
            Withdrawn: the thread was stopped
          </p>
        </div>
      </div>
    </div>
    """
  end

  # An ok `ask_owner` call's card: the thread from the result's details,
  # and Blip's wording.
  defp card_of_call(call, result) do
    details = (result && result["details"]) || %{}

    wording =
      case Message.arguments(call) do
        {:ok, %{"question" => question}} when is_binary(question) -> question
        _none -> nil
      end

    %{
      title: details["title"],
      slug: details["slug"],
      thread_id: details["thread_id"],
      text: details["wording"] || wording,
      hub?: false
    }
  end

  # The hub's escalation notice: the thread's own question, or the notice
  # if it carries none.
  defp card_of_notice(data) do
    %{
      title: data["title"],
      slug: data["slug"],
      thread_id: data["thread_id"],
      text: data["question"] || data["message"],
      hub?: true
    }
  end

  defp first_line(text) when is_binary(text) do
    case text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> truncate(200) do
      "" -> nil
      line -> line
    end
  end

  defp first_line(_text), do: nil

  @doc """
  One tool call: a line saying what it did, which opens to show the result.
  Under the line, while it runs (and after the user stopped it), the end
  of what it has printed; once it's done, any image it returned.
  """
  attr :call, :map, required: true
  attr :result, :map, default: nil
  attr :tail, :string, default: nil, doc: "the end of the call's output while it runs"
  attr :id_prefix, :string, default: ""
  attr :image_path, :any, required: true, doc: "fn entry_id, index -> the image's path end"

  @spec action(map()) :: Phoenix.LiveView.Rendered.t()
  def action(assigns) do
    args =
      case Message.arguments(assigns.call) do
        {:ok, args} -> args
        _ -> %{}
      end

    message = assigns.result && assigns.result["message"]
    details = (assigns.result && assigns.result["details"]) || %{}
    status = Transcript.action_status(assigns.result, details)

    assigns =
      assign(assigns,
        dom_id: "#{assigns.id_prefix}action-#{assigns.call["id"]}",
        args: args,
        details: details,
        status: status,
        output: message && Message.text_of(message),
        images: Message.images(message),
        # A stopped call keeps what it printed before the stop in view.
        tail: status in [:pending, :stopped] && assigns.tail
      )

    ~H"""
    <div
      id={@dom_id}
      data-status={@status}
      data-tool={@call["name"]}
      class="overflow-hidden rounded-xl border border-line bg-surface shadow-xs transition-shadow has-[details[open]]:shadow-sm"
    >
      <%!-- Re-rendered as output streams in or results land; the browser's open state stays. --%>
      <details
        id={"#{@dom_id}-details"}
        class="group"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary class="flex cursor-pointer list-none items-center gap-2.5 px-3 py-2 text-[13px] select-none">
          <span class={[
            "grid size-6 shrink-0 place-items-center rounded-md",
            @status == :pending && "bg-accent-soft text-accent-strong",
            @status == :done && "bg-ok-soft text-ok",
            @status == :error && "bg-bad-soft text-bad",
            @status == :stopped && "bg-sunken text-ink-faint"
          ]}>
            <.spinner :if={@status == :pending} class="size-3.5" />
            <.icon :if={@status == :done} name={action_icon(@call["name"])} class="size-3.5" />
            <.icon :if={@status == :error} name="hero-exclamation-triangle-micro" class="size-3.5" />
            <.icon :if={@status == :stopped} name="hero-stop-micro" class="size-3.5" />
          </span>
          <span class="min-w-0 flex-1 truncate text-ink-soft">
            <.action_label name={@call["name"]} args={@args} details={@details} status={@status} />
          </span>
          <span
            :if={@details["exit_code"] not in [nil, 0]}
            class="shrink-0 rounded bg-warn-soft px-1.5 py-0.5 font-mono text-[11px] text-warn"
          >
            exit {@details["exit_code"]}
          </span>
          <.icon
            name="hero-chevron-down-micro"
            class="size-4 shrink-0 text-ink-faint transition group-open:rotate-180"
          />
        </summary>
        <div class="border-t border-line px-3.5 py-2.5">
          <pre class="max-h-72 overflow-auto font-mono text-[12px] leading-relaxed whitespace-pre-wrap text-ink-soft">{@output || "Waiting for the result."}</pre>
        </div>
      </details>
      <%!-- Reversed, so it stays scrolled to the newest line as output comes in. --%>
      <div
        :if={@tail}
        id={"#{@dom_id}-tail"}
        class="flex max-h-40 flex-col-reverse overflow-auto border-t border-line bg-sunken/60 px-3.5 py-2"
      >
        <pre class="font-mono text-[12px] leading-relaxed whitespace-pre-wrap text-ink-soft">{@tail}</pre>
      </div>
      <img
        :for={{_image, index} <- Enum.with_index(@images)}
        id={"#{@dom_id}-image-#{index}"}
        src={@image_path.(@result["entry_id"], index)}
        loading="lazy"
        alt={@output || "An image from #{@args["machine"]}"}
        class="max-h-80 w-full border-t border-line bg-sunken object-contain"
      />
    </div>
    """
  end

  @doc """
  A web search the model ran (OpenAI runs it): what it looked for, or the
  page it read, linked.
  """
  attr :action, :map, default: nil, doc: "what the search did; nil while it runs"

  @spec search(map()) :: Phoenix.LiveView.Rendered.t()
  def search(assigns) do
    ~H"""
    <p class="flex min-w-0 items-center gap-2 text-[13px] text-ink-faint" data-search>
      <span :if={is_nil(@action)} class="text-accent-strong"><.spinner class="size-3.5" /></span>
      <.icon :if={@action} name="hero-globe-alt-micro" class="size-3.5 shrink-0" />
      <%= if @action && @action["url"] do %>
        <a
          href={@action["url"]}
          target="_blank"
          rel="noopener noreferrer"
          class="min-w-0 truncate hover:text-ink hover:underline"
        >
          {Transcript.search_label(@action)}
        </a>
      <% else %>
        <span class="min-w-0 truncate">{Transcript.search_label(@action)}</span>
      <% end %>
    </p>
    """
  end

  @doc """
  What a call did, in a line. A machine call names its command or path,
  and the machine; a context-file call names the file (and Blip's its
  project), `load_skill` the
  skill, and `ask_blip` its question. They are in the present while they
  run.
  """
  attr :name, :string, required: true
  attr :args, :map, required: true
  attr :details, :map, default: %{}
  attr :status, :atom, default: :done

  @spec action_label(map()) :: Phoenix.LiveView.Rendered.t()
  def action_label(%{name: name} = assigns) when name in ~w(shell view_image) do
    %{verb: verb, subject: subject, machine: machine} =
      Transcript.machine_action(name, assigns.args, assigns.details, assigns.status)

    assigns =
      assign(assigns,
        verb: verb,
        subject: truncate(subject),
        whole: truncate(subject, 300),
        machine: machine
      )

    # Only the command or path gives way to a narrow card: the verb and the
    # machine always show. The gap lays it out; the spaces keep the text whole.
    ~H"""
    <span class="flex min-w-0 items-baseline gap-x-1" phx-no-format><span class="shrink-0">{@verb}</span> <code class="min-w-0 truncate font-mono text-[12.5px] text-ink" title={@whole}>{@subject}</code><span :if={@machine} class="shrink-0" data-machine={@machine}> on <span class="font-medium text-ink">{@machine}</span></span></span>
    """
  end

  def action_label(%{name: name} = assigns) when name in @file_tools do
    assigns =
      assign(assigns,
        verb: file_verb(name, assigns.status),
        file: truncate(assigns.details["file"] || assigns.args["name"]),
        project: file_project(assigns.args, assigns.details)
      )

    ~H"""
    <span phx-no-format>{@verb}<span :if={@file != ""}> <span class="font-medium text-ink">{@file}</span></span><span :if={@project} data-project={@project}> in <span class="font-medium text-ink">{@project}</span></span></span>
    """
  end

  def action_label(%{name: "load_skill"} = assigns) do
    {verb, rest} = skill_words(assigns.status)

    assigns =
      assign(assigns,
        verb: verb,
        rest: rest,
        skill: truncate(assigns.details["skill"] || String.trim(assigns.args["name"] || ""))
      )

    ~H"""
    <span phx-no-format>{@verb} <span class="font-medium text-ink">{@skill}</span>{@rest}</span>
    """
  end

  def action_label(%{name: "ask_blip"} = assigns) do
    assigns =
      assign(assigns,
        verb: ask_verb(assigns.status),
        question: truncate(assigns.args["question"]),
        whole: truncate(assigns.args["question"], 300)
      )

    ~H"""
    <span phx-no-format>{@verb}<span :if={@question != ""}>: <span class="text-ink" title={@whole}>{@question}</span></span></span>
    """
  end

  def action_label(%{name: name} = assigns) when name in @read_tools do
    {verb, subject} = read_words(name, assigns.args, assigns.details, assigns.status)
    assigns = assign(assigns, verb: verb, subject: truncate(subject))

    ~H"""
    <span phx-no-format>{@verb}<span :if={@subject != ""}> <span class="font-medium text-ink">{@subject}</span></span></span>
    """
  end

  def action_label(%{name: name} = assigns) when name in @work_tools do
    {verb, subject, rest} = work_words(name, assigns.args, assigns.details, assigns.status)

    assigns =
      assign(assigns,
        verb: verb,
        subject: truncate(subject),
        rest: rest,
        href: work_href(name, assigns.status, assigns.details)
      )

    ~H"""
    <span phx-no-format>{@verb}<span :if={@subject != ""}> <.link :if={@href} navigate={@href} class="font-medium text-ink hover:underline">{@subject}</.link><span :if={!@href} class="font-medium text-ink">{@subject}</span></span>{@rest}</span>
    """
  end

  def action_label(%{name: name} = assigns) when name in @skill_tools do
    {verb, skill, project} = skill_tool_words(name, assigns.args, assigns.details, assigns.status)
    assigns = assign(assigns, verb: verb, skill: truncate(skill), project: truncate(project))

    ~H"""
    <span phx-no-format>{@verb}<span :if={@skill != ""}> <span class="font-medium text-ink">{@skill}</span></span><span :if={@project != ""} data-project={@project}> for <span class="font-medium text-ink">{@project}</span></span></span>
    """
  end

  def action_label(assigns) do
    assigns = assign(assigns, :text, label_text(assigns.name, assigns.args))

    ~H"""
    {@text}
    """
  end

  defp label_text("list_machines", _), do: "Checked your machines"

  defp label_text("update_memory", args),
    do: "Memory: #{args["action"]} #{truncate(args["text"])}"

  defp label_text("schedule", %{"project" => slug} = args) when is_binary(slug) and slug != "",
    do: "Scheduled in #{truncate(slug)}: #{truncate(args["prompt"])}"

  defp label_text("schedule", args), do: "Scheduled: #{truncate(args["prompt"])}"

  defp label_text("list_schedules", %{"project" => slug}) when is_binary(slug) and slug != "",
    do: "Checked the schedules in #{truncate(slug)}"

  defp label_text("list_schedules", _), do: "Checked the schedule"
  defp label_text("cancel_schedule", args), do: "Cancelled #{args["schedule_id"]}"
  defp label_text(name, _), do: name

  # The words around a skill's name: "Loading the pdf-forms skill",
  # "Couldn't load pdf-form".
  defp skill_words(:pending), do: {"Loading the", " skill"}
  defp skill_words(:error), do: {"Couldn't load", ""}
  defp skill_words(:stopped), do: {"Stopped loading the", " skill"}
  defp skill_words(_done), do: {"Loaded the", " skill"}

  # Blip's skill tools: the verb for the call's status, the skill and the
  # project it turned on or off for (from the result's details, else the
  # arguments). Listing names neither.
  defp skill_tool_words("list_skills", _args, _details, status),
    do: {status_verb(status, "Checking skills", "Checked skills", "check skills"), nil, nil}

  defp skill_tool_words("set_project_skill", args, details, status) do
    on = if Map.get(details, "on", args["on"]) == false, do: "off", else: "on"

    {status_verb(status, "Turning #{on}", "Turned #{on}", "turn #{on}"),
     details["skill"] || args["skill"], details["slug"] || args["project"]}
  end

  # A question can wait for hours, so the running words say it is asking.
  defp ask_verb(:pending), do: "Asking Blip"
  defp ask_verb(:error), do: "Couldn't ask Blip"
  defp ask_verb(:stopped), do: "Stopped asking Blip"
  defp ask_verb(_done), do: "Asked Blip"

  # Blip's read tools: the verb for the call's status, and what it read
  # (a project's slug, a thread's title in quotes), from the result's
  # details or else the arguments.
  defp read_words("list_projects", _args, _details, status),
    do: {status_verb(status, "Looking over", "Looked over", "look over"), "projects"}

  defp read_words("read_project", args, details, status),
    do:
      {status_verb(status, "Looking over", "Looked over", "look over"),
       details["slug"] || args["project"]}

  defp read_words("list_threads", args, details, status) do
    verb = status_verb(status, "Checking threads", "Checked threads", "check threads")

    case details["slug"] || args["project"] do
      project when is_binary(project) -> {verb <> " in", project}
      _all -> {verb, ""}
    end
  end

  defp read_words("read_thread", args, details, status) do
    verb = status_verb(status, "Reading", "Read", "read")

    case details["title"] do
      title when is_binary(title) -> {verb, ~s("#{title}")}
      _none -> {verb, args["thread"]}
    end
  end

  # Blip's tools that start and stop work: the verb, what it acted on (a
  # project's slug, a thread's title in quotes, or its ID while the call
  # runs), and the words after it.
  defp work_words("start_project", _args, details, status) do
    case {status, details["slug"]} do
      {:done, slug} when is_binary(slug) -> {"Started the project", slug, ""}
      _running -> {status_verb(status, "Starting", "Started", "start") <> " a project", "", ""}
    end
  end

  defp work_words("start_thread", args, details, status) do
    project = details["slug"] || args["project"]
    verb = status_verb(status, "Starting", "Started", "start") <> " a thread"

    case {status, details["title"], project} do
      {:done, title, slug} when is_binary(title) -> {"Started", ~s("#{title}"), " in #{slug}"}
      {_status, _title, slug} when is_binary(slug) -> {verb <> " in", slug, ""}
      _nowhere -> {verb, "", ""}
    end
  end

  defp work_words("message_thread", args, details, status),
    do: {status_verb(status, "Messaging", "Messaged", "message"), thread_name(args, details), ""}

  defp work_words("stop_thread", args, details, status) do
    verb =
      case status do
        :stopped -> "Didn't stop"
        status -> status_verb(status, "Stopping", "Stopped", "stop")
      end

    {verb, thread_name(args, details), ""}
  end

  # A thread's question: the thread's title once the result names it, the
  # question's ID while the call runs.
  defp work_words("answer_question", args, details, status),
    do:
      {status_verb(status, "Answering", "Answered", "answer"), question_thread(args, details), ""}

  defp work_words("ask_owner", args, details, status),
    do:
      {status_verb(status, "Asking you about", "Asked you about", "ask you about"),
       question_thread(args, details), ""}

  # A thread Blip started, or whose question it handled, links to its page.
  defp work_href(name, :done, %{"slug" => slug, "thread_id" => id})
       when name in ~w(start_thread answer_question ask_owner) and is_binary(slug) and
              is_binary(id),
       do: ~p"/projects/#{slug}/threads/#{id}"

  defp work_href(_name, _status, _details), do: nil

  defp thread_name(args, details) do
    case details["title"] do
      title when is_binary(title) -> ~s("#{title}")
      _none -> args["thread"]
    end
  end

  defp question_thread(args, details) do
    case details["title"] do
      title when is_binary(title) -> ~s("#{title}")
      _none -> args["question_id"]
    end
  end

  defp status_verb(:pending, running, _done, _base), do: running
  defp status_verb(:error, _running, _done, base), do: "Couldn't " <> base
  defp status_verb(:stopped, running, _done, _base), do: "Stopped " <> String.downcase(running)
  defp status_verb(_done, _running, done, _base), do: done

  # Blip's file calls name a project (its slug once the result is in); a
  # thread's only ever touch its own, so they name none.
  defp file_project(args, details) do
    case details["slug"] || args["project"] do
      project when is_binary(project) and project != "" -> truncate(project)
      _none -> nil
    end
  end

  # Listing names no file; the others name the one they touched.
  defp file_verb("list_context_files", :pending), do: "Checking the context files"
  defp file_verb("list_context_files", _status), do: "Checked the context files"
  defp file_verb("read_context_file", :pending), do: "Reading"
  defp file_verb("read_context_file", _status), do: "Read"
  defp file_verb("write_context_file", :pending), do: "Writing"
  defp file_verb("write_context_file", _status), do: "Wrote"
  defp file_verb("edit_context_file", :pending), do: "Editing"
  defp file_verb("edit_context_file", _status), do: "Edited"

  @doc """
  The icon a tool's call shows once it went through: in a conversation's
  action line, and on the activity page's rows. A tool without one of its
  own gets a check.
  """
  @spec action_icon(term()) :: String.t()
  def action_icon("shell"), do: "hero-command-line-micro"
  def action_icon("view_image"), do: "hero-photo-micro"
  def action_icon("list_machines"), do: "hero-server-stack-micro"
  def action_icon("update_memory"), do: "hero-bookmark-micro"
  def action_icon("list_context_files"), do: "hero-document-duplicate-micro"
  def action_icon("read_context_file"), do: "hero-document-text-micro"
  def action_icon("write_context_file"), do: "hero-document-plus-micro"
  def action_icon("edit_context_file"), do: "hero-pencil-square-micro"
  def action_icon("load_skill"), do: "hero-book-open-micro"
  def action_icon("ask_blip"), do: "hero-chat-bubble-left-ellipsis-micro"
  def action_icon(name) when name in ~w(list_projects read_project), do: "hero-folder-micro"
  def action_icon("list_threads"), do: "hero-queue-list-micro"
  def action_icon("read_thread"), do: "hero-chat-bubble-left-right-micro"
  def action_icon("start_project"), do: "hero-folder-plus-micro"
  def action_icon("start_thread"), do: "hero-play-circle-micro"
  def action_icon("message_thread"), do: "hero-paper-airplane-micro"
  def action_icon("stop_thread"), do: "hero-stop-circle-micro"
  def action_icon("answer_question"), do: "hero-chat-bubble-bottom-center-text-micro"
  def action_icon("ask_owner"), do: "hero-question-mark-circle-micro"
  def action_icon("list_skills"), do: "hero-book-open-micro"
  def action_icon("set_project_skill"), do: "hero-adjustments-horizontal-micro"

  def action_icon(name) when name in ~w(schedule list_schedules cancel_schedule),
    do: "hero-clock-micro"

  def action_icon(_), do: "hero-check-micro"

  # One line of at most `limit` characters; anything that isn't text is nothing.
  defp truncate(text, limit \\ 90)
  defp truncate(text, _limit) when not is_binary(text), do: ""

  defp truncate(text, limit) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > limit, do: String.slice(text, 0, limit - 3) <> "...", else: text
  end

  @doc """
  What the model is up to between answers: waiting on a run (the thinking
  dots), or the answer as it streams.
  """
  attr :live, :map, required: true
  attr :shown, :map, required: true, doc: "the finished blocks of the in-flight answer"
  attr :mood, :atom, required: true
  attr :id_prefix, :string, default: ""

  @spec live_output(map()) :: Phoenix.LiveView.Rendered.t()
  def live_output(%{live: nil} = assigns) do
    ~H"""
    <div id={"#{@id_prefix}live-output"} data-mood={@mood} class="mt-5">
      <div :if={@mood == :thinking} class="flex h-6 items-center"><.thinking /></div>
    </div>
    """
  end

  # The answer as it streams: whole blocks, each fading in as it arrives
  # (`data-streaming`, see app.css), with the thinking dots under them while
  # more is on its way.
  def live_output(assigns) do
    ~H"""
    <div id={"#{@id_prefix}live-output"} data-mood={@mood} class="mt-5 space-y-2">
      <p
        :if={@live.retry}
        class="flex items-center gap-2 rounded-lg bg-warn-soft px-3 py-2 text-[13px] text-ink-soft"
      >
        <.icon name="hero-arrow-path" class="size-4 animate-spin text-warn" /> {@live.retry}
      </p>
      <p
        :if={@shown.reasoning != "" and @shown.text == ""}
        class="line-clamp-3 text-[13px] leading-relaxed text-ink-faint italic"
      >
        {@shown.reasoning |> String.slice(-400, 400)}
      </p>
      <div :if={@live.searches != []} id={"#{@id_prefix}live-searches"} class="space-y-1">
        <.search :for={search <- Enum.reverse(@live.searches)} action={search.action} />
      </div>
      <div
        :if={@shown.text != ""}
        id={"#{@id_prefix}live-text"}
        class="markdown-body text-ink"
        data-streaming
      >
        {raw(Markdown.to_html(@shown.text))}
      </div>
      <div
        :for={{_index, name} <- @live.tools}
        class="flex items-center gap-2 text-[13px] text-ink-faint"
      >
        <.spinner class="size-3.5" /> Preparing {name}
      </div>
      <div :if={@live.tools == %{} and is_nil(@live.retry)} class="flex h-6 items-center">
        <.thinking />
      </div>
    </div>
    """
  end

  @doc "Three breathing dots."
  @spec thinking(map()) :: Phoenix.LiveView.Rendered.t()
  def thinking(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 text-ink-faint" aria-label="Thinking">
      <span class="size-1.5 animate-breathe rounded-full bg-current" />
      <span class="size-1.5 animate-breathe rounded-full bg-current [animation-delay:0.2s]" />
      <span class="size-1.5 animate-breathe rounded-full bg-current [animation-delay:0.4s]" />
    </div>
    """
  end

  @doc "In place of the composer until there's a model to talk to."
  attr :chatgpt, :map, required: true
  attr :who, :string, default: "Blip", doc: "who needs the sign-in, as the sentence's subject"
  attr :id_prefix, :string, default: ""
  attr :class, :any, default: nil, doc: "added to the outer row"

  @spec sign_in_to_talk(map()) :: Phoenix.LiveView.Rendered.t()
  def sign_in_to_talk(assigns) do
    ~H"""
    <div class={["shrink-0 border-t border-line px-4 pt-3 pb-4", @class]}>
      <div
        id={"#{@id_prefix}sign-in-to-talk"}
        class="mx-auto flex w-full max-w-3xl flex-wrap items-center justify-between gap-3 rounded-2xl border border-line bg-canvas px-4 py-3"
      >
        <p class="text-[14px] text-ink-soft">
          {if(@chatgpt.state == :signed_in,
            do: "Photon isn't allowed to use your ChatGPT plan yet.",
            else: "#{@who} needs a ChatGPT sign-in to think."
          )}
        </p>
        <.button navigate={~p"/settings"} variant="primary" size="sm">
          {if(@chatgpt.state == :signed_in, do: "Fix in Settings", else: "Sign in with ChatGPT")}
        </.button>
      </div>
    </div>
    """
  end

  @doc """
  The message box, with the queued messages above it and, while the
  conversation is busy, the steer or follow-up toggle and Stop. Enter
  sends; Shift+Enter starts a new line. The box empties as it sends; a
  page whose send was refused gives the text back with a
  `"composer:restore"` event (`%{id: <the box's ID>, text: text}`).
  """
  attr :form, :any, required: true
  attr :busy, :boolean, required: true
  attr :mode, :string, required: true
  attr :queued, :list, required: true
  attr :id_prefix, :string, default: ""
  attr :placeholder, :string, default: "Ask Blip anything..."
  attr :class, :any, default: nil, doc: "added to the outer row"

  attr :autofocus, :boolean,
    default: false,
    doc: "whether the message box takes focus when it mounts, after a live navigation too"

  slot :context,
    doc: "what goes with the next message, shown inside the box above the text (Blip's page chip)"

  slot :above, doc: "a line above the queued messages (a thread's question to Blip)"
  slot :footer, doc: "a note under the box (a thread's while Blip has its question)"

  @spec composer(map()) :: Phoenix.LiveView.Rendered.t()
  def composer(assigns) do
    ~H"""
    <div class={["shrink-0 px-3 pt-1 pb-3 sm:px-4 sm:pb-4", @class]}>
      <div class="mx-auto w-full max-w-3xl">
        {render_slot(@above)}
        <.queued_messages queued={@queued} id_prefix={@id_prefix} />

        <.form
          for={@form}
          id={"#{@id_prefix}composer"}
          phx-submit="send"
          class="rounded-2xl border border-line bg-canvas transition focus-within:border-accent/60 focus-within:bg-surface focus-within:shadow-md focus-within:shadow-accent/10"
        >
          <div :if={@context != []} class="flex px-2.5 pt-2.5">{render_slot(@context)}</div>
          <textarea
            id={"#{@id_prefix}composer-input"}
            name={@form[:text].name}
            phx-hook=".Composer"
            autofocus={@autofocus}
            phx-mounted={@autofocus && JS.focus()}
            rows="1"
            placeholder={if(@busy, do: "Add to the conversation...", else: @placeholder)}
            class="block max-h-60 min-h-11 w-full resize-none bg-transparent px-3.5 pt-2.5 pb-1 text-[14.5px] leading-relaxed text-ink outline-none placeholder:text-ink-faint"
          >{@form[:text].value}</textarea>
          <div class="flex items-center gap-2 px-2 pb-2">
            <button
              :if={@busy}
              type="button"
              id={"#{@id_prefix}mode-toggle"}
              phx-click="toggle_mode"
              class={[
                "rounded-full px-2.5 py-1 text-[12px] transition",
                @mode == "steer" && "bg-accent-soft font-medium text-accent-strong",
                @mode != "steer" && "text-ink-faint hover:bg-sunken hover:text-ink-soft"
              ]}
              title="Steer joins the current work after its next step. Otherwise your message waits for the current answer."
            >
              {if(@mode == "steer", do: "Steer current work", else: "Send after this answer")}
            </button>
            <span class="flex-1" />
            <.button
              :if={@busy}
              type="button"
              id={"#{@id_prefix}stop"}
              variant="secondary"
              size="sm"
              phx-click="stop"
            >
              <.icon name="hero-stop-solid" class="size-3.5" /> Stop
            </.button>
            <.button
              type="submit"
              id={"#{@id_prefix}send"}
              variant="primary"
              size="sm"
              class="size-8 rounded-full px-0"
              title="Send"
            >
              <.icon name="hero-arrow-up" class="size-4" />
            </.button>
          </div>
        </.form>
        {render_slot(@footer)}
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
        export default {
          mounted() {
            const grow = () => {
              this.el.style.height = "auto"
              this.el.style.height = Math.min(this.el.scrollHeight, 240) + "px"
            }
            this.el.addEventListener("input", grow)
            this.el.addEventListener("keydown", e => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault()
                if (this.el.value.trim() !== "") this.el.form.requestSubmit()
              }
            })
            this.el.form.addEventListener("submit", () => setTimeout(() => { this.el.value = ""; grow() }, 0))
            // A refused send gives back what was typed (the box empties on submit).
            this.handleEvent("composer:restore", ({id, text}) => {
              if (id !== this.el.id) return
              this.el.value = text
              grow()
            })
            // Measured while Blip's panel is closed (as narrow as Blip), the
            // placeholder wraps a word a line and the box mounts at its
            // tallest; it measures again when its width changes.
            let width = this.el.clientWidth
            this.resized = new ResizeObserver(() => {
              if (this.el.clientWidth === width) return
              width = this.el.clientWidth
              grow()
            })
            this.resized.observe(this.el)
            grow()
          },
          destroyed() {
            if (this.resized) this.resized.disconnect()
          }
        }
      </script>
    </div>
    """
  end

  @doc """
  The answer box of a thread's question with the owner, inside its form
  (the home page's question rows and the thread page's banners): Enter
  sends, Shift+Enter starts a new line, as in the composer.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :id, :string, required: true

  @spec answer_box(map()) :: Phoenix.LiveView.Rendered.t()
  def answer_box(assigns) do
    ~H"""
    <.input
      field={@field}
      id={@id}
      type="textarea"
      rows="2"
      placeholder="Your answer goes straight to the thread"
      phx-debounce="300"
      phx-hook=".AnswerBox"
      enterkeyhint="send"
      class={[field_class(), "h-auto min-h-16 resize-y py-2 leading-relaxed"]}
    />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AnswerBox">
      export default {
        mounted() {
          this.el.addEventListener("keydown", e => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault()
              if (this.el.value.trim() !== "") this.el.form.requestSubmit()
            }
          })
        }
      }
    </script>
    """
  end

  @doc """
  The messages waiting in a conversation's inbox, each with whether it
  steers the current work or comes next, and a button to withdraw it
  (`"withdraw"` with its ID). The owner's answer to a thread's question
  has no such button: it has already gone to the thread, so its chip
  says so instead. Shown above the composer, or above whatever takes the
  composer's place.
  """
  attr :queued, :list, required: true
  attr :id_prefix, :string, default: ""

  @spec queued_messages(map()) :: Phoenix.LiveView.Rendered.t()
  def queued_messages(assigns) do
    ~H"""
    <div :if={@queued != []} id={"#{@id_prefix}queued"} class="mb-2 flex flex-wrap gap-1.5">
      <span
        :for={s <- @queued}
        id={"#{@id_prefix}queued-#{s.id}"}
        class="flex max-w-full items-center gap-1.5 rounded-full border border-line bg-surface py-1 pr-1 pl-3 text-[12px] text-ink-soft"
      >
        <span class="font-medium text-ink-faint">{queued_label(s)}</span>
        <span class="max-w-60 truncate">{queued_text(s.content)}</span>
        <span
          :if={answer?(s)}
          id={"#{@id_prefix}queued-#{s.id}-sent"}
          class="rounded-full p-0.5 text-ok"
          title="Already sent to the thread. Blip reads it next."
        >
          <.icon name="hero-check-micro" class="size-3.5" />
        </span>
        <button
          :if={!answer?(s)}
          phx-click="withdraw"
          phx-value-id={s.id}
          class="rounded-full p-0.5 hover:bg-sunken"
          title="Withdraw"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </button>
      </span>
    </div>
    """
  end

  # The owner's answer to a thread's question, relayed to Blip.
  defp answer?(%{content: %{"source" => %{"kind" => "answer"}}}), do: true
  defp answer?(_submission), do: false

  defp queued_label(submission) do
    cond do
      answer?(submission) -> "Answered"
      submission.mode == "steer" -> "Steer"
      true -> "Next"
    end
  end

  # What a queued message says on its chip: what was typed, or for a
  # signal message, which threads it is from.
  defp queued_text(%{"source" => %{"kind" => "signal"}} = content) do
    lines =
      Transcript.signal_lines(%{
        "message" => %{"content" => content["parts"]},
        "source" => content["source"]
      })

    questions? = Enum.any?(lines, &(&1.ref["kind"] == "question"))
    titles = Enum.map_join(lines, ", ", &~s("#{thread_title(&1.ref["title"])}"))
    if(questions?, do: "Question from ", else: "Update on ") <> titles
  end

  defp queued_text(content), do: Transcript.typed(content["parts"], content["source"])
end
