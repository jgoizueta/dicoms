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
    pack_name = File.join(data_dir, 'pack')
    pack_file = pack_name + ".mkv"

    # TODO: download test DICOM files

    unless File.directory?(dicom_dir)
      skip
      return
    end

    alternatives = [
      { strategy: :first, drop_base: false },
      { strategy: :first, drop_base: true },
      { strategy: :global, drop_base: false },
      { strategy: :global, drop_base: true },
      { strategy: :window }
    ]

    alternatives.each do |strategy|
      FileUtils.mkdir_p img_dir
      FileUtils.mkdir_p tmp_dir
      FileUtils.mkdir_p out_dir

      settings = {}
      dicompack = DicomPack.new(settings)
      dicompack.extract(
        dicom_dir,
        strategy.merge(output: img_dir)
      )
      img_files = Dir[File.join(img_dir, '*')].sort
      num_imgs = img_files.size
      assert num_imgs > 0
      total_size = img_files.map { |f| File.size(f) }.inject(&:+)
      dicom_size = dicompack.find_dicom_files(dicom_dir).map { |f| File.size(f) }.inject(&:+)

      dicompack = DicomPack.new(settings)
      dicompack.pack(
        dicom_dir,
        strategy.merge(output: pack_name, tmp: tmp_dir)
      )

      assert File.file?(pack_file), "Packed file #{pack_file} exists"
      if num_imgs >= 10
        assert File.size(pack_file) < total_size
      end
      assert File.size(pack_file) < dicom_size/5, "File size is reduced"

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
end
