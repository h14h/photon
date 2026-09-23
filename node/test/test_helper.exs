data_dir = Path.join(System.tmp_dir!(), "photon-node-test-#{System.unique_integer([:positive])}")
File.rm_rf!(data_dir)

# The server is unreachable, so the connection just keeps retrying; runs and
# logs work regardless, which is the point.
{:ok, _} =
  PhotonNode.start_link(
    server: "ws://127.0.0.1:9/node/websocket",
    token: "test",
    node_id: "test-node",
    data_dir: data_dir
  )

ExUnit.start()
