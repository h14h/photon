defmodule Photon.Attachments do
  @moduledoc """
  Images attached to a message.

  `unreal-agent-runner` takes text messages only; the harness sees images
  through its ViewImage tool, which reads files from the workspace. So an
  attachment travels with `start_run` to the node, which writes it into the
  workspace under `.attachments/`, and the message gets a note listing the
  paths. The hub keeps its own copy under `sessions/<id>/attachments/` so the
  transcript can show it, recognising the note with `split/1`.
  """

  @dir ".attachments"
  @exts ~w(.png .jpg .jpeg .webp)
  @note_header "Attached images (in the workspace; open them with ViewImage):"

  @doc "Extensions accepted for upload: formats both browsers and ViewImage handle."
  def exts, do: @exts

  @doc "A unique, shell- and path-safe workspace path for an uploaded file."
  def workspace_path(client_name, index) do
    ext = client_name |> Path.extname() |> String.downcase()
    ext = if ext in @exts, do: ext, else: ".png"

    base =
      client_name
      |> Path.basename()
      |> Path.rootname()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.replace(~r/\A[-.]+|[-.]+\z/, "")
      |> String.slice(0, 40)

    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    index = index |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "")
    name = Enum.join(Enum.reject([stamp, index, base], &(&1 == "")), "-")
    "#{@dir}/#{name}#{ext}"
  end

  @doc "Whether a path is one `workspace_path/2` could have produced."
  def valid_path?(path) when is_binary(path) do
    path =~ ~r/\A\.attachments\/[A-Za-z0-9._-]{1,80}\z/ and Path.extname(path) in @exts
  end

  def valid_path?(_), do: false

  @doc "The prompt with a note pointing the agent at its attachments."
  def with_note(prompt, []), do: prompt

  def with_note(prompt, paths) do
    note = Enum.map_join(paths, "\n", &"- #{&1}")
    String.trim("#{prompt}\n\n#{@note_header}\n#{note}")
  end

  @doc "Splits a message into its own text and the attachment paths in its note."
  def split(text) when is_binary(text) do
    case String.split(text, @note_header, parts: 2) do
      [own, note] ->
        paths =
          for "- " <> path <- String.split(note, "\n", trim: true), valid_path?(path), do: path

        {String.trim(own), paths}

      [_] ->
        {text, []}
    end
  end

  ## The hub's copies

  def hub_dir(session_id), do: Path.join([Photon.Paths.sessions_dir(), session_id, "attachments"])

  def save!(session_id, path, data) do
    dest = Path.join(hub_dir(session_id), Path.basename(path))
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, data)
    dest
  end

  @doc "The hub's copy of an attachment, if it has one."
  def hub_file(session_id, name) do
    path = Path.join(hub_dir(session_id), name)

    if valid_path?("#{@dir}/#{name}") and Regex.match?(~r/\A[0-9a-f-]{36}\z/, session_id) and
         File.regular?(path),
       do: {:ok, path},
       else: :error
  end

  def mime(path) do
    case Path.extname(path) do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
