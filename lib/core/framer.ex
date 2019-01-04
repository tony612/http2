defmodule HTTP2.Framer do
  use Bitwise, only_operators: true
  alias HTTP2.Const
  require HTTP2.Const

  @frame_types %{
    data: 0,
    headers: 1,
    priority: 2,
    rst_stream: 3,
    settings: 4,
    push_promise: 5,
    ping: 6,
    goaway: 7,
    window_update: 8,
    continuation: 9,
    altsvc: 10
  }
  @frame_type_names Enum.map(@frame_types, fn {k, v} -> {v, k} end) |> Enum.into(%{})

  @frame_flags %{
    data: [
      end_stream: 0,
      padded: 3,
      compressed: 5
    ],
    headers: [
      end_stream: 0,
      end_headers: 2,
      padded: 3,
      priority: 5
    ],
    priority: [],
    rst_stream: [],
    settings: [ack: 0],
    push_promise: [
      end_headers: 2,
      padded: 3
    ],
    ping: [ack: 0],
    goaway: [],
    window_update: [],
    continuation: [end_headers: 2],
    altsvc: []
  }

  @defined_errors %{
    no_error: 0,
    protocol_error: 1,
    internal_error: 2,
    flow_control_error: 3,
    settings_timeout: 4,
    stream_closed: 5,
    frame_size_error: 6,
    refused_stream: 7,
    cancel: 8,
    compression_error: 9,
    connect_error: 10,
    enhance_your_calm: 11,
    inadequate_security: 12,
    http_1_1_required: 13
  }

  @defined_settings %{
    settings_header_table_size: 1,
    settings_enable_push: 2,
    settings_max_concurrent_streams: 3,
    settings_initial_window_size: 4,
    settings_max_frame_size: 5,
    settings_max_header_list_size: 6
  }

  def parse(<<len::unsigned-24, type::unsigned-8, flags::unsigned-8, _::1, stream_id::unsigned-31, rest::binary>>)
      when byte_size(rest) >= len do
    if len > Const.init_max_frame_size() do
      raise HTTP2.ProtocolError, message: "Frame length is too large"
    else
      type = @frame_type_names[type]
      flags = type_flags(type, flags)
      frame = %{length: len, type: type, flags: flags, stream_id: stream_id}

      parse_payload(type, frame, rest)
    end
  end

  def parse(_) do
    nil
  end

  @doc false
  def type_flags(type, flags) do
    (@frame_flags[type] || %{})
    |> Enum.reduce([], fn {name, pos}, acc ->
      if (flags &&& 1 <<< pos) > 0 do
        [name | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_payload(:data, %{length: len} = frame, buf) do
    # TODO: padding
    <<payload::bytes-size(len), rest::binary>> = buf
    {Map.put(frame, :payload, payload), rest}
  end

  defp parse_payload(:headers, %{length: len, flags: flags} = frame, buf) do
    # TODO: padding
    {frame, buf} =
      if Enum.member?(flags, :priority) do
        priority_fields(frame, buf)
      else
        {frame, buf}
      end

    <<payload::bytes-size(len), rest::binary>> = buf
    {Map.put(frame, :payload, payload), rest}
  end

  defp parse_payload(:priority, frame, buf) do
    priority_fields(frame, buf)
  end

  defp parse_payload(:rst_stream, frame, <<err::unsigned-32, new_buf::binary>>) do
    error = unpack_error(err)
    {Map.put(frame, :error, error), new_buf}
  end

  defp parse_payload(:settings, frame = %{length: len, stream_id: stream_id}, buf) do
    if rem(len, 6) != 0 do
      raise HTTP2.FrameSizeError, message: "SETTINGS frame length should be multiple of 6"
    end

    if stream_id != 0 do
      raise HTTP2.ProtocolError, message: "Invalid stream ID (#{stream_id}) for SETTINGS frame"
    end

    {new_buf, payload} = parse_settings(div(len, 6), buf, [])
    {Map.put(frame, :payload, payload), new_buf}
  end

  defp parse_payload(:push_promise, frame = %{length: len}, <<_::1, stream::unsigned-31, buf::binary>>) do
    # TODO: padding
    case buf do
      <<payload::bytes-size(len), rest::binary>> ->
        frame =
          frame
          |> Map.put(:promise_stream, stream)
          |> Map.put(:payload, payload)

        {frame, rest}

      _ ->
        nil
    end
  end

  defp parse_payload(:ping, frame = %{length: len}, buf) do
    <<payload::bytes-size(len), rest::binary>> = buf
    {Map.put(frame, :payload, payload), rest}
  end

  defp parse_payload(:goaway, frame = %{length: len}, <<_::1, stream::unsigned-31, err::unsigned-32, buf::binary>>) do
    error = unpack_error(err)
    len = len - 8
    <<payload::bytes-size(len), rest::binary>> = buf

    frame =
      frame
      |> Map.put(:last_stream, stream)
      |> Map.put(:error, error)
      |> Map.put(:payload, payload)

    {frame, rest}
  end

  defp parse_payload(:window_update, frame, <<_::1, incr::unsigned-31, rest::binary>>) do
    {Map.put(frame, :increment, incr), rest}
  end

  defp parse_payload(:continuation, frame = %{length: len}, buf) do
    <<payload::bytes-size(len), rest::binary>> = buf
    {Map.put(frame, :payload, payload), rest}
  end

  defp parse_payload(:altsvc, frame = %{length: len}, buf) do
    # TODO
    nil
  end

  defp priority_fields(frame, buf) do
    <<e::1, sd::unsigned-31, weight::unsigned-8, new_buf::binary>> = buf
    fields = %{exclusive: e != 0, stream_dependency: sd, weight: weight + 1}
    {Map.merge(frame, fields), new_buf}
  end

  defp parse_settings(0, buf, settings), do: {buf, Enum.reverse(settings)}

  defp parse_settings(len, <<id::unsigned-16, val::unsigned-32, buf::binary>>, settings) do
    case Enum.find(@defined_settings, fn {name, v} -> v == id end) do
      {name, _} -> parse_settings(len - 1, buf, [{name, val} | settings])
      _ -> parse_settings(len - 1, buf, settings)
    end
  end

  defp unpack_error(err_num) do
    {err, _} = Enum.find(@defined_errors, {err_num, err_num}, fn {k, v} -> v == err_num end)
    err
  end
end
