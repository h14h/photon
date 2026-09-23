defmodule PhotonWeb.TranscriptComponents do
  @moduledoc "Renders `Photon.Transcript` entries."

  use PhotonWeb, :html

  attr :entry, :map, required: true
  attr :show_control, :boolean, default: false
  attr :session_id, :string, default: nil

  def entry(%{entry: %{type: :user}} = assigns) do
    {text, images} = Photon.Attachments.split(assigns.entry.text)
    assigns = assign(assigns, text: text, images: images)

    ~H"""
    <div class="flex flex-col items-end gap-1.5">
      <div :if={@images != []} class="flex max-w-[80%] flex-wrap items-end justify-end gap-1.5">
        <a
          :for={path <- @images}
          href={image_url(@session_id, path)}
          target="_blank"
          title={path}
          class="block overflow-hidden rounded-xl border border-base-300 bg-base-200"
        >
          <img src={image_url(@session_id, path)} alt={path} class="max-h-40 max-w-60 object-cover" />
        </a>
      </div>
      <div
        :if={@text != ""}
        class="max-w-[80%] rounded-2xl rounded-br-md bg-primary px-4 py-2.5 text-primary-content shadow-sm"
      >
        <p class="whitespace-pre-wrap break-words text-[15px] leading-relaxed">{@text}</p>
      </div>
    </div>
    """
  end

  def entry(%{entry: %{type: :assistant}} = assigns) do
    ~H"""
    <div class="group flex gap-3">
      <div class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-lg bg-base-300 text-base-content/70">
        <.icon name="hero-sparkles-micro" class="size-4" />
      </div>
      <div class="min-w-0 flex-1">
        <.markdown text={@entry.text} />
        <div class="mt-1 flex gap-3 font-mono text-[11px] text-base-content/40 opacity-0 transition group-hover:opacity-100">
          <span :if={@entry.meta.stop}>stop: {@entry.meta.stop}</span>
          <span :if={@entry.meta.usage}>
            {@entry.meta.usage["InputTokens"]} in · {@entry.meta.usage["OutputTokens"]} out
          </span>
          <span :if={@entry.meta.at}>{time(@entry.meta.at)}</span>
        </div>
      </div>
    </div>
    """
  end

  def entry(%{entry: %{type: :reasoning}} = assigns) do
    ~H"""
    <details class="group ml-10 text-sm text-base-content/60">
      <summary class="flex cursor-pointer list-none items-center gap-1.5 select-none hover:text-base-content/80">
        <.icon name="hero-light-bulb-micro" class="size-3.5" />
        <span>Reasoning</span>
        <.icon name="hero-chevron-right-micro" class="size-3.5 transition group-open:rotate-90" />
      </summary>
      <p class="mt-2 whitespace-pre-wrap border-l-2 border-base-300 pl-3 italic">{@entry.text}</p>
    </details>
    """
  end

  def entry(%{entry: %{type: :tool}} = assigns) do
    ~H"""
    <details
      class="group ml-10 overflow-hidden rounded-xl border border-base-300 bg-base-200/60"
      open={@entry.status in [:running, :pending]}
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2 select-none hover:bg-base-300/40">
        <.icon name={tool_icon(@entry.name)} class="size-4 shrink-0 text-base-content/60" />
        <span class="shrink-0 text-xs font-semibold tracking-wide text-base-content/70 uppercase">
          {@entry.name}
        </span>
        <code class="min-w-0 flex-1 truncate font-mono text-[13px]">{tool_summary(@entry)}</code>
        <.status status={@entry.status} exit_code={@entry[:exit_code]} />
        <.icon
          name="hero-chevron-right-micro"
          class="size-4 shrink-0 text-base-content/40 transition group-open:rotate-90"
        />
      </summary>
      <div class="space-y-2 border-t border-base-300 px-3 py-2.5">
        <pre
          :if={@entry.name == "Bash" and @entry.args["command"]}
          class="overflow-x-auto font-mono text-[13px] text-base-content/80"
        ><span class="select-none text-base-content/40">$ </span>{@entry.args["command"]}</pre>
        <pre
          :if={@entry.name not in ["Bash", "ViewImage"]}
          class="overflow-x-auto font-mono text-xs text-base-content/70"
        >{@entry.raw_args}</pre>
        <p
          :if={@entry.status in [:pending, :running]}
          class="flex items-center gap-2 text-sm text-base-content/50"
        >
          <span class="loading loading-dots loading-xs"></span>
          {if @entry.status == :pending, do: "Submitted", else: "Running asynchronously"}
        </p>
        <pre
          :if={present?(@entry[:stdout])}
          class="max-h-96 overflow-auto rounded-lg bg-base-300/70 p-2.5 font-mono text-[12.5px] leading-relaxed whitespace-pre-wrap"
        >{@entry.stdout}</pre>
        <div :if={present?(@entry[:stderr])}>
          <div class="mb-1 text-[11px] font-semibold tracking-wide text-warning uppercase">
            stderr
          </div>
          <pre class="max-h-64 overflow-auto rounded-lg bg-warning/10 p-2.5 font-mono text-[12.5px] whitespace-pre-wrap">{@entry.stderr}</pre>
        </div>
        <p
          :if={present?(@entry[:error])}
          class="rounded-lg bg-error/10 px-2.5 py-1.5 font-mono text-[12.5px] text-error"
        >
          {@entry.error}
        </p>
        <p
          :if={
            @entry.status == :completed and @entry.name == "Bash" and not present?(@entry[:stdout]) and
              not present?(@entry[:stderr])
          }
          class="text-sm text-base-content/40 italic"
        >
          (no output)
        </p>
        <div :if={@entry[:image]} class="space-y-1">
          <img
            src={"data:#{@entry.image.mime};base64,#{@entry.image.data}"}
            class="max-h-96 rounded-lg border border-base-300"
          />
          <p :if={@entry[:image_meta]} class="font-mono text-[11px] text-base-content/50">
            {image_caption(@entry.image_meta)}
          </p>
        </div>
      </div>
    </details>
    """
  end

  def entry(%{entry: %{type: :error}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2 rounded-xl border border-error/30 bg-error/10 px-3 py-2.5 text-sm text-error">
      <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4 shrink-0" />
      <p class="font-mono text-[13px] break-words whitespace-pre-wrap">{@entry.text}</p>
    </div>
    """
  end

  def entry(%{entry: %{type: :stderr}} = assigns) do
    ~H"""
    <p class="font-mono text-xs break-all text-base-content/50">
      <span class="text-warning/80">stderr›</span> {@entry.text}
    </p>
    """
  end

  def entry(%{entry: %{type: :exit}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 py-1 text-[11px] tracking-wide text-base-content/40 uppercase">
      <div class="h-px flex-1 bg-base-300"></div>
      <span>{exit_label(@entry.status)}</span>
      <div class="h-px flex-1 bg-base-300"></div>
    </div>
    """
  end

  def entry(%{entry: %{type: :control}} = assigns) do
    ~H"""
    <div :if={@show_control} class="flex justify-center">
      <span class="rounded-full bg-base-200 px-2.5 py-0.5 font-mono text-[11px] text-base-content/50">
        {@entry.text}
      </span>
    </div>
    """
  end

  defp image_url(session_id, path),
    do: "/sessions/#{session_id}/attachments/#{Path.basename(path)}"

  attr :status, :atom, required: true
  attr :exit_code, :any, default: nil

  defp status(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded-full px-2 py-0.5 font-mono text-[11px]",
      status_class(@status, @exit_code)
    ]}>
      {status_label(@status, @exit_code)}
    </span>
    """
  end

  defp status_class(:completed, code) when code in [nil, 0], do: "bg-success/15 text-success"
  defp status_class(:completed, _code), do: "bg-warning/15 text-warning"
  defp status_class(s, _) when s in [:running, :pending], do: "bg-info/15 text-info"
  defp status_class(:interrupted, _), do: "bg-warning/15 text-warning"
  defp status_class(_, _), do: "bg-error/15 text-error"

  defp status_label(:completed, code) when code not in [nil, 0], do: "exit #{code}"
  defp status_label(:completed, _), do: "done"
  defp status_label(status, _), do: Atom.to_string(status)

  defp tool_icon("Bash"), do: "hero-command-line-micro"
  defp tool_icon("ViewImage"), do: "hero-photo-micro"
  defp tool_icon("SkillUse"), do: "hero-book-open-micro"
  defp tool_icon(_), do: "hero-wrench-micro"

  defp tool_summary(%{name: "Bash", args: %{"command" => command}}), do: first_line(command)
  defp tool_summary(%{name: "ViewImage", args: %{"path" => path}}), do: path
  defp tool_summary(%{raw_args: raw}), do: raw

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp image_caption(meta) do
    [
      meta.original_mime,
      meta.width && meta.height && "#{meta.width}×#{meta.height}",
      meta.scale && meta.scale < 1 && "scaled ×#{Float.round(meta.scale * 1.0, 3)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp exit_label(0), do: "run finished"
  defp exit_label(130), do: "run interrupted"
  defp exit_label(status), do: "runner exited with #{status}"

  defp present?(value), do: is_binary(value) and value != ""

  defp time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ""
    end
  end

  @doc "Renders CommonMark and GitHub-flavored Markdown through the safe renderer."
  attr :text, :string, required: true

  def markdown(assigns) do
    assigns = assign(assigns, :html, Photon.Markdown.to_html(assigns.text))

    ~H"""
    <div class="markdown-body">{Phoenix.HTML.raw(@html)}</div>
    """
  end
end
