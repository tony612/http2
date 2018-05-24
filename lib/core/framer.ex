defmodule HTTP2.Framer do
  # 2^31 - 1
  defmacro max_stream_id, do: 0x7FFFFFFF
end
