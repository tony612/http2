defmodule HTTP2.Connection do
  alias HTTP2.Framer
  require HTTP2.Framer

  # Default values for SETTINGS frame, as defined by the spec.
  @spec_default_connection_settings %{
    settings_header_table_size: 4096,
    # enabled for servers
    settings_enable_push: 1,
    settings_max_concurrent_streams: Framer.max_stream_id(),
    settings_initial_window_size: 65_535,
    settings_max_frame_size: 16_384,
    # 2^31 - 1
    settings_max_header_list_size: 0x7FFFFFFF
  }

  override_settings = %{
    settings_max_concurrent_streams: 100
  }

  @default_connection_settings Map.merge(@spec_default_connection_settings, override_settings)

  @preface_magic "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  @type t :: %__MODULE__{
          state: atom,
          recv_buffer: binary,
          local_settings: map
        }
  defstruct state: nil, recv_buffer: <<>>, local_settings: @default_connection_settings

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

  defp parse_buffer(conn) do
    {:ok, conn}
  end
end
