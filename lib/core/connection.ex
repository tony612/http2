defmodule HTTP2.Connection do
  alias HTTP2.Const
  require HTTP2.Const

  # Default values for SETTINGS frame, as defined by the spec.
  @spec_default_connection_settings %{
    settings_header_table_size: 4096,
    # enabled for servers
    settings_enable_push: 1,
    settings_max_concurrent_streams: Const.max_stream_id(),
    settings_initial_window_size: Const.init_window_size(),
    settings_max_frame_size: Const.init_max_frame_size(),
    # 2^31 - 1
    settings_max_header_list_size: Const.init_max_header_list_size()
  }

  override_settings = %{
    settings_max_concurrent_streams: 100
  }

  @default_connection_settings Map.merge(@spec_default_connection_settings, override_settings)

  @preface_magic "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  @type t :: %__MODULE__{
          state: atom,
          recv_buffer: binary,
          local_settings: map,
          continuation: list,
          pending_settings: list,
          remote_role: atom
        }
  defstruct state: nil,
            recv_buffer: <<>>,
            local_settings: @default_connection_settings,
            continuation: [],
            pending_settings: [],
            remote_role: nil

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
    case HTTP2.Framer.parse(buffer) do
      nil ->
        {:ok, conn}

      frame ->
        # TODO: continuation
        {conn, frame} = handle_frame(conn, frame)
        {:ok, conn}
    end
  end

  defp handle_frame(conn, %{stream_id: stream_id, type: type} = frame)
       when stream_id == 0 or type in [:settings, :ping, :goaway] do
    connection_manage(conn, frame)
  end

  defp connection_manage(%{state: :waiting_connection_preface} = conn, frame) do
    conn = %{conn | state: :connected}
    connection_setting(conn, frame)
  end

  defp connection_setting(conn, %{type: :settings, stream_id: 0, flags: flags} = frame) do
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
  end

  # private
  @doc false
  def validate_settings(_, []) do
    nil
  end

  def validate_settings(:server, [{:settings_enable_push = key, v} | t]) when v != 0 do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(:client, [{:settings_enable_push = key, v} | t]) when v != 0 and v != 1 do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(_, [{:settings_initial_window_size = key, v} | t]) when v > Const.max_window_size() do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(_, [{:settings_max_frame_size = key, v} | t])
      when v < Const.init_max_frame_size() or v > Const.allowed_max_frame_size() do
    HTTP2.ProtocolError.exception(message: "invalid value for #{key}")
  end

  def validate_settings(role, [{_, _} | t]) do
    validate_settings(role, t)
  end

  defp connection_error!(error) do
  end
end
