defmodule HTTP2.ConnectionTest do
  use ExUnit.Case, async: true

  alias HTTP2.Connection
  import HTTP2.Connection
  alias HTTP2.Const
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

  test "validate_settings/2 works for settings_enable_push" do
    refute validate_settings(:server, settings_enable_push: 0)
    assert %HTTP2.ProtocolError{message: _} = validate_settings(:server, settings_enable_push: 1)
    assert %HTTP2.ProtocolError{message: _} = validate_settings(:server, settings_enable_push: 100)
    refute validate_settings(:client, settings_enable_push: 0)
    refute validate_settings(:client, settings_enable_push: 1)
    assert %HTTP2.ProtocolError{message: _} = validate_settings(:client, settings_enable_push: 100)
  end

  test "validate_settings/2 works for settings_initial_window_size" do
    refute validate_settings(:client, settings_initial_window_size: Const.max_window_size())
    refute validate_settings(:server, settings_initial_window_size: Const.max_window_size())

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:client, settings_initial_window_size: Const.max_window_size() + 1)

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:server, settings_initial_window_size: Const.max_window_size() + 1)
  end

  test "validate_settings/2 works for settings_max_frame_size" do
    refute validate_settings(:client, settings_max_frame_size: Const.init_max_frame_size())
    refute validate_settings(:client, settings_max_frame_size: Const.init_max_frame_size() + 1)
    refute validate_settings(:client, settings_max_frame_size: Const.allowed_max_frame_size())
    refute validate_settings(:client, settings_max_frame_size: Const.allowed_max_frame_size() - 1)

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:client, settings_max_frame_size: Const.init_max_frame_size() - 1)

    assert %HTTP2.ProtocolError{message: _} =
             validate_settings(:server, settings_max_frame_size: Const.allowed_max_frame_size() + 1)
  end
end
