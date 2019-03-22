defmodule HTTP2.Server.Stream do
  use HTTP2.Stream
  use HTTP2.FlowBuffer

  use GenServer
  import Logger

  def new(args) do
    # TODO: process_priority
    s = args
    {:ok, pid} = GenServer.start_link(HTTP2.Server.Stream, s)
    pid
  end

  @impl true
  def init(s) do
    Logger.debug("Start new stream #{inspect(s)} in process #{inspect(self())}")
    {:ok, {s, :queue.new()}}
  end

  def handle_call({:recv_frame, frame}, from, {s, queue}) do
    Logger.debug("Stream##{s.id} recv frame #{inspect(frame)}")
    queue = :queue.in(frame, queue)
    {:reply, :ok, {s, queue}, {:continue, :recv_frame}}
  end

  def handle_continue(:recv_frame, {s, queue}) do
    case :queue.out(queue) do
      {{:value, frame}, queue} ->
        s = recv(s, frame)
        state = {s, queue}
        if :queue.is_empty(queue) do
          {:noreply, state, :hibernate}
        else
          {:noreply, state, {:continue, :recv_frame}}
        end
      {:empty, queue} ->
        {:noreply, {s, queue}, :hibernate}
    end
  end

  def recv(%{state: state} = stream0, %{type: type, others: others} = frame) do
    {stream, frame} = transition(state, :receiving, stream0, frame)
    Logger.debug("Stream##{stream0.id} state changes #{inspect(stream0.state)} => #{inspect(stream.state)}, closed: #{inspect(stream.closed)}")
    ignore = Map.get(others, :ignore)

    stream = case type do
      :data ->
        update_local_window(stream, frame)
        unless ignore do
          # TODO
        end
        calculate_window_update(stream)
      :headers ->
        unless ignore do
          # TODO
        end
        stream
      :push_promise ->
        unless ignore do
          # TODO
        end
        stream
      :priority ->
        process_priority(stream, frame)
      :window_update ->
        process_window_update(stream, frame)
      # :altsvc ->
      # :blocked ->
      _ ->
        stream
    end

    complete_transition(stream)
  end
end
