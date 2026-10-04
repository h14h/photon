defmodule Photon.ChatGPT do
  @moduledoc """
  The hub's ChatGPT account: Sign in with ChatGPT is how Photon gets a
  model. Blip and the agents on every node run on the signed-in user's
  ChatGPT plan, through this hub, which holds the tokens; nodes never see
  them.

  This process owns the account. It keeps the tokens in the data directory
  (`chatgpt.json`, mode 0600), refreshes the access token one request at a
  time (OpenAI asks that refreshes for a session be serialized), and
  announces changes on `topic/0` as `{:chatgpt_changed, status}`. The rules
  (the sign-in link, the pasted address, the tokens) are
  `Photon.ChatGPT.OAuth`'s; this module does the HTTP and the file.

  Signing in, see `Photon.ChatGPT.OAuth`: `begin_sign_in/0` returns the
  link, and `finish_sign_in/1` takes the address the browser landed on.

  Tests and local development can use a scripted model instead
  (`config :photon, :mock_model, true`); `llm_config/1` then returns it.
  """

  use Boundary, deps: [Photon.Events, Photon.Paths, PhotonCore.LLM, Jason, Req]

  use GenServer

  require Logger

  alias Photon.ChatGPT.OAuth
  alias Photon.{Events, Paths}

  @topic "chatgpt"
  @models_url "https://api.openai.com/v1/models"
  @models_ttl_ms 10 * 60 * 1000
  @sign_in_ttl_ms 15 * 60 * 1000
  @call_timeout 30_000

  @typedoc """
  Where the account stands: `:signed_out`, `:signed_in`, or
  `:sign_in_again` (the sign-in lapsed or was revoked); who it is; whether
  the user let Photon use their plan; and whether a sign-in is waiting for
  its pasted address.
  """
  @type status :: %{
          state: :signed_out | :signed_in | :sign_in_again,
          email: String.t() | nil,
          name: String.t() | nil,
          plan_use: boolean(),
          signing_in: boolean()
        }

  @typedoc "A model the account can use."
  @type model :: %{id: String.t(), name: String.t()}

  ## API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "PubSub topic carrying `{:chatgpt_changed, status}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok
  def subscribe, do: Events.subscribe(@topic)

  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Starts a sign-in; returns the link to open in a new tab."
  @spec begin_sign_in() :: {:ok, String.t()}
  def begin_sign_in, do: GenServer.call(__MODULE__, :begin_sign_in)

  @doc "Finishes the sign-in with the address the browser landed on."
  @spec finish_sign_in(String.t()) :: :ok | {:error, String.t()}
  def finish_sign_in(pasted),
    do: GenServer.call(__MODULE__, {:finish_sign_in, pasted}, @call_timeout)

  @spec cancel_sign_in() :: :ok
  def cancel_sign_in, do: GenServer.call(__MODULE__, :cancel_sign_in)

  @doc "Signs out: revokes the refresh token and forgets the tokens."
  @spec sign_out() :: :ok
  def sign_out, do: GenServer.call(__MODULE__, :sign_out, @call_timeout)

  @doc "A current access token, refreshed first if it's about to expire."
  @spec access_token() :: {:ok, String.t()} | {:error, String.t()}
  def access_token, do: GenServer.call(__MODULE__, :access_token, @call_timeout)

  @doc """
  Says the API refused `token` (a 401), so the next `access_token/0`
  refreshes it rather than handing it out again.
  """
  @spec token_rejected(String.t()) :: :ok
  def token_rejected(token), do: GenServer.call(__MODULE__, {:token_rejected, token})

  @doc "The models the account can use, in the server's order (cached for a few minutes)."
  @spec models() :: {:ok, [model()]} | {:error, String.t()}
  def models, do: GenServer.call(__MODULE__, :models, @call_timeout)

  @doc """
  Whether Blip can think: signed in with plan use allowed, or the hub is
  set to the scripted model.
  """
  @spec ready?(status()) :: boolean()
  def ready?(status) do
    Application.get_env(:photon, :mock_model, false) or
      (status.state == :signed_in and status.plan_use)
  end

  @doc """
  The model config for a request now: ChatGPT with a current token, or,
  when the hub is set to the scripted model, `script` (see the moduledoc).
  Without a sign-in the token is nil, and the request fails saying so.
  """
  @spec llm_config(module()) :: PhotonCore.LLM.config()
  def llm_config(script) do
    if Application.get_env(:photon, :mock_model, false) do
      %{provider: "mock", script: script}
    else
      token =
        case access_token() do
          {:ok, token} -> token
          {:error, _reason} -> nil
        end

      %{provider: "chatgpt", base_url: OAuth.resource(), api_key: token}
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    {:ok, %{account: load(), pending: nil, models: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  def handle_call(:begin_sign_in, _from, state) do
    {pending, url} = OAuth.begin(secrets(), state.account, state.account["host_id"], now())
    state = %{state | pending: pending}
    announce(state)
    {:reply, {:ok, url}, state}
  end

  def handle_call(:cancel_sign_in, _from, state) do
    state = %{state | pending: nil}
    announce(state)
    {:reply, :ok, state}
  end

  def handle_call({:finish_sign_in, pasted}, _from, state) do
    case finish(state, pasted) do
      {:ok, state} ->
        announce(state)
        {:reply, :ok, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:sign_out, _from, state) do
    :ok = revoke(state.account["credentials"])
    state = put_account(state, signed_out(state.account, nil))
    announce(state)
    {:reply, :ok, %{state | models: nil}}
  end

  def handle_call(:access_token, _from, state) do
    {reply, state} = fresh_token(state)
    {:reply, reply, state}
  end

  def handle_call(:models, _from, state) do
    {reply, state} = fetch_models(state)
    {:reply, reply, state}
  end

  def handle_call({:token_rejected, token}, _from, state) do
    case state.account["credentials"] do
      %{"access_token" => ^token} = credentials ->
        account = %{state.account | "credentials" => %{credentials | "expires_at" => 0}}
        {:reply, :ok, put_account(state, account)}

      _other ->
        {:reply, :ok, state}
    end
  end

  ## Signing in

  defp finish(%{pending: nil} = state, _pasted),
    do: {:error, "No sign-in is waiting. Start again with Sign in with ChatGPT.", state}

  defp finish(%{pending: pending} = state, pasted) do
    with :ok <- fresh?(pending),
         {:ok, %{code: code, client_id: client_id}} <- OAuth.read_callback(pasted, pending) do
      # The issued client ID is kept before the code is traded, so a failed
      # trade doesn't register Photon a second time.
      state
      |> put_account(Map.put(state.account, "client_id", client_id))
      |> trade(pending, code, client_id)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp trade(state, pending, code, client_id) do
    expect = %{client_id: client_id, nonce: pending.nonce}

    with {:ok, response} <- token_request(OAuth.exchange_form(pending, code, client_id)),
         {:ok, credentials} <- OAuth.credentials(response, expect, nil, now()) do
      account =
        Map.merge(state.account, %{
          "credentials" => credentials,
          "email" => credentials["email"],
          "id_token" => credentials["id_token"],
          "problem" => nil
        })

      {:ok, %{put_account(state, account) | pending: nil, models: nil}}
    else
      {:error, {:token, body}} ->
        {:error, "ChatGPT didn't accept the sign-in: #{token_error(body)}", state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp fresh?(pending) do
    if now() - pending.started_at < @sign_in_ttl_ms,
      do: :ok,
      else: {:error, "That sign-in is too old. Start again."}
  end

  ## Tokens

  defp fresh_token(%{account: %{"credentials" => nil}} = state),
    do: {{:error, "Not signed in with ChatGPT."}, state}

  defp fresh_token(%{account: %{"credentials" => credentials}} = state) do
    if OAuth.refresh_due?(credentials, now()),
      do: refresh(state, credentials),
      else: {{:ok, credentials["access_token"]}, state}
  end

  defp refresh(state, credentials) do
    expect = %{client_id: credentials["client_id"], sub: credentials["sub"]}

    with {:ok, response} <- token_request(OAuth.refresh_form(credentials)),
         {:ok, renewed} <- OAuth.credentials(response, expect, credentials, now()) do
      account =
        Map.merge(state.account, %{"credentials" => renewed, "id_token" => renewed["id_token"]})

      {{:ok, renewed["access_token"]}, put_account(state, account)}
    else
      {:error, {:token, body}} -> refresh_failed(state, body)
      {:error, reason} -> {{:error, "Couldn't refresh the ChatGPT sign-in: #{reason}"}, state}
    end
  end

  defp refresh_failed(state, body) do
    case OAuth.failure(body) do
      :sign_in_again ->
        Logger.warning("ChatGPT sign-in lapsed: #{inspect(body)}")

        state =
          put_account(
            state,
            signed_out(state.account, "Your ChatGPT sign-in lapsed. Sign in again.")
          )

        announce(state)
        {{:error, "The ChatGPT sign-in lapsed. Sign in again in Settings."}, state}

      :retry_later ->
        {{:error, "Couldn't refresh the ChatGPT sign-in: #{token_error(body)}"}, state}
    end
  end

  defp token_request(form) do
    case Req.post(OAuth.token_url(), [form: form, retry: false] ++ req_options()) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{body: body}} -> {:error, {:token, body}}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp token_error(%{"error_description" => description}) when is_binary(description),
    do: description

  defp token_error(%{"error" => error}) when is_binary(error), do: error
  defp token_error(body), do: inspect(body)

  # Signing out is best effort: the tokens are forgotten either way, and
  # OpenAI answers an empty 200 even for a token that's already invalid.
  defp revoke(nil), do: :ok

  defp revoke(credentials) do
    case Req.post(
           OAuth.revoke_url(),
           [form: OAuth.revoke_form(credentials), retry: false] ++ req_options()
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> Logger.warning("couldn't revoke the ChatGPT sign-in: #{inspect(other)}")
    end
  end

  ## Models

  defp fetch_models(%{models: {at, models}} = state) when is_list(models) do
    if now() - at < @models_ttl_ms,
      do: {{:ok, models}, state},
      else: fetch_models(%{state | models: nil})
  end

  defp fetch_models(state) do
    with {{:ok, token}, state} <- fresh_token(state) do
      case Req.get(@models_url, [auth: {:bearer, token}, retry: false] ++ req_options()) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          models = OAuth.models(body)
          {{:ok, models}, %{state | models: {now(), models}}}

        {:ok, %Req.Response{status: status}} ->
          {{:error, "ChatGPT didn't list models (HTTP #{status})."}, state}

        {:error, exception} ->
          {{:error, Exception.message(exception)}, state}
      end
    end
  end

  ## The account file

  defp load do
    with {:ok, body} <- File.read(Paths.chatgpt_file()),
         {:ok, %{"host_id" => host_id} = account} when is_binary(host_id) <- Jason.decode(body) do
      Map.merge(blank(host_id), account)
    else
      _ ->
        16 |> :crypto.strong_rand_bytes() |> OAuth.uuid() |> OAuth.host_id() |> blank() |> save()
    end
  end

  defp blank(host_id) do
    %{
      "host_id" => host_id,
      "client_id" => nil,
      "email" => nil,
      "id_token" => nil,
      "credentials" => nil,
      "problem" => nil
    }
  end

  defp signed_out(account, problem), do: %{account | "credentials" => nil, "problem" => problem}

  defp put_account(state, account), do: %{state | account: save(account)}

  defp save(account) do
    path = Paths.chatgpt_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(account, pretty: true))
    File.chmod!(path, 0o600)
    account
  end

  ## Helpers

  defp status(%{account: account, pending: pending}) do
    credentials = account["credentials"]

    %{
      state:
        cond do
          credentials != nil -> :signed_in
          account["problem"] != nil -> :sign_in_again
          true -> :signed_out
        end,
      email: account["email"],
      name: credentials && credentials["name"],
      plan_use: credentials != nil and OAuth.plan_use?(credentials),
      signing_in: pending != nil
    }
  end

  defp announce(state), do: Events.broadcast(@topic, {:chatgpt_changed, status(state)})

  defp secrets do
    <<port::16>> = :crypto.strong_rand_bytes(2)

    %{
      verifier: random(32),
      state: random(16),
      nonce: random(16),
      port: 49_152 + rem(port, 16_384)
    }
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp now, do: System.system_time(:millisecond)

  defp req_options, do: Application.get_env(:photon, __MODULE__, [])[:req_options] || []
end
