defmodule HTTP2.Server.Ranch do
  require Logger

  defstruct conn: nil, socket: nil, transport: nil, ref: nil

  def start_link(ref, _socket, transport, opts) do
    pid = spawn_link(__MODULE__, :init, [{ref, transport, opts}])
    {:ok, pid}
  end

  def init({ref, transport, _opts}) do
    Logger.info("#{ref} started handshake")
    {:ok, socket} = :ranch.handshake(ref)
    Logger.info("#{ref} finished handshake")
    conn = HTTP2.Connection.new_server()
    send = fn data -> transport.send(socket, data) end
    conn = %{conn | events_handler: %HTTP2.Server.ConnHandler{send_fn: send}}
    transport.setopts(socket, [active: 1024])
    state = %__MODULE__{conn: conn, socket: socket, transport: transport, ref: ref}
    loop(state)
  end

  def loop(%{conn: conn, socket: socket, transport: transport, ref: ref} = state) do
    receive do
      {:tcp, socket, data} ->
        conn = HTTP2.Connection.recv(conn, data)

        loop(%{state | conn: conn})
      {:tcp_closed, socket} ->
        Logger.info("#{ref} socket closed")
      {:tcp_error, socket, reason} ->
        Logger.error("#{ref} has error #{inspect(reason)}")
      {:tcp_passive, socket} ->
        transport.setopts(socket, [active: 1024])
        loop(state)
      other ->
        IO.inspect other
    end
  end
end
