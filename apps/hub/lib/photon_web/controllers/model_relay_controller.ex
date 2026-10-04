defmodule PhotonWeb.ModelRelayController do
  @moduledoc """
  The model relay nodes use: `POST /node/llm/stream`, authenticated with the
  node token as a bearer token.

  A node sends a request without any provider in it (the conversation, the
  tools and the system prompt; see `PhotonCore.LLM.Relay.body/1`). The hub
  runs it itself, on the signed-in ChatGPT plan with the model and reasoning
  effort in its settings, and streams back what happens, in the relay's
  format (`PhotonCore.LLM.Relay`). So nodes never see a token, and a change
  of model applies to every node session's next turn. It serves Photon's
  own nodes only (their token), not other tools: Sign in with ChatGPT's
  terms don't allow a general-purpose API.

  The request runs in a task linked to this process, which streams each
  event as it comes, and a keep-alive while nothing does (the model may
  think for a while). If the node goes away mid-answer, the task stops.
  With the scripted model (tests) it answers with `PhotonCore.LLM.MockAgent`.
  """

  use PhotonWeb, :controller

  alias Photon.{ChatGPT, Settings}
  alias PhotonCore.LLM
  alias PhotonCore.LLM.{Error, Relay}

  @keep_alive_ms 15_000

  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, params) do
    if authorized?(conn) do
      relay(conn, request(params, Settings.load()), ChatGPT.llm_config(PhotonCore.LLM.MockAgent))
    else
      refuse(conn, 401, Error.new(:config, "invalid node token"))
    end
  end

  defp authorized?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Photon.NodeAuth.valid?(token)
      _ -> false
    end
  end

  # The node's conversation, with the hub's model and effort.
  defp request(params, settings) do
    %{
      model: Settings.model(settings),
      system: text(params["system"]),
      messages: list(params["messages"]),
      tools: list(params["tools"]),
      reasoning: text(settings["reasoning"]),
      cache_key: text(params["cache_key"])
    }
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp relay(conn, _request, %{provider: "chatgpt", api_key: nil}) do
    refuse(conn, 503, Error.new(:config, "The hub isn't signed in with ChatGPT."))
  end

  defp relay(conn, request, config) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    relay = self()

    task =
      Task.async(fn ->
        result = LLM.stream(request, config, &send(relay, {:llm_event, &1}))
        send(relay, {:llm_done, result})
      end)

    forward(conn, task, config)
  end

  defp forward(conn, task, config) do
    next = &forward(&1, task, config)

    receive do
      {:llm_event, event} ->
        send_or_stop(conn, Relay.event(event), task, next)

      {:llm_done, result} ->
        # The task is ending; this collects its reply and its monitor.
        _sent = Task.await(task)
        finish(conn, result, config)
    after
      @keep_alive_ms -> send_or_stop(conn, Relay.keep_alive(), task, next)
    end
  end

  # A node that went away takes its request with it.
  defp send_or_stop(conn, data, task, continue) do
    case chunk(conn, data) do
      {:ok, conn} ->
        continue.(conn)

      {:error, _closed} ->
        # The node is gone, so nobody waits for the answer.
        _ = Task.shutdown(task, :brutal_kill)
        conn
    end
  end

  defp finish(conn, {:ok, response}, _config), do: last_chunk(conn, Relay.done(response))

  defp finish(conn, {:error, %Error{status: 401} = error}, %{api_key: token})
       when is_binary(token) do
    :ok = ChatGPT.token_rejected(token)
    last_chunk(conn, Relay.error(error))
  end

  defp finish(conn, {:error, error}, _config), do: last_chunk(conn, Relay.error(error))

  defp last_chunk(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp refuse(conn, status, error),
    do: conn |> put_status(status) |> json(%{"error" => Relay.encode_error(error)})
end
