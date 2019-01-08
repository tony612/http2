defmodule HTTP2.Connection do
  alias HTTP2.Const
  require HTTP2.Const

  # Default values for SETTINGS frame, as defined by the spec.
  @spec_default_connection_settings %{
    header_table_size: 4096,
    # enabled for servers
    enable_push: 1,
    max_concurrent_streams: Const.max_stream_id(),
    initial_window_size: Const.init_window_size(),
    max_frame_size: Const.init_max_frame_size(),
    # 2^31 - 1
    max_header_list_size: Const.init_max_header_list_size()
  }

  override_settings = %{
    max_concurrent_streams: 100
  }

  @default_connection_settings Map.merge(@spec_default_connection_settings, override_settings)

  @preface_magic "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  @type t :: %__MODULE__{
          state: atom,
          recv_buffer: binary,
          local_settings: map,
          local_window_limit: integer,
          local_window: integer,
          local_role: atom,
          remote_settings: map,
          remote_window_limit: integer,
          remote_window: integer,
          remote_role: atom,
          continuation: list,
          pending_settings: list,
          h2c_upgrade: atom,
          compressor: map,
          decompressor: map
        }
  defstruct state: nil,
            recv_buffer: <<>>,
            local_settings: @default_connection_settings,
            local_window_limit: @default_connection_settings[:initial_window_size],
            local_window: @default_connection_settings[:initial_window_size],
            local_role: nil,
            remote_settings: @spec_default_connection_settings,
            remote_window_limit: @spec_default_connection_settings[:initial_window_size],
            remote_window: @spec_default_connection_settings[:initial_window_size],
            remote_role: nil,
            continuation: [],
            pending_settings: [],
            h2c_upgrade: nil,
            compressor: %{},
            decompressor: %{}

  def settings(_payload) do
    # TODO
  end

  @spec recv(t, binary) :: t
  def recv(%{recv_buffer: buffer} = conn, data) do
    parse_buffer(%{conn | recv_buffer: <<buffer::binary, data::binary>>})
  end

  defp parse_buffer(%{state: :waiting_magic, recv_buffer: buffer} = conn) do
    case buffer do
      <<@preface_magic, rest::binary>> ->
        local_settings =
          Enum.reject(conn.local_settings, fn {k, v} ->
            v == @spec_default_connection_settings[k]
          end)

        settings(local_settings)
        parse_buffer(%{conn | state: :waiting_connection_preface, recv_buffer: rest})

      _ when byte_size(buffer) < 24 ->
        len = byte_size(buffer)

        case @preface_magic do
          <<^buffer::bytes-size(len), _>> ->
            {:ok, conn}

          _ ->
            {:error, :handshake}
        end

      _ ->
        {:error, :handshake}
    end
  end

  defp parse_buffer(%{recv_buffer: buffer} = conn) do
    case HTTP2.Frame.parse(buffer) do
      nil ->
        {:ok, conn}

      frame ->
        # TODO: continuation
        conn = handle_frame(conn, frame)
        {:ok, conn}
    end
  end

  # private
  @doc false
  def handle_frame(conn, %{stream_id: stream_id, type: type} = frame)
      when stream_id == 0 or type in [:settings, :ping, :goaway] do
    connection_manage(conn, frame)
  end

  defp connection_manage(%{state: :waiting_connection_preface} = conn, frame) do
    conn = %{conn | state: :connected}
    connection_settings(conn, frame)
  end

  defp connection_settings(conn, %{type: :settings, stream_id: 0, flags: flags} = frame) do
    {settings, side} =
      if Enum.member?(flags, :ack) do
        %{pending_settings: [settings | _]} = conn
        {settings, :local}
      else
        %{remote_role: remote_role} = conn
        %{payload: payload} = frame
        err = validate_settings(remote_role, payload)
        if err, do: connection_error!(err)
        {payload, :remote}
      end

    case side do
      :local ->
        local_settings(conn, settings)

      :remote ->
        conn = %{state: state, h2c_upgrade: h2c_upgrade} = remote_settings(conn, settings)

        if state != :closed && h2c_upgrade != :start do
          # TODO
          # send_frame(%{type: settings, stream_id: 0, payload: [], flags: [:ack]})
        end

        conn
    end
  end

  defp connection_settings(_conn, _) do
    connection_error!(:protocol)
  end

  defp local_settings(%{local_settings: local_settings} = conn, [{key, val} | settings]) do
    local_settings = Map.put(local_settings, key, val)
    conn = %{conn | local_settings: local_settings}
    conn = local_setting(key, val, conn)
    local_settings(conn, settings)
  end

  defp local_settings(conn, []) do
    conn
  end

  defp local_setting(
         :initial_window_size,
         v,
         %{local_window: window, local_window_limit: window_limit} = conn
       ) do
    window = window - window_limit + v
    # TODO: change streams' window
    window_limit = v
    %{conn | local_window: window, local_window_limit: window_limit}
  end

  defp local_setting(:header_table_size, v, %{compressor: compressor} = conn) do
    %{conn | compressor: Map.put(compressor, :table_size, v)}
  end

  defp remote_settings(%{remote_settings: remote_settings} = conn, [{key, val} | settings]) do
    remote_settings = Map.put(remote_settings, key, val)
    conn = %{conn | remote_settings: remote_settings}
    conn = remote_setting(key, val, conn)
    remote_settings(conn, settings)
  end

  defp remote_settings(conn, []) do
    conn
  end

  defp remote_setting(
         :initial_window_size,
         v,
         %{remote_window: window, remote_window_limit: window_limit} = conn
       ) do
    # set window_limit, calculate window using window_limit
    window = window - window_limit + v
    # TODO: change streams' window
    window_limit = v
    %{conn | remote_window: window, remote_window_limit: window_limit}
  end

  defp remote_setting(:header_table_size, v, %{decompressor: decompressor} = conn) do
    %{conn | decompressor: Map.put(decompressor, :table_size, v)}
  end

  # private
  @doc false
  def validate_settings(_, []) do
    nil
  end

  def validate_settings(:server, [{:enable_push = key, v} | _]) when v != 0 do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(:client, [{:enable_push = key, v} | _]) when v != 0 and v != 1 do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(_, [{:initial_window_size = key, v} | _]) when v > Const.max_window_size() do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(_, [{:max_frame_size = key, v} | _])
      when v < Const.init_max_frame_size() or v > Const.allowed_max_frame_size() do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(role, [{_, _} | t]) do
    validate_settings(role, t)
  end

  defp connection_error!(error) do
    # TODO
  end
end
