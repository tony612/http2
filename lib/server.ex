defmodule HTTP2.Server do
  defstruct id: nil, port: nil, tls_config: nil, max_conns: 16384, num_acceptors: 100, payload: %{}

  def listen(server) do
    transport =
      if server.tls_config do
        :ranch_ssl
      else
        :ranch_tcp
      end

    {:ok, pid} =
      :ranch.start_listener(
        server.id,
        transport,
        [port: server.port, max_connections: server.max_conns, num_acceptors: server.num_acceptors],
        HTTP2.Server.Ranch,
        []
      )

    %{payload: payload} = server
    {:ok, %{server | payload: Map.put(payload, :ranch_pid, pid)}}
  end
end
