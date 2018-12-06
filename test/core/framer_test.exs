defmodule HTTP2.FramerTest do
  use ExUnit.Case, async: true

  # alias HTTP2.Framer
  import HTTP2.Framer

  test "parse/1 returns nil" do
    refute parse(<<>>)
    refute parse(<<1, 2, 3, 4, 5, 6, 7, 8>>)
  end

  test "parse/1 DATA frame works" do
    buffer = <<1::24, 0, 1, 1::32, 1, 2>>
    assert {%{length: 1, type: :data, flags: [:end_stream], stream_id: 1}, <<2>>} = parse(buffer)
  end

  test "parse/1 DATA frame nil" do
    buffer = <<2::24, 0, 1, 1::32, 1>>
    assert nil == parse(buffer)
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
end
