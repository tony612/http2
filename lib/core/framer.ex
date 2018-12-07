defmodule HTTP2.Framer do
  use Bitwise, only_operators: true
  # 2^31 - 1
  defmacro max_stream_id, do: 0x7FFFFFFF
  # 2^14
  @default_max_frame_size 16384

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

  def parse(<<len::unsigned-24, type::unsigned-8, flags::unsigned-8, _::1, stream_id::unsigned-31, rest::binary>>)
      when stream_id != 0 do
    if len > @default_max_frame_size do
      {:error, {:protocol_error, "payload too large"}}
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
    case buf do
      <<payload::bytes-size(len), rest::binary>> ->
        {Map.put(frame, :payload, payload), rest}

      _ ->
        nil
    end
  end

  defp parse_payload(:headers, %{length: len, flags: flags} = frame, buf) do
    # TODO: padding
    {frame, buf} =
      if Enum.member?(flags, :priority) do
        priority_fields(frame, buf)
      else
        {frame, buf}
      end

    case buf do
      <<payload::bytes-size(len), rest::binary>> ->
        {Map.put(frame, :payload, payload), rest}

      _ ->
        nil
    end
  end

  defp priority_fields(frame, buf) do
    <<e::1, sd::unsigned-31, weight::unsigned-8, new_buf::binary>> = buf
    fields = %{exclusive: e != 0, stream_dependency: sd, weight: weight + 1}
    {Map.merge(frame, fields), new_buf}
  end
end
