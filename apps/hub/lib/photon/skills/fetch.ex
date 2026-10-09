defmodule Photon.Skills.Fetch do
  @moduledoc """
  Downloads skills for `Photon.Skills.fetch/1`, the only place Photon
  fetches them. `Photon.Skills.Source` decides what to ask for and what the
  answers mean; this makes the requests with `Req`.

  A GitHub link costs at most two API calls without a sign-in (the
  repository, for a root link's default branch, and the tree under the
  linked folder, or a file's folder, in one call), then one download per
  SKILL.md. Those downloads run
  through `Task.async_stream/3`, six at a time, each given 20 seconds
  (rule 93). Every request is bounded: no retries, at most 3 redirects,
  15 seconds in all (a server that sends a byte now and then can't hold
  the install page on Fetching), and it stops reading past 256 KB (8 MB
  for an API answer, since a large repository's tree is long).

  Each request runs in a task linked to the caller, so it can be stopped
  at its deadline; the caller's process (the install page's
  `start_async` task) waits for the answer, and the stream's tasks are
  linked to it too.
  """

  alias Photon.Skills.Source

  @file_limit 256 * 1024
  @api_limit 8 * 1024 * 1024
  @receive_timeout 15_000
  @deadline 15_000
  @max_redirects 3
  @concurrency 6
  @download_timeout 20_000

  @typedoc "What `Photon.Skills.fetch/1` returns."
  @type fetched :: {:ok, [Source.candidate()], String.t() | nil} | {:error, String.t()}

  @doc """
  The skills behind a GitHub link: the one in the linked file's or
  folder's own SKILL.md, or up to 30 in the folders under it. When the
  tree can't be listed but the link was to a file, the file is still
  downloaded on its own, with a note that its folder wasn't checked.
  """
  @spec github(Source.github()) :: fetched()
  def github(link) do
    with {:ok, link} <- with_ref(link) do
      case tree(link) do
        {:ok, found, notice} ->
          link |> download_all(found) |> Source.result(notice)

        {:error, _message} when link.kind == :file ->
          Source.result([candidate(Source.unlisted(link), link, link.path)], nil)

        {:error, message} ->
          {:error, message}
      end
    end
  end

  @doc "The SKILL.md at any other address, downloaded as a file."
  @spec web(String.t()) :: fetched()
  def web(url) do
    download = url |> get(:file) |> message(:web)
    Source.result([Source.candidate("fetched", Source.web(url), download)], nil)
  end

  # A root link names no ref: GitHub's answer for the repository has its
  # default branch.
  defp with_ref(%{ref: nil} = link) do
    case get(Source.repo_url(link), :api) do
      {:ok, %{"default_branch" => ref}} when is_binary(ref) and ref != "" ->
        {:ok, %{link | ref: ref}}

      {:ok, _other} ->
        {:error, Source.error_message(:unreadable, {:api, Source.place(link)})}

      {:error, failure} ->
        {:error, Source.error_message(failure, {:api, Source.place(link)})}
    end
  end

  defp with_ref(link), do: {:ok, link}

  defp tree(link) do
    case get(Source.tree_url(link), :api) do
      {:ok, tree} ->
        Source.skills_in_tree(tree, link.path, link.kind)

      {:error, :too_big} when link.kind == :folder ->
        {:error, Source.too_big_to_list(link.path)}

      {:error, failure} ->
        {:error, Source.error_message(failure, {:api, Source.place(link)})}
    end
  end

  # In the tree's order; a download that runs out of time keeps its
  # place with a timeout as its error.
  defp download_all(link, found) do
    found
    |> Task.async_stream(&candidate(Source.folder(link, &1), link, &1.file),
      max_concurrency: @concurrency,
      timeout: @download_timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip_with(found, fn
      {:ok, candidate}, _found ->
        candidate

      {:exit, _reason}, found ->
        folder = Source.folder(link, found)
        Source.candidate("fetched", folder, {:error, Source.error_message(:timeout, :web)})
    end)
  end

  # The folder's SKILL.md (or the linked file), from GitHub's file server.
  defp candidate(folder, link, file) do
    place = Source.place(%{link | kind: :file, path: file})

    download =
      link
      |> Source.raw_url(file)
      |> get(:file)
      |> message({:github, place})

    Source.candidate("fetched", folder, download)
  end

  defp message({:ok, text}, _answerer), do: {:ok, text}
  defp message({:error, failure}, answerer), do: {:error, Source.error_message(failure, answerer)}

  ## Requests

  @doc """
  GETs `url`: an API answer decoded from JSON (`:api`), or a file's text
  (`:file`, refused when it is a web page or not text). Either is
  refused past its size limit. Errors are `Source.failure/0`s, which
  `Source.error_message/2` turns into what to tell the owner.
  """
  @spec get(String.t(), :api | :file) :: {:ok, term()} | {:error, Source.failure()}
  def get(url, kind) do
    task = Task.async(fn -> request(url, kind) end)

    case Task.yield(task, deadline()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      # Only a caller that traps exits hears of a crash this way.
      {:exit, reason} -> {:error, Exception.format_exit(reason)}
      # Past the deadline: the task is gone, and so is its connection.
      nil -> {:error, :timeout}
    end
  end

  defp request(url, kind) do
    case Req.get(url, options(kind)) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        body(response, kind)

      {:ok, %Req.Response{status: status}} ->
        {:error, status}

      {:error, exception} ->
        {:error, reason(exception)}
    end
  end

  defp options(kind) do
    [
      retry: false,
      receive_timeout: @receive_timeout,
      redirect: true,
      max_redirects: @max_redirects,
      decode_body: false,
      headers: headers(kind),
      into: collector(limit(kind))
    ] ++ req_options()
  end

  defp headers(:api),
    do: [accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28"]

  defp headers(:file), do: []

  defp limit(:api), do: @api_limit
  defp limit(:file), do: @file_limit

  # Keeps the body as iodata and stops reading past the limit, so a large
  # answer never sits in memory whole.
  defp collector(limit) do
    fn {:data, data}, {request, response} ->
      size = Req.Response.get_private(response, :size, 0) + byte_size(data)
      chunks = [Req.Response.get_private(response, :chunks, []), data]

      if size > limit do
        {:halt, {request, Req.Response.put_private(response, :too_big, true)}}
      else
        response =
          response
          |> Req.Response.put_private(:size, size)
          |> Req.Response.put_private(:chunks, chunks)

        {:cont, {request, response}}
      end
    end
  end

  defp body(response, kind) do
    if Req.Response.get_private(response, :too_big, false) do
      {:error, :too_big}
    else
      response
      |> Req.Response.get_private(:chunks, [])
      |> IO.iodata_to_binary()
      |> decode(kind, Req.Response.get_header(response, "content-type"))
    end
  end

  defp decode(body, :api, _content_types) do
    case Jason.decode(body) do
      {:ok, answer} -> {:ok, answer}
      {:error, _not_json} -> {:error, :unreadable}
    end
  end

  defp decode(body, :file, content_types), do: Source.text(body, content_types)

  defp reason(%Req.TransportError{reason: :timeout}), do: :timeout
  defp reason(exception) when is_exception(exception), do: Exception.message(exception)
  defp reason(other), do: inspect(other)

  defp req_options, do: config()[:req_options] || []

  defp deadline, do: config()[:deadline] || @deadline

  defp config, do: Application.get_env(:photon, Photon.Skills, [])
end
