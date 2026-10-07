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

  The events these components send (`send`, `toggle_mode`, `stop`,
  `withdraw`) go to the LiveView that renders them; the socket side of the
  conversation is `PhotonWeb.ConversationView`.
  """

  use PhotonWeb, :html

  alias Photon.{Markdown, Transcript}
  alias PhotonCore.Message

  @file_tools ~w(list_context_files read_context_file write_context_file edit_context_file)
  @read_tools ~w(list_projects read_project list_threads read_thread)
  @work_tools ~w(start_project start_thread message_thread stop_thread)

  @doc "One entry of the conversation: a message, an answer with its calls, an error or a reset."
  attr :entry, :map, required: true
  attr :results, :map, required: true
  attr :outputs, :map, default: %{}, doc: "the tail of each running call's output"
  attr :id_prefix, :string, default: ""
  attr :image_path, :any, required: true, doc: "fn entry_id, index -> the image's path end"

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
        <.action
          :for={call <- @calls}
          call={call}
          result={@results[call["id"]]}
          tail={@outputs[call["id"]]}
          id_prefix={@id_prefix}
          image_path={@image_path}
        />
      </div>
    </div>
    """
  end

  def entry(%{entry: %{kind: "error"}} = assigns) do
    assigns = assign(assigns, quiet: Transcript.quiet?(assigns.entry.data))

    ~H"""
    <div class={[
      "flex items-start gap-2 rounded-xl px-3.5 py-2.5 text-sm",
      if(@quiet, do: "bg-sunken text-ink-soft", else: "bg-bad-soft text-ink")
    ]}>
      <.icon
        name={
          cond do
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

  def entry(%{entry: %{kind: "reset"}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 py-2 text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
      <span class="h-px flex-1 bg-line" /> Fresh context <span class="h-px flex-1 bg-line" />
    </div>
    """
  end

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

  def action_label(assigns) do
    assigns = assign(assigns, :text, label_text(assigns.name, assigns.args))

    ~H"""
    {@text}
    """
  end

  defp label_text("list_machines", _), do: "Checked your machines"

  defp label_text("update_memory", args),
    do: "Memory: #{args["action"]} #{truncate(args["text"])}"

  defp label_text("schedule", args), do: "Scheduled: #{truncate(args["prompt"])}"
  defp label_text("list_schedules", _), do: "Checked the schedule"
  defp label_text("cancel_schedule", args), do: "Cancelled #{args["schedule_id"]}"
  defp label_text(name, _), do: name

  # The words around a skill's name: "Loading the pdf-forms skill",
  # "Couldn't load pdf-form".
  defp skill_words(:pending), do: {"Loading the", " skill"}
  defp skill_words(:error), do: {"Couldn't load", ""}
  defp skill_words(:stopped), do: {"Stopped loading the", " skill"}
  defp skill_words(_done), do: {"Loaded the", " skill"}

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

  # A thread Blip started links to its page.
  defp work_href("start_thread", :done, %{"slug" => slug, "thread_id" => id})
       when is_binary(slug) and is_binary(id),
       do: ~p"/projects/#{slug}/threads/#{id}"

  defp work_href(_name, _status, _details), do: nil

  defp thread_name(args, details) do
    case details["title"] do
      title when is_binary(title) -> ~s("#{title}")
      _none -> args["thread"]
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

  defp action_icon("shell"), do: "hero-command-line-micro"
  defp action_icon("view_image"), do: "hero-photo-micro"
  defp action_icon("list_machines"), do: "hero-server-stack-micro"
  defp action_icon("update_memory"), do: "hero-bookmark-micro"
  defp action_icon("list_context_files"), do: "hero-document-duplicate-micro"
  defp action_icon("read_context_file"), do: "hero-document-text-micro"
  defp action_icon("write_context_file"), do: "hero-document-plus-micro"
  defp action_icon("edit_context_file"), do: "hero-pencil-square-micro"
  defp action_icon("load_skill"), do: "hero-book-open-micro"
  defp action_icon("ask_blip"), do: "hero-chat-bubble-left-ellipsis-micro"
  defp action_icon(name) when name in ~w(list_projects read_project), do: "hero-folder-micro"
  defp action_icon("list_threads"), do: "hero-queue-list-micro"
  defp action_icon("read_thread"), do: "hero-chat-bubble-left-right-micro"
  defp action_icon("start_project"), do: "hero-folder-plus-micro"
  defp action_icon("start_thread"), do: "hero-play-circle-micro"
  defp action_icon("message_thread"), do: "hero-paper-airplane-micro"
  defp action_icon("stop_thread"), do: "hero-stop-circle-micro"

  defp action_icon(name) when name in ~w(schedule list_schedules cancel_schedule),
    do: "hero-clock-micro"

  defp action_icon(_), do: "hero-check-micro"

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
  sends; Shift+Enter starts a new line.
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

  @spec composer(map()) :: Phoenix.LiveView.Rendered.t()
  def composer(assigns) do
    ~H"""
    <div class={["shrink-0 px-3 pt-1 pb-3 sm:px-4 sm:pb-4", @class]}>
      <div class="mx-auto w-full max-w-3xl">
        <div :if={@queued != []} id={"#{@id_prefix}queued"} class="mb-2 flex flex-wrap gap-1.5">
          <span
            :for={s <- @queued}
            id={"#{@id_prefix}queued-#{s.id}"}
            class="flex max-w-full items-center gap-1.5 rounded-full border border-line bg-surface py-1 pr-1 pl-3 text-[12px] text-ink-soft"
          >
            <span class="font-medium text-ink-faint">{if(s.mode == "steer", do: "Steer", else: "Next")}</span>
            <span class="max-w-60 truncate">
              {Transcript.typed(s.content["parts"], s.content["source"])}
            </span>
            <button
              phx-click="withdraw"
              phx-value-id={s.id}
              class="rounded-full p-0.5 hover:bg-sunken"
              title="Withdraw"
            >
              <.icon name="hero-x-mark-micro" class="size-3.5" />
            </button>
          </span>
        </div>

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
            grow()
          }
        }
      </script>
    </div>
    """
  end
end
