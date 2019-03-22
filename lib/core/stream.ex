defmodule HTTP2.Stream do
  defstruct id: nil,
            weight: 16,
            stream_dependency: 0,
            local_window_limit: nil,
            local_window: nil,
            remote_window: nil,
            state: :idle,
            exclusive: false,
            closed: nil

  import Logger

  defmacro __using__(args) do
    quote do
      def new(stream) do
        # TODO: process_priority
        stream
      end
      defoverridable new: 1

      import HTTP2.Stream
    end
  end


  def transition(state, op, stream, frame)
  def transition(:idle, :sending, stream, %{type: type} = frame) do
    s = case type do
      :push_promise ->
        event(stream, :reserved_local)
      :headers ->
        if end_stream?(type, frame) do
          event(stream, :half_closed_local)
        else
          event(stream, :open)
        end
      :rst_stream ->
        event(stream, :local_rst)
      :priority ->
        process_priority(stream, frame)
      _ ->
        stream_error()
    end
    {s, frame}
  end
  def transition(:idle, _, stream, %{type: type} = frame) do
    s = case type do
      :push_promise ->
        event(stream, :reserved_remote)
      :headers ->
        if end_stream?(type, frame) do
          event(stream, :half_closed_remote)
        else
          event(stream, :open)
        end
      :priority ->
        process_priority(stream, frame)
      _ ->
        stream_error(:protocol_error)
    end
    {s, frame}
  end
  def transition(:reserved_local, :sending, stream, %{type: type} = frame) do
    s = case type do
      :headers ->
        event(stream, :half_closed_remote)
      :rst_stream ->
        event(stream, :local_rst)
      _ ->
        stream_error(:protocol_error)
    end
    {s, frame}
  end
  def transition(:reserved_local, _, stream, %{type: type} = frame) do
    s = case type do
      :rst_stream ->
        event(stream, :remote_rst)
      type when type in [:priority, :window_update] ->
        stream
      _ ->
        stream_error()
    end
    {s, frame}
  end
  def transition(:reserved_remote, :sending, stream, %{type: type} = frame) do
    s = case type do
      :rst_stream ->
        event(stream, :local_rst)
      type when type in [:priority, :window_update] ->
        stream
      _ ->
        stream_error()
    end
    {s, frame}
  end
  def transition(:reserved_remote, _, stream, %{type: type} = frame) do
    s = case type do
      :headers ->
        event(stream, :half_closed_local)
      :rst_stream ->
        event(stream, :remote_rst)
      _ ->
        stream_error()
    end
    {s, frame}
  end
  def transition(:open, :sending, stream, %{type: type} = frame) do
    s = case type do
      type when type in [:data, :headers, :continuation] ->
        if end_stream?(type, frame) do
          event(stream, :half_closed_local)
        else
          stream
        end
      :rst_stream ->
        event(stream, :local_rst)
      _ ->
        stream
    end
    {s, frame}
  end
  def transition(:open, _, stream, %{type: type} = frame) do
    s = case type do
      type when type in [:data, :headers, :continuation] ->
        if end_stream?(type, frame) do
          event(stream, :half_closed_remote)
        else
          stream
        end
      :rst_stream ->
        event(stream, :remote_rst)
      _ ->
        stream
    end
    {s, frame}
  end
  def transition(:half_closed_local, :sending, stream, %{type: type} = frame) do
    s = case type do
      :rst_stream ->
        event(stream, :local_rst)
      :priority ->
        process_priority(stream, frame)
      :window_update ->
        stream
      _ ->
        stream_error()
    end
    {s, frame}
  end
  def transition(:half_closed_local, _, stream, %{type: type} = frame) do
    s = case type do
      type when type in [:data, :headers, :continuation] ->
        if end_stream?(type, frame) do
          event(stream, :remote_closed)
        else
          stream
        end
      :rst_stream ->
        event(stream, :remote_rst)
      :priority ->
        process_priority(stream, frame)
      _ ->
        stream
    end
    {s, frame}
  end
  def transition(:half_closed_remote, :sending, stream, %{type: type} = frame) do
    s = case type do
      type when type in [:data, :headers, :continuation] ->
        if end_stream?(type, frame) do
          event(stream, :local_closed)
        else
          stream
        end
      :rst_stream ->
        event(stream, :local_rst)
      _ ->
        stream
    end
    {s, frame}
  end
  def transition(:half_closed_remote, _, stream, %{type: type} = frame) do
    s = case type do
      :rst_stream ->
        event(stream, :remote_rst)
      :priority ->
        process_priority(stream, frame)
      :window_update ->
        stream
      _ ->
        stream_error(:stream_closed)
    end
    {s, frame}
  end
  def transition(:closed, :sending, stream, %{type: type} = frame) do
    s = case type do
      :rst_stream ->
        stream
      :priority ->
        process_priority(stream, frame)
      _ ->
        stream_error(:stream_closed)
    end
    {s, frame}
  end
  def transition(:closed, _, stream, %{type: type} = frame) do
    if type == :priority do
      {process_priority(stream, frame), frame}
    else
      case Map.get(stream, :closed) do
        s when s in [:remote_rst, :remote_closed] ->
          if type == :rst_stream || type == :window_update do
            {stream, frame}
          else
            stream_error(:stream_closed)
          end
        s when s in [:local_rst, :local_closed] ->
          if type != :window_update do
            {stream, put_in(frame, [Access.key(:others), Access.key(:ignore)], true)}
          else
            {stream, frame}
          end
        _ ->
          {stream, frame}
      end
    end
  end

  def event(stream, new_state) do
    case new_state do
      s when s in [:open, :reserved_local, :reserved_remote] ->
        Map.put(stream, :state, s)
      s when s in [:half_closed_local, :half_closed_remote] ->
        stream
        |> Map.put(:state, :half_closing)
        |> Map.put(:closed, s)
      s when s in [:local_closed, :remote_closed, :local_rst, :remote_rst] ->
        stream
        |> Map.put(:state, :closing)
        |> Map.put(:closed, s)
      _ ->
        stream
    end
  end

  def end_stream?(type, %{flags: flags} = frame) when type in [:data, :headers, :continuation] do
    Enum.member?(flags, :end_stream)
  end
  def end_stream?(_type, _frame), do: false

  def process_priority(stream, %{weight: weight, others: others} = frame) do
    stream
    |> Map.put(:weight, weight)
    |> Map.put(:stream_dependency, Map.get(others, :stream_dependency))
  end

  def complete_transition(%{state: state} = stream) do
    case state do
      :closing ->
        Map.put(stream, :state, :closed)
      :half_closing ->
        %{closed: closed} = stream
        Map.put(stream, :state, closed)
      _ ->
        stream
    end
  end

  def stream_error(error \\ :internal_error) do
    # TODO
  end
end
