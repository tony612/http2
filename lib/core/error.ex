defmodule HTTP2.ProtocolError do
  defexception [:message]
end

defmodule HTTP2.FrameSizeError do
  defexception [:message]
end

defmodule HTTP2.CompressionError do
  defexception [:message]
end
