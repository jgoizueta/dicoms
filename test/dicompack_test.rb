require 'test_helper'

class DicomPackTest < Minitest::Test

  def setup
    @data_dir  = File.join('test', 'data')
    @dicom_dir = File.join(@data_dir, 'dicom')
    @empty_dir = File.join(@data_dir, 'empty')
    FileUtils.mkdir_p @empty_dir
    if File.directory?(@dicom_dir)
      @dicom_files = Dir[File.join(@dicom_dir, '*')]
    end
  end

  def teardown
    FileUtils.rm_rf @empty_dir
    if @dicom_files
      Dir[File.join(@dicom_dir, '*')].each do |fn|
        unless @dicom_files.include?(fn)
          FileUtils.rm fn
        end
      end
    end
  end

  def test_that_it_has_a_version_number
    refute_nil ::DicomPack::VERSION
  end

  def test_dicom_file_list
    unless File.directory?(@dicom_dir)
      skip
      return
    end
    settings = {}
    dicompack = DicomPack.new(settings)
    all_files = dicompack.find_dicom_files(@dicom_dir)
    assert_equal Dir[File.join(@dicom_dir, '*')].size,
                 all_files.size
    a_file = all_files.first
    if a_file
      one_file = dicompack.find_dicom_files(a_file)
      assert_equal [a_file], one_file
    end
    no_files = dicompack.find_dicom_files(@empty_dir)
    assert no_files.empty?

    # Non-dicom files are ignored
    no_dicom = File.join(@dicom_dir, 'non_dicom.dcm')
    File.write no_dicom, 'NOT A DICOM FILE'
    begin
      assert_equal all_files, dicompack.find_dicom_files(@dicom_dir)
      assert dicompack.find_dicom_files(no_dicom).empty?
    ensure
      FileUtils.rm no_dicom
    end

    no_dicom = File.join(@empty_dir, 'non_dicom.dcm')
    File.write no_dicom, 'NOT A DICOM FILE'
    begin
      assert dicompack.find_dicom_files(@empty_dir).empty?
    ensure
      FileUtils.rm no_dicom
    end

    non_existent = File.join(@empty_dir, 'no_file.dcm')
    assert dicompack.find_dicom_files(non_existent).empty?
  end
end
