defmodule HTTP2.FlowBuffer do
  # local_window
  # local_window_limit

  defmacro __using__(opts) do
    quote do
      def update_local_window(%{local_window: local_window} = self, %{payload: payload, padding: padding} = frame) do
        frame_size = byte_size(payload)
        frame_size = if padding do
          frame_size + padding
        else
          frame_size
        end
        Map.put(self, :local_window, local_window - frame_size)
      end

      def calculate_window_update(%{local_window_limit: local_window_limit, local_window: local_window} = self) do
        if local_window < 0 do
          raise :flow_control_error
        end

        if local_window <= (local_window_limit / 2) do
          self
        else
          # TODO: send window_update
        end
      end

      def send_data(self) do
        # TODO:
      end

      def process_window_update(%{remote_window: remote_window} = self, %{others: others} = frame) do
        ignore = Map.get(others, :ignore)
        if ignore do
          self
        else
          increment = Map.get(others, :increment)
          self = Map.put(self, remote_window, remote_window + increment)
          send_data(self)
        end
      end
    end
  end
end
