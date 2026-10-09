defmodule PhotonWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :photon

  # The session cookie is signed, not encrypted: readable, not forgeable.
  @session_options [
    store: :cookie,
    key: "_photon_key",
    signing_salt: "M5WxSyrW",
    same_site: "Lax"
  ]

  # Nodes dial in here; see PhotonNode for the protocol. Where a
  # connection came from (peer and forwarded address) decides whose it is.
  # Frames are capped at 8 MB on purpose: enough for a view_image snapshot
  # (at most 5 MB of image data), and a node keeps every snapshot under
  # 6 MB of JSON (docs/operations.md, node rule 9).
  socket "/node", PhotonWeb.NodeSocket,
    websocket: [
      connect_info: [:x_headers, :peer_data],
      check_origin: false,
      max_frame_size: 8_000_000
    ],
    longpoll: false

  # Websocket only: a long-poll transport carries its session in a token
  # that any device holding it could keep using, past the device checks.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: false

  # In production (no code reloading), serves the gzipped files
  # `phx.digest` made.
  plug Plug.Static,
    at: "/",
    from: :photon,
    gzip: not code_reloading?,
    only: PhotonWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Bodies are small: every route is a GET, and LiveView is websocket only.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 1_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PhotonWeb.Router
end
