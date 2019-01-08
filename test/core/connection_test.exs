defmodule HTTP2.ConnectionTest do
  use ExUnit.Case, async: true

  alias HTTP2.{Connection, Const, Frame}
  import HTTP2.Connection
  require HTTP2.Const

  test "recv/2 gets right preface when waiting_magic" do
    conn = %Connection{state: :waiting_magic}

    assert {:ok, %Connection{state: :waiting_connection_preface, recv_buffer: ""}} =
             recv(conn, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
  end

  test "recv/2 buffer is part of preface magic when waiting_magic" do
    conn = %Connection{state: :waiting_magic}
    # 23 bytes
    data = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r"

    assert {:ok, %Connection{state: :waiting_magic, recv_buffer: ^data}} = recv(conn, data)
  end

  test "recv/2 buffer is not part of preface magic when waiting_magic and buffer < 24 bytes" do
    conn = %Connection{state: :waiting_magic}
    # 23 bytes
    data = "pri * http/2.0\r\n\r\nsm\r\n\r"

    assert {:error, :handshake} = recv(conn, data)
  end

  test "recv/2 buffer is wrong when waiting_magic and buffer >= 24 bytes" do
    conn = %Connection{state: :waiting_magic}
    data = "pri * http/2.0\r\n\r\nsm\r\n\r\n"

    assert {:error, :handshake} = recv(conn, data)
  end

  test "validate_settings/2 works for enable_push" do
    refute validate_settings(:server, enable_push: 0)
    assert %HTTP2.ProtocolError{message: _} = validate_settings(:server, enable_push: 1)
    assert %HTTP2.ProtocolError{message: _} = validate_settings(:server, enable_push: 100)
    refute validate_settings(:client, enable_push: 0)
    refute validate_settings(:client, enable_push: 1)
    assert %HTTP2.ProtocolError{message: _} = validate_settings(:client, enable_push: 100)
  end

  test "validate_settings/2 works for initial_window_size" do
    refute validate_settings(:client, initial_window_size: Const.max_window_size())
    refute validate_settings(:server, initial_window_size: Const.max_window_size())

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:client, initial_window_size: Const.max_window_size() + 1)

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:server, initial_window_size: Const.max_window_size() + 1)
  end

  test "validate_settings/2 works for max_frame_size" do
    refute validate_settings(:client, max_frame_size: Const.init_max_frame_size())
    refute validate_settings(:client, max_frame_size: Const.init_max_frame_size() + 1)
    refute validate_settings(:client, max_frame_size: Const.allowed_max_frame_size())
    refute validate_settings(:client, max_frame_size: Const.allowed_max_frame_size() - 1)

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:client, max_frame_size: Const.init_max_frame_size() - 1)

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:server, max_frame_size: Const.allowed_max_frame_size() + 1)
  end

  test "handle_frame/2 connection set state when waiting_connection_preface" do
    conn = %Connection{state: :waiting_connection_preface, remote_role: :client}
    frame = %Frame{stream_id: 0, type: :settings, payload: []}
    assert %{state: :connected} = handle_frame(conn, frame)
  end

  test "handle_frame/2 connection set remote settings when waiting_connection_preface" do
    conn = %Connection{
      state: :waiting_connection_preface,
      remote_role: :client,
      remote_window: 80000,
      remote_window_limit: 70000
    }

    frame = %Frame{stream_id: 0, type: :settings, payload: [initial_window_size: 75000]}

    assert %{remote_settings: %{initial_window_size: 75000}, remote_window: 85000, remote_window_limit: 75000} =
             handle_frame(conn, frame)

    conn = %Connection{
      state: :waiting_connection_preface,
      remote_role: :client
    }

    frame = %Frame{stream_id: 0, type: :settings, payload: [header_table_size: 1234]}
    assert %{remote_settings: %{header_table_size: 1234}, decompressor: %{table_size: 1234}} = handle_frame(conn, frame)

    conn = %Connection{
      state: :waiting_connection_preface,
      remote_role: :client,
      remote_window: 80000,
      remote_window_limit: 70000
    }

    frame = %Frame{stream_id: 0, type: :settings, payload: [initial_window_size: 75000, header_table_size: 1234]}

    assert %{
             remote_settings: %{initial_window_size: 75000, header_table_size: 1234},
             remote_window: 85000,
             remote_window_limit: 75000,
             remote_window: 85000,
             remote_window_limit: 75000,
             decompressor: %{table_size: 1234}
           } = handle_frame(conn, frame)
  end

  test "handle_frame/2 connection set local settings when waiting_connection_preface" do
    conn = %Connection{
      state: :waiting_connection_preface,
      local_window: 80000,
      local_window_limit: 70000,
      pending_settings: [[initial_window_size: 75000]]
    }

    frame = %Frame{stream_id: 0, type: :settings, flags: [:ack]}

    assert %{local_settings: %{initial_window_size: 75000}, local_window: 85000, local_window_limit: 75000} =
             handle_frame(conn, frame)

    conn = %Connection{
      state: :waiting_connection_preface,
      pending_settings: [[header_table_size: 1234]]
    }

    frame = %Frame{stream_id: 0, type: :settings, flags: [:ack]}
    assert %{local_settings: %{header_table_size: 1234}, compressor: %{table_size: 1234}} = handle_frame(conn, frame)

    conn = %Connection{
      state: :waiting_connection_preface,
      local_window: 80000,
      local_window_limit: 70000,
      pending_settings: [[initial_window_size: 75000, header_table_size: 1234]]
    }

    frame = %Frame{stream_id: 0, type: :settings, flags: [:ack]}

    assert %{
             local_settings: %{initial_window_size: 75000, header_table_size: 1234},
             local_window: 85000,
             local_window_limit: 75000,
             local_window: 85000,
             local_window_limit: 75000,
             compressor: %{table_size: 1234}
           } = handle_frame(conn, frame)
  end
end
