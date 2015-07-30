require 'test_helper'

class DicomPackTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::DicomPack::VERSION
  end

  def test_pack_unpack_preserves_images
    data_dir = File.join('test', 'data')
    dicom_dir = File.join(data_dir, 'dicom')
    img_dir = File.join(data_dir, 'img')
    tmp_dir = File.join(data_dir, 'tmp')
    out_dir = File.join(data_dir, 'out')
    pack_file = File.join(data_dir, 'pack')

    # TODO: download test DICOM files

    unless File.directory?(dicom_dir)
      skip
      return
    end

    FileUtils.mkdir_p img_dir
    FileUtils.mkdir_p tmp_dir
    FileUtils.mkdir_p out_dir

    settings = {}
    dicompack = DicomPack.new(settings)
    dicompack.extract(
      dicom_dir,
      strategy: :first,  # TODO: use sample, but fix seed
      drop_base: true,
      output: img_dir
    )
    img_files = Dir[File.join(img_dir, '*')].sort
    num_imgs = img_files.size
    assert num_imgs > 0

    dicompack = DicomPack.new(settings)
    dicompack.pack(
      dicom_dir,
      strategy: :first,
      drop_base: true,
      output: pack_file,
      tmp: tmp_dir
    )

    pack_file = pack_file + ".mkv"

    assert File.file?(pack_file), "Packed file #{pack_file} exists"
    # TODO: assert pack_file size < (total size of dicom_files)/10

    dicompack.unpack(
      pack_file,
      output: out_dir
    )

    out_files = Dir[File.join(out_dir, '*.jpeg')].sort
    num_out = out_files.size
    assert_equal num_imgs, num_out
    img_files.zip(out_files).each do |in_fn, out_fn|
      a = Magick::Image.read(in_fn).first
      b = Magick::Image.read(out_fn).first
      assert_equal a.rows, b.rows
      assert_equal a.columns, b.columns
      diff = a.compare_channel(b, Magick::MeanSquaredErrorMetric).last
      assert diff <= 2E-5, "File #{in_fn} similar to #{out_fn}"
    end
    FileUtils.rm_rf tmp_dir
    FileUtils.rm_rf pack_file
    FileUtils.rm_rf img_dir
    FileUtils.rm_rf out_dir
  end
end
