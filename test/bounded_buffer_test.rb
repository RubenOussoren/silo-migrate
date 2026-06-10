# frozen_string_literal: true

require_relative "test_helper"

class BoundedBufferTest < SiloMigrateTest
  def test_keeps_everything_under_the_limit
    buffer = SiloMigrate::BoundedBuffer.new(max_bytes: 100)
    buffer.write("hello ")
    buffer.write("world")
    assert_equal "hello world", buffer.tail_string
    assert_equal 11, buffer.byte_count
    refute buffer.truncated?
  end

  def test_drops_oldest_chunks_beyond_the_limit
    buffer = SiloMigrate::BoundedBuffer.new(max_bytes: 10)
    buffer.write("aaaaa")
    buffer.write("bbbbb")
    buffer.write("ccccc")
    assert buffer.truncated?
    assert_equal 15, buffer.byte_count
    assert_equal "bbbbbccccc", buffer.tail_string
  end

  def test_trims_a_single_oversized_chunk
    buffer = SiloMigrate::BoundedBuffer.new(max_bytes: 4)
    buffer.write("abcdefgh")
    assert buffer.truncated?
    assert_equal "efgh", buffer.tail_string
  end
end
