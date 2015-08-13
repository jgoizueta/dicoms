require 'test_helper'

class ShareSettingsTest < Minitest::Test

  def setup
    @data_dir  = File.join('test', 'data')
    @test_file = File.join(@data_dir, 'test.json')
    FileUtils.rm @test_file if File.exists?(@test_file)
  end

  def teardown
    FileUtils.rm @test_file if File.exists?(@test_file)
  end

  def test_shared_is_created_with_initial_contets
    refute File.file?(@test_file) # sanity chech
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      initial_contents: {
        value: 111
      }
    )
    assert File.file?(@test_file)
    assert_equal 111, @shared.read.value
  end

  def test_shared_is_created_with_replace_contets
    refute File.file?(@test_file) # sanity chech
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      replace_contents: {
        value: 111
      }
    )
    assert File.file?(@test_file)
    assert_equal 111, @shared.read.value
  end

  def test_contents_not_replaced_by_initial
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      replace_contents: {
        value: 111
      }
    )
    assert_equal 111, @shared.read.value # sanity chech
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      initial_contents: {
        value: 222
      }
    )
    assert_equal 111, @shared.read.value
  end

  def test_contents_replaced
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      replace_contents: {
        value: 111
      }
    )
    assert_equal 111, @shared.read.value # sanity chech
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      replace_contents: {
        value: 222
      }
    )
    assert_equal 222, @shared.read.value
  end

  def test_update
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      replace_contents: {
        value_a: 111,
        value_b: 222
      }
    )
    assert_equal 111, @shared.read.value_a
    assert_equal 222, @shared.read.value_b
    assert_nil @shared.read.value_c
    @shared.update do |data|
      assert_equal 111, data.value_a
      assert_equal 222, data.value_b
      assert_nil data.value_c
      data.value_b = 333
      data.value_c = 444
      data
    end
    assert_equal 111, @shared.read.value_a
    assert_equal 333, @shared.read.value_b
    assert_equal 444, @shared.read.value_c
  end

  def test_write
    @shared = DicomPack::SharedSettings.new(
      @test_file,
      replace_contents: {
        value_a: 111,
        value_b: 222
      }
    )
    assert_equal 111, @shared.read.value_a
    assert_equal 222, @shared.read.value_b
    assert_nil @shared.read.value_c
    @shared.write value_b: 333, value_c: 444
    assert_nil @shared.read.value_a
    assert_equal 333, @shared.read.value_b
    assert_equal 444, @shared.read.value_c
  end
end
