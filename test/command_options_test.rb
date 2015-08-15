require 'test_helper'

class ShareFileTest < Minitest::Test

  def setup
    @data_dir  = File.join('test', 'data')
    @settings_file = File.join(@data_dir, 'dicom.json')
    FileUtils.rm @settings_file if File.exists?(@settings_file)
  end

  def teardown
    FileUtils.rm @settings_file if File.exists?(@settings_file)
  end

  def test_options_without_settings_file
    options = DicomS::CommandOptions.new(
      a: 11,
      b: 22,
      c: 33,
      path: 'abc',
      path2: 'xyz/uvw'
    )
    assert_equal 11, options[:a]
    assert_equal 22, options[:b]
    assert_equal 33, options[:c]
    assert_equal 'abc', options[:path]
    assert_equal 11, options.a
    assert_equal 22, options.b
    assert_equal 33, options.c
    assert_equal 'abc', options.path
    assert_equal 'abc', options.path_option(:path)
    assert_equal 'xyz/uvw', options.path2
    assert_equal 'xyz/uvw', options.path_option(:path2)
  end

  def test_options_with_settings_file
    settings = DicomS::SharedSettings.new(@settings_file)
    settings.write(
      a: 11,
      b: 22,
      c: 33,
      path: 'abc',
      path2: 'xyz/uvw'
    )
    options = DicomS::CommandOptions.new(
      settings: @settings_file
    )
    assert_equal 11, options[:a]
    assert_equal 22, options[:b]
    assert_equal 33, options[:c]
    assert_equal 'abc', options[:path]
    assert_equal 11, options.a
    assert_equal 22, options.b
    assert_equal 33, options.c
    assert_equal 'abc', options.path
    assert_equal 'abc', File.basename(options.path_option(:path))
    assert_equal File.expand_path(File.dirname(@settings_file)),
                 File.dirname(options.path_option(:path))
    assert_equal 'xyz/uvw', options.path2
    assert_equal 'uvw', File.basename(options.path_option(:path2))
    assert_equal File.expand_path(File.join(File.dirname(@settings_file), 'xyz')),
                 File.dirname(options.path_option(:path2))
  end

end
