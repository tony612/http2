defmodule HTTP2.Const do
  defmacro init_window_size, do: 65_535
  defmacro max_window_size, do: 0x7FFFFFFF
  defmacro init_max_frame_size, do: 16384
  defmacro allowed_max_frame_size, do: 16_777_215
  defmacro init_max_header_list_size, do: 0x7FFFFFFF
  defmacro max_stream_id, do: 0x7FFFFFFF
end
