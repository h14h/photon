defmodule Photon.ChatGPT do
  @moduledoc """
  The hub's ChatGPT account: Sign in with ChatGPT is how Photon gets a
  model. Blip and the agents on every node run on the signed-in user's
  ChatGPT plan, through this hub, which holds the tokens; nodes never see
  them.

  This process owns the account. It keeps the tokens in the data directory
  (`chatgpt.json`, mode 0600, replaced whole by `Photon.PrivateFile`),
  refreshes the access token one request at a time (OpenAI asks that
  refreshes for a session be serialized), and announces changes on
  `topic/0` as `{:chatgpt_changed, status}`. It hands out a token only
  while the user lets Photon use their plan, and its state (tokens,
  sign-in secrets) never appears in crash reports (`format_status/1`).

  Model requests go through `stream/3`, which tells this process when the
  API refuses a token, so the next request gets a fresh one. The rules
  (the sign-in link, the pasted address, the tokens) are
  `Photon.ChatGPT.OAuth`'s; this module does the HTTP and the file.

  Signing in, see `Photon.ChatGPT.OAuth`: `begin_sign_in/0` returns the
  link, and `finish_sign_in/1` takes the address the browser landed on.

  Tests and local development can use a scripted model instead
  (`config :photon, :mock_model, true`); `llm_config/1` then returns it.
  """

  use Boundary,
    deps: [
      Photon.Events,
      Photon.Paths,
      Photon.PrivateFile,
      PhotonCore.LLM,
      PhotonCore.LLM.Error,
      Jason,
      Req
    ]

  use GenServer

  require Logger

  alias Photon.ChatGPT.OAuth
  alias Photon.{Events, Paths, PrivateFile}
  alias PhotonCore.LLM

  @topic "chatgpt"
  @models_url "https://api.openai.com/v1/models"
  @models_ttl_ms 10 * 60 * 1000
  @sign_in_ttl_ms 15 * 60 * 1000
  @call_timeout 30_000
  @no_plan_use "Photon isn't allowed to use your ChatGPT plan. Sign in again and allow it."

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

  @doc """
  Finishes the sign-in with the address the browser landed on. The address
  carries a one-time code, so a call that fails (it timed out, say) comes
  back as an error rather than an exit, whose reason would hold it.
  """
  @spec finish_sign_in(String.t()) :: :ok | {:error, String.t()}
  def finish_sign_in(pasted) do
    GenServer.call(__MODULE__, {:finish_sign_in, pasted}, @call_timeout)
  catch
    :exit, _reason -> {:error, "Signing in didn't finish in time. Start again."}
  end

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
  def token_rejected(token),
    do: GenServer.call(__MODULE__, {:token_rejected, fingerprint(token)})

  # What names a token in messages, so no exit reason or crash report holds it.
  defp fingerprint(token), do: :crypto.hash(:sha256, token)

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
  Without a token (signed out, plan use not allowed, a refresh that
  failed) the token is nil and `:problem` says why, which is what the
  request fails with.
  """
  @spec llm_config(module()) :: LLM.config()
  def llm_config(script) do
    if Application.get_env(:photon, :mock_model, false) do
      %{provider: "mock", script: script}
    else
      case access_token() do
        {:ok, token} ->
          %{provider: "chatgpt", base_url: OAuth.resource(), api_key: token}

        {:error, reason} ->
          %{provider: "chatgpt", base_url: OAuth.resource(), api_key: nil, problem: reason}
      end
    end
  end

  @doc """
  Runs a model request with `config` (from `llm_config/1`), as
  `PhotonCore.LLM.stream/3` does, in the caller. If the API refuses the
  token (a 401), says so with `token_rejected/1`, so the next request gets
  a fresh one. Blip's turns go through here.
  """
  @spec stream(LLM.request(), LLM.config(), LLM.on_event()) ::
          {:ok, LLM.response()} | {:error, PhotonCore.LLM.Error.t()}
  def stream(request, config, on_event) do
    result = LLM.stream(request, config, on_event)

    case {result, config} do
      {{:error, %PhotonCore.LLM.Error{status: 401}}, %{api_key: token}} when is_binary(token) ->
        token_rejected(token)

      _other ->
        :ok
    end

    result
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

  def handle_call({:token_rejected, fingerprint}, _from, state),
    do: {:reply, :ok, expire(state, fingerprint)}

  # Crash reports and `:sys.get_status/1` show the state and the last
  # message; tokens and sign-in secrets are left out of both.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, redact(state)}
      {:message, message} -> {:message, redact_message(message)}
      {:log, _log} -> {:log, []}
      other -> other
    end)
  end

  # The state with its secrets replaced by `:redacted`.
  defp redact(%{account: account, pending: pending} = state) do
    secret = fn
      {key, value} when key in ["credentials", "id_token"] and value != nil -> {key, :redacted}
      pair -> pair
    end

    %{state | account: Map.new(account, secret), pending: pending && :redacted}
  end

  defp redact(state), do: state

  defp redact_message({:"$gen_call", from, {:finish_sign_in, _pasted}}),
    do: {:"$gen_call", from, {:finish_sign_in, :redacted}}

  defp redact_message(message), do: message

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
    do: {{:error, "The hub isn't signed in with ChatGPT."}, state}

  defp fresh_token(%{account: %{"credentials" => credentials}} = state) do
    cond do
      not OAuth.plan_use?(credentials) -> {{:error, @no_plan_use}, state}
      OAuth.refresh_due?(credentials, now()) -> refresh(state, credentials)
      true -> {{:ok, credentials["access_token"]}, state}
    end
  end

  # The API refused the token with this fingerprint: if it's still the
  # current one, the next request refreshes it rather than handing it out
  # again.
  defp expire(state, fingerprint) do
    case state.account["credentials"] do
      %{"access_token" => token} = credentials when is_binary(token) ->
        if fingerprint(token) == fingerprint,
          do: expire_credentials(state, credentials),
          else: state

      _signed_out ->
        state
    end
  end

  defp expire_credentials(state, credentials),
    do: put_account(state, %{state.account | "credentials" => %{credentials | "expires_at" => 0}})

  defp refresh(state, credentials) do
    expect = %{client_id: credentials["client_id"], sub: credentials["sub"]}

    with {:ok, response} <- token_request(OAuth.refresh_form(credentials)),
         {:ok, renewed} <- OAuth.credentials(response, expect, credentials, now()) do
      account =
        Map.merge(state.account, %{"credentials" => renewed, "id_token" => renewed["id_token"]})

      state = put_account(state, account)

      # A refresh can come back with less than the user granted before.
      if OAuth.plan_use?(renewed),
        do: {{:ok, renewed["access_token"]}, state},
        else: {{:error, @no_plan_use}, state}
    else
      {:error, {:token, body}} -> refresh_failed(state, body)
      {:error, reason} -> {{:error, "Couldn't refresh the ChatGPT sign-in: #{reason}"}, state}
    end
  end

  defp refresh_failed(state, body) do
    case OAuth.failure(body) do
      :sign_in_again ->
        Logger.warning("ChatGPT sign-in lapsed: #{token_error(body)}")

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
      {:ok, %Req.Response{status: status}} -> revoke_failed("HTTP #{status}")
      {:error, exception} -> revoke_failed(Exception.message(exception))
    end
  end

  defp revoke_failed(reason) do
    Logger.warning("couldn't revoke the ChatGPT sign-in: #{reason}")
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

        {:ok, %Req.Response{status: 401}} ->
          {{:error, "ChatGPT refused the sign-in's token. Try again."},
           expire(state, fingerprint(token))}

        {:ok, %Req.Response{status: status}} ->
          {{:error, "ChatGPT didn't list models (HTTP #{status})."}, state}

        {:error, exception} ->
          {{:error, Exception.message(exception)}, state}
      end
    end
  end

  ## The account file

  # A missing file is a new hub. One that can't be read stops the hub
  # rather than being replaced (that would lose the sign-in for good); one
  # that isn't an account is set aside, with a note in the log.
  defp load do
    path = Paths.chatgpt_file()

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"host_id" => host_id} = account} when is_binary(host_id) ->
            Map.merge(blank(host_id), account)

          _malformed ->
            set_aside(path)
            new_account()
        end

      {:error, :enoent} ->
        new_account()

      {:error, reason} ->
        raise "couldn't read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp new_account,
    do: 16 |> :crypto.strong_rand_bytes() |> OAuth.uuid() |> OAuth.host_id() |> blank() |> save()

  defp set_aside(path) do
    aside = "#{path}.unreadable-#{System.system_time(:second)}"
    File.rename!(path, aside)
    Logger.error("#{path} wasn't a ChatGPT account; moved it to #{aside}. Sign in again.")
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
    :ok = PrivateFile.write!(Paths.chatgpt_file(), Jason.encode_to_iodata!(account, pretty: true))
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
