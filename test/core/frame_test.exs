defmodule HTTP2.FrameTest do
  use ExUnit.Case, async: true

  # alias HTTP2.Frame
  import HTTP2.Frame

  test "parse/1 returns nil" do
    refute parse(<<>>)
    refute parse(<<1, 2, 3, 4, 5, 6, 7, 8>>)
  end

  test "parse/1 DATA frame works" do
    buffer = <<1::24, 0, 1, 1::32, 1, 2>>
    assert {%{length: 1, type: :data, flags: [:end_stream], stream_id: 1, payload: <<1>>}, <<2>>} = parse(buffer)
  end

  test "parse/1 DATA frame nil" do
    buffer = <<2::24, 0, 1, 1::32, 1>>
    assert nil == parse(buffer)
  end

  test "parse/1 DATA raise error for too large length" do
    buffer = <<16385::24, 0, 1, 1::32, 1::size(16385)-unit(8)>>

    assert_raise HTTP2.ProtocolError, ~r/too large/, fn ->
      parse(buffer)
    end
  end

  test "type_flags/2 works" do
    assert [:end_stream] == type_flags(:data, 1)
    assert [:padded] == type_flags(:data, 8)
    assert [:compressed] == type_flags(:data, 32)
    assert [:end_stream, :padded] == type_flags(:data, 9)
    assert [:padded, :compressed] == type_flags(:data, 40)
    assert [:end_stream, :compressed] == type_flags(:data, 33)
    assert [:end_stream, :padded, :compressed] == type_flags(:data, 41)
    assert [:end_stream, :end_headers] == type_flags(:headers, 5)
  end

  test "parse/1 HEADERS frame works" do
    buffer = <<1::24, 1, 1, 1::32, 1, 2>>
    assert {%{length: 1, type: :headers, flags: [:end_stream], stream_id: 1, payload: <<1>>}, <<2>>} = parse(buffer)
  end

  test "parse/1 HEADERS frame works for priority" do
    buffer = <<1::24, 1, 32, 1::32, 1::1, 2::31, 3, 4>>

    assert {%{
              length: 1,
              type: :headers,
              flags: [:priority],
              stream_id: 1,
              others: %{
                exclusive: true,
                stream_dependency: 2,
                weight: 4
              },
              payload: <<4>>
            }, <<>>} = parse(buffer)
  end

  test "parse/1 PRIORITY frame works" do
    buffer = <<1::24, 2, 32, 1::32, 1::1, 2::31, 2>>

    assert {%{
              length: 1,
              type: :priority,
              flags: [],
              stream_id: 1,
              others: %{exclusive: true, stream_dependency: 2, weight: 3}
            }, <<>>} = parse(buffer)
  end

  test "parse/1 PRIORITY frame non-exclusive" do
    buffer = <<1::24, 2, 32, 1::32, 0::1, 123::31, 10>>

    assert {%{
              length: 1,
              type: :priority,
              flags: [],
              stream_id: 1,
              others: %{
                exclusive: false,
                stream_dependency: 123,
                weight: 11
              }
            }, <<>>} = parse(buffer)
  end

  test "parse/1 RST_STREAM frame works" do
    buffer = <<1::24, 3, 1, 1::32, 1::32>>
    assert {%{length: 1, type: :rst_stream, stream_id: 1, others: %{error: :protocol_error}}, <<>>} = parse(buffer)
    buffer = <<1::24, 3, 1, 1::32, 12::32>>
    assert {%{length: 1, type: :rst_stream, stream_id: 1, others: %{error: :inadequate_security}}, <<>>} = parse(buffer)
  end

  test "parse/1 SETTINGS frame raise error for invalid length" do
    buffer = <<1::24, 4, 1, 1::32, 1>>

    assert_raise HTTP2.FrameSizeError, ~r/multiple of 6/, fn ->
      parse(buffer)
    end
  end

  test "parse/1 SETTINGS frame raise error for non-zero stream id" do
    buffer = <<6::24, 4, 1, 1::32, 1::48>>

    assert_raise HTTP2.ProtocolError, ~r/Invalid stream ID/, fn ->
      parse(buffer)
    end
  end

  test "parse/1 SETTINGS frame works" do
    buffer = <<6::24, 4, 1, 0::32, 1::16, 123::32>>

    assert {%{length: 6, type: :settings, stream_id: 0, payload: [{:settings_header_table_size, 123}]}, <<>>} =
             parse(buffer)

    buffer = <<12::24, 4, 1, 0::32, 1::16, 123::32, 6::16, 321::32>>

    assert {%{
              length: 12,
              type: :settings,
              stream_id: 0,
              payload: [settings_header_table_size: 123, settings_max_header_list_size: 321]
            }, <<>>} = parse(buffer)
  end

  test "parse/1 SETTINGS frame skip unknown settings" do
    buffer = <<12::24, 4, 1, 0::32, 7::16, 123::32, 6::16, 321::32>>

    assert {%{length: 12, type: :settings, stream_id: 0, payload: [settings_max_header_list_size: 321]}, <<>>} =
             parse(buffer)
  end

  test "parse/1 PUSH_PROMISE frame works" do
    buffer = <<1::24, 5, 1, 1::32, 1::1, 10::31, 123>>

    assert {%{length: 1, type: :push_promise, stream_id: 1, payload: <<123>>, others: %{promise_stream_id: 10}}, <<>>} =
             parse(buffer)
  end

  test "parse/1 PUSH_PROMISE frame no enought payload" do
    buffer = <<1::24, 5, 1, 1::32, 1::1, 10::31>>
    assert nil == parse(buffer)
  end

  test "parse/1 PING frame works" do
    buffer = <<1::24, 6, 1, 1::32, 123>>
    assert {%{length: 1, type: :ping, stream_id: 1, payload: <<123>>}, <<>>} = parse(buffer)
  end

  test "parse/1 GOAWAY frame works" do
    buffer = <<9::24, 7, 1, 1::32, 0::1, 321::31, 1::32, 123>>

    assert {%{
              length: 9,
              type: :goaway,
              stream_id: 1,
              others: %{last_stream_id: 321, error: :protocol_error},
              payload: <<123>>
            }, <<>>} = parse(buffer)
  end

  test "parse/1 WINDOW_UPDATE frame works" do
    buffer = <<4::24, 8, 1, 1::32, 0::1, 123::31>>
    assert {%{length: 4, type: :window_update, stream_id: 1, others: %{increment: 123}}, <<>>} = parse(buffer)
  end

  test "parse/1 CONTINUATION frame works" do
    buffer = <<1::24, 9, 1, 1::32, 123>>
    assert {%{length: 1, type: :continuation, stream_id: 1, payload: <<123>>}, <<>>} = parse(buffer)
  end
end
