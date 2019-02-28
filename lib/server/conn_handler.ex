defmodule HTTP2.Server.ConnHandler do
  defstruct [send_fn: nil]

  defimpl HTTP2.ConnHandler do
    def handle(%{send_fn: send_fn}, :frame, bytes) do
      send_fn.(bytes)
    end
  end
end
