require 'test_helper'

class ProgressTest < Minitest::Test
  def setup
    @data_dir  = File.join('test', 'data')
    @progress_file_name = File.join(@data_dir, 'progress.json')
    FileUtils.rm @progress_file_name if File.exists?(@progress_file_name)
    @progress_file = DicomS::SharedSettings.new(@progress_file_name)
  end

  def teardown
    FileUtils.rm @progress_file_name if File.exists?(@progress_file_name)
    @progress_file = nil
  end

  def test_start
    refute File.exists?(@progress_file_name) # sanity check
    progress = DicomS::Progress.new('Test process', progress: @progress_file_name)
    assert File.file?(@progress_file_name)
    data = @progress_file.read
    assert_equal 0, progress.progress
    assert_equal 0, data.progress
    assert_equal 'Test process', data.process
    assert_nil data.subprocess
  end

  def test_progress
    progress = DicomS::Progress.new('Test process', progress: @progress_file_name)
    refute progress.finished?
    progress.update 10
    refute progress.finished?
    data = @progress_file.read
    assert_equal 10, progress.progress
    assert_equal 10, data.progress
    assert_equal 'Test process', data.process
    assert_nil data.subprocess
    progress.update 20, 'Test subprocess'
    refute progress.finished?
    data = @progress_file.read
    assert_equal 20, progress.progress
    assert_equal 20, data.progress
    assert_equal 'Test process', data.process
    assert_equal 'Test subprocess', data.subprocess
    progress.update 30
    refute progress.finished?
    data = @progress_file.read
    assert_equal 30, progress.progress
    assert_equal 30, data.progress
    assert_equal 'Test process', data.process
    assert_equal 'Test subprocess', data.subprocess
    progress.finish
    data = @progress_file.read
    assert File.file?(@progress_file_name)
    assert progress.finished?
    assert_equal 100, progress.progress
    assert_equal 100, data.progress
    assert_equal 'Test process', data.process
  end

  def test_subprocess
    progress = DicomS::Progress.new('Test process', progress: @progress_file_name)
    progress.update 10
    progress.begin_subprocess 'Test subprocess', 60, 4
    refute progress.finished?
    data = @progress_file.read
    assert_equal 10, progress.progress
    assert_equal 10, data.progress
    assert_equal 'Test process', data.process
    assert_equal 'Test subprocess', data.subprocess
    progress.update_subprocess 2
    refute progress.finished?
    data = @progress_file.read
    assert_equal 10+60/2, progress.progress
    assert_equal 10+60/2, data.progress
    assert_equal 'Test process', data.process
    assert_equal 'Test subprocess', data.subprocess
    progress.update_subprocess 3
    refute progress.finished?
    data = @progress_file.read
    assert_equal 10+60*3.0/4, progress.progress
    assert_equal 10+60*3.0/4, data.progress
    assert_equal 'Test process', data.process
    assert_equal 'Test subprocess', data.subprocess
    progress.begin_subprocess 'Test subprocess 2', 10, 4
    refute progress.finished?
    data = @progress_file.read
    assert_equal 10+60, progress.progress
    assert_equal 10+60, data.progress
    assert_equal 'Test process', data.process
    assert_equal 'Test subprocess 2', data.subprocess
    progress.update_subprocess 2
    refute progress.finished?
    data = @progress_file.read
    assert_equal 10+60+10/2, progress.progress
    assert_equal 10+60+10/2, data.progress
    assert_equal 'Test process', data.process
    assert_equal 'Test subprocess 2', data.subprocess
    progress.end_subprocess
    refute progress.finished?
    data = @progress_file.read
    assert_equal 10+60+10, data.progress
    assert_equal 10+60+10, progress.progress
    assert_equal 'Test process', data.process
    refute progress.finished?
  end

  def test_no_progress
    progress = DicomS::Progress.new('Test process')
    refute File.exists?(@progress_file_name)
    refute progress.finished?
    progress.update 10
    refute progress.finished?
    refute File.exists?(@progress_file_name)
    assert_equal 10, progress.progress
    progress.update 20, 'Test subprocess'
    refute progress.finished?
    assert_equal 20, progress.progress
    refute File.exists?(@progress_file_name)
    progress.update 30
    refute progress.finished?
    assert_equal 30, progress.progress
    refute File.exists?(@progress_file_name)
    progress.finish
    refute File.exists?(@progress_file_name)
    assert progress.finished?
    assert_equal 100, progress.progress
  end

  def test_no_progress_with_subprocesses
    progress = DicomS::Progress.new('Test process')
    refute File.exists?(@progress_file_name)
    progress.update 10
    refute File.exists?(@progress_file_name)
    progress.begin_subprocess 'Test subprocess', 60, 4
    refute File.exists?(@progress_file_name)
    refute progress.finished?
    assert_equal 10, progress.progress
    refute File.exists?(@progress_file_name)
    progress.update_subprocess 2
    refute progress.finished?
    assert_equal 10+60/2, progress.progress
    refute File.exists?(@progress_file_name)
    progress.update_subprocess 3
    refute progress.finished?
    assert_equal 10+60*3.0/4, progress.progress
    refute File.exists?(@progress_file_name)
    progress.begin_subprocess 'Test subprocess 2', 10, 4
    refute progress.finished?
    assert_equal 10+60, progress.progress
    refute File.exists?(@progress_file_name)
    progress.update_subprocess 2
    refute progress.finished?
    assert_equal 10+60+10/2, progress.progress
    refute File.exists?(@progress_file_name)
    progress.end_subprocess
    refute progress.finished?
    assert_equal 10+60+10, progress.progress
    refute File.exists?(@progress_file_name)
    refute progress.finished?
  end
end
