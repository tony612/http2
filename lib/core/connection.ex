defmodule HTTP2.Connection do
  alias HTTP2.Const
  require HTTP2.Const
  require Logger
  use HTTP2.FlowBuffer

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

  @default_weight 16

  @type t :: %__MODULE__{
          state: atom,
          latest_stream_id: integer,
          recv_buffer: binary,
          local_settings: map,
          local_window_limit: integer,
          local_window: integer,
          local_role: :server | :client,
          remote_settings: map,
          remote_window_limit: integer,
          remote_window: integer,
          remote_role: atom,
          continuation: list,
          pending_settings: list,
          h2c_upgrade: atom,
          compressor: map,
          decompressor: map,
          others: map,
          events_handler: any,
          streams: map
        }
  defstruct state: nil,
            latest_stream_id: nil,
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
            decompressor: %{},
            others: %{},
            events_handler: nil,
            streams: %{}

  def new(attrs \\ %{}) do
    conn = %__MODULE__{
      compressor: HTTP2.HPACK.new(@spec_default_connection_settings[:header_table_size]),
      decompressor: HTTP2.HPACK.new(@spec_default_connection_settings[:header_table_size])
    }

    Map.merge(conn, attrs)
  end

  def new_server() do
    conn = new()
    %{ conn | latest_stream_id: 2, state: :waiting_magic, local_role: :server, remote_role: :client}
  end

  def new_client() do
    conn = new()
    %{ conn | latest_stream_id: 1, state: :waiting_connection_preface, local_role: :client, remote_role: :server}
  end

  def settings(_payload) do
    # TODO
  end

  defp send(conn, %{type: :data}) do
    # TODO
  end

  defp send(conn, %{type: :rst_stream, others: %{error: :protocol_error}}) do
    # TODO
  end

  defp send(%{events_handler: handler}, frame) do
    frames = encode(conn, frame)
    Enum.reduce(frames, conn, fn f, conn ->
      HTTP2.ConnHandler.handle(handler, :frame, f)
      conn
    end)
  end

  @spec recv(t, binary) :: t
  def recv(%{recv_buffer: buffer} = conn, data) do
    parse_buffer(%{conn | recv_buffer: <<buffer::binary, data::binary>>})
  end

  defp parse_buffer(%{state: :waiting_magic, recv_buffer: buffer} = conn) do
    case buffer do
      <<@preface_magic, rest::binary>> ->
        Logger.debug("Got preface magic")
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

      {frame, <<>>} ->
        Logger.debug("Got frame #{inspect(frame)} and buffer is empty")
        conn = handle_frame(conn, frame)
        {:ok, conn}

      {frame, rest} ->
        Logger.debug("Got frame #{inspect(frame)}")
        # TODO: continuation
        conn = handle_frame(conn, frame)
        parse_buffer(%{conn | recv_buffer: rest})
    end
  end

  # private
  @doc false
  def handle_frame(conn, %{stream_id: stream_id, type: type} = frame)
      when stream_id == 0 or type in [:settings, :ping, :goaway] do
    connection_manage(conn, frame)
  end

  def handle_frame(%{local_role: :server}, %{type: :headers, stream_id: id}) when rem(id, 2) == 0 do
    connection_error!()
  end

  def handle_frame(%{streams: streams, local_role: role} = conn, %{type: :headers, flags: flags, stream_id: stream_id} = frame) do
    if Enum.member?(flags, :end_headers) do
      %{decompressor: table, state: state} = conn
      %{payload: payload} = frame

      case HTTP2.HPACK.decode(payload, table) do
        {:ok, headers, table} ->
          conn = %{conn | decompressor: table}
          frame = %{frame | payload: headers}

          # Some headers still should be handled after closed
          if state == :closed do
            {conn, frame}
          else
            {conn, stream} =
              case Map.fetch(streams, stream_id) do
                {:ok, s} ->
                  {conn, s}

                :error ->
                  %{others: frame_others} = frame
                  %{local_settings: %{initial_window_size: local_initial_window_size},
                    remote_settings: %{initial_window_size: remote_initial_window_size}} = conn
                  s = %HTTP2.Stream{
                    id: stream_id,
                    weight: Map.get(frame_others, :weight, @default_weight),
                    stream_dependency: Map.get(frame_others, :stream_dependency, 0),
                    exclusive: Map.get(frame_others, :exclusive, false),
                    local_window_limit: local_initial_window_size,
                    local_window: local_initial_window_size,
                    remote_window: remote_initial_window_size
                  }
                  activate_stream(conn, stream_id, s)
              end

            if role == :server do
              GenServer.call(stream, {:recv_frame, frame})
            else
              # TODO
            end
            conn
          end

        {:error, error} ->
          connection_error!(error)
      end
    else
      %{continuation: continuation} = conn
      %{conn | continuation: [frame | continuation]}
    end
  end

  def handle_frame(conn, %{type: :push_promise} = frame) do
    # TODO push_promise
  end

  def handle_frame(%{streams: streams, local_role: role} = conn, %{type: type, stream_id: sid} = frame) do
    # TODO others
    case Map.fetch(streams, sid) do
      {:ok, s} ->
        conn = if role == :server do
          GenServer.call(s, {:recv_frame, frame})
          if type == :data do
            update_local_window(conn, frame)
            calculate_window_update(conn)
          end
        else
        end

      :error ->
        case type do
          :priority ->
            # TODO
            conn
          :window_update ->
            process_window_update(conn, frame)
          _ ->
            connection_error!()
        end
    end
  end

  defp connection_manage(%{state: :waiting_connection_preface} = conn, frame) do
    conn = %{conn | state: :connected}
    connection_settings(conn, frame)
  end

  defp connection_manage(%{state: :connected} = conn, %{type: type} = frame) do
    case type do
      :window_update ->
        # TODO send_data
        %{remote_window: window} = conn
        %{payload: incr} = frame
        %{conn | remote_window: window + incr}

      :ping ->
        # TODO
        # send_frame(%{type: ping, stream_id: 0, payload: frame.payload, flags: [:ack]})
        conn

      :settings ->
        connection_settings(conn, frame)

      :goaway ->
        others = Map.put(conn.others, :closed_since, Time.utc_now())
        %{conn | state: :closed, others: others}

      :altsvc ->
        # TODO
        conn

      :blocked ->
        conn

      _ ->
        connection_error!()
    end
  end

  defp connection_manage(%{state: :closed, others: %{closed_since: closed_since}}, _frame) do
    if Time.diff(Time.utc_now(), closed_since) > 15 do
      connection_error!()
    end
  end

  defp connection_manage(_, _) do
    connection_error!()
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

  defp remote_setting(_, _, conn) do
    conn
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

  defp connection_error!(error \\ :protocol_error) do
    # TODO
    raise error
  end

  def activate_stream(%{streams: streams, local_role: role} = conn, id, s) do
    s = if role == :server do
      HTTP2.Server.Stream.new(s)
    else
    end
    # TODO: listen stream events
    {%{conn | streams: Map.put(streams, id, s)}, s}
  end
end
