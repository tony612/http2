defmodule HTTP2.ConnectionTest do
  use ExUnit.Case, async: true

  alias HTTP2.Connection
  import HTTP2.Connection

  test "recv/2 gets right preface when waiting_magic" do
    conn = %Connection{state: :waiting_magic}

    assert %Connection{state: :waiting_connection_preface, recv_buffer: ""} =
             recv(conn, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
  end
end
