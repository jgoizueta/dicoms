require 'rmagick'

class DicomPack
  NORMALIZE_PROJECTION_IMAGES = true
  ASSIGN_IMAGE_PIXELS_AS_ARRAY = true
  ADJUST_AAP_FOR_WIDTH = true

  # extract projected images of a set of DICOM files
  def projection(dicom_directory, options = {})
    # We can save on memory use by using 8-bit processing:
    options = options.merge(output: :byte)

    strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
    sequence = Sequence.new(dicom_directory, strategy: strategy)

    extract_dir = options[:output] || File.join(dicom_directory, 'images')
    FileUtils.mkdir_p FileUtils.mkdir_p extract_dir

    if sequence.metadata.lim_max <= 255
       bits = 8
     else
       bits = 16
    end

    xaxis = decode_vector(sequence.metadata.xaxis)
    yaxis = decode_vector(sequence.metadata.yaxis)
    zaxis = decode_vector(sequence.metadata.zaxis)
    if xaxis[0].abs != 1 || xaxis[1] != 0 || xaxis[2] != 0 ||
       yaxis[0] != 0 || yaxis[1] != 1 || yaxis[2] != 0 ||
       zaxis[0] != 0 || zaxis[1] != 0 || zaxis[2].abs != 1
      raise Error, "Unsupported orientation"
    end
    reverse_x = xaxis[0] < 0
    reverse_y = yaxis[1] < 0
    reverse_z = zaxis[2] < 0

    maxx = sequence.metadata.nx
    maxy = sequence.metadata.ny
    maxz = sequence.metadata.nz

    # minimum and maximum slices with non-(almost)-blank contents
    minx_contents = maxx
    maxx_contents = 0
    miny_contents = maxy
    maxy_contents = 0
    minz_contents = maxz
    maxz_contents = 0

    # Load all the slices into a (big) 3D array
    if bits == 8
      # TODO: support signed too
      volume = NArray.byte(maxx, maxy, maxz)
    else
      # With type NArray::SINT instead of NArray::INT we would use up half the
      # memory, but each slice to be converted to image would have to be
      # convertd to INT...
      # volume = NArray.sint(maxx, maxy, maxz)
      volume = NArray.int(maxx, maxy, maxz)
    end
    keeping_path do
      sequence.each do |dicom, z, file|
        slice = sequence.dicom_pixels(dicom, unsigned: true)
        volume[true, true, z] = slice
        if center_slice_projection?(options[:axial])
          minz_contents, maxz_contents = update_min_max_contents(
            z, slice.max, maxy, minz_contents, maxz_contents
          )
        end
      end
    end

    if center_slice_projection?(options[:coronal])
      (0...maxy).each do |y|
        miny_contents, maxy_contents = update_min_max_contents(
          y, volume[true, y, true].max, maxy, miny_contents, maxy_contents
        )
      end
    end

    if center_slice_projection?(options[:sagittal])
      (0...maxz).each do |z|
        minz_contents, maxz_contents = update_min_max_contents(
          z, volume[true, true, z].max, maxz, minz_contents, maxz_contents
        )
      end
    end

    if single_slice_projection?(options[:axial])
      axial_zs = [options[:axial].to_i]
    elsif center_slice_projection?(options[:axial])
      axial_zs = [[(minz_contents+maxz_contents)/2, 'c']]
    elsif middle_slice_projection?(options[:axial])
      axial_zs = [[maxz/2, 'm']]
    elsif full_projection?(options[:axial])
      axial_zs = (0...maxz)
    else
      axial_zs = []
    end
    axial_zs.each do |z, suffix|
      slice = volume[true, true, z]
      output_image = output_file_name(extract_dir, 'axial_', suffix || z.to_s)
      save_pixels slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
        normalize: NORMALIZE_PROJECTION_IMAGES
    end

    if single_slice_projection?(options[:sagittal])
      sagittal_xs = [options[:sagittal].to_i]
    elsif center_slice_projection?(options[:sagittal])
      sagittal_xs = [[(minx_contents+maxx_contents)/2, 'c']]
    elsif middle_slice_projection?(options[:sagittal])
      sagittal_xs = [[maxx/2, 'm']]
    elsif full_projection?(options[:sagittal])
      sagittal_xs = (0...maxx)
    else
      sagittal_xs = []
    end
    sagittal_xs.each do |x, suffix|
      slice = volume[x, true, true]
      output_image = output_file_name(extract_dir, 'sagittal_', suffix || x.to_s)
      save_pixels slice, output_image,
        bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
        normalize: NORMALIZE_PROJECTION_IMAGES
    end

    if single_slice_projection?(options[:coronal])
      coronal_ys = [options[:coronal].to_i]
    elsif center_slice_projection?(options[:coronal])
      coronal_ys = [[(miny_contents+maxy_contents)/2, 'c']]
    elsif middle_slice_projection?(options[:coronal])
      coronal_ys = [[maxy/2, 'm']]
    elsif full_projection?(options[:coronal])
      coronal_ys = (0...maxx)
    else
      coronal_ys = []
    end
    coronal_ys.each do |y, suffix|
      slice = volume[true, y, true]
      output_image = output_file_name(extract_dir, 'coronal_', suffix || y.to_s)
      save_pixels slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
        normalize: NORMALIZE_PROJECTION_IMAGES
    end

    float_v = nil
    if options.values_at(:axial, :coronal, :sagittal).include?('aap')
      # It's gonna take memory... (a whole lot of precious memory)
      float_v ||= volume.to_type(NArray::SFLOAT)
      # To enhance result contrast we will apply a gamma of x**4
      float_v.mul! 1.0/float_v.max
      float_v.mul! float_v
      float_v.mul! float_v
    end
    if aggregate_projection?(options[:axial])
      if options[:axial] == 'aap'
        slice = accumulated_attenuation_projection(
          float_v, Z_AXIS, sequence.metadata.lim_max, maxz
        ).to_type(volume.typecode)
      else # 'mip' ('*' is also handled here)
        slice = maximum_intensity_projection(volume, Z_AXIS)
      end
      output_image = output_file_name(extract_dir, 'axial_', "#{options[:axial]}")
      save_pixels slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
        normalize: NORMALIZE_PROJECTION_IMAGES
    end
    if aggregate_projection?(options[:coronal])
      if options[:coronal] == 'aap'
        # It's gonna take memory... (a whole lot of precious memory)
        float_v ||= volume.to_type(NArray::SFLOAT)
        slice = accumulated_attenuation_projection(
          float_v, Y_AXIS, sequence.metadata.lim_max, maxy
        ).to_type(volume.typecode)
      else # 'mip' ('*' is also handled here)
         slice = maximum_intensity_projection(volume, Y_AXIS)
      end
      output_image = output_file_name(extract_dir, 'coronal_', "#{options[:coronal]}")
      save_pixels slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
        normalize: NORMALIZE_PROJECTION_IMAGES
    end
    if aggregate_projection?(options[:sagittal])
      if options[:sagittal] == 'aap'
        # It's gonna take memory... (a whole lot of precious memory)
        float_v ||= volume.to_type(NArray::SFLOAT)
        slice = accumulated_attenuation_projection(
          float_v, X_AXIS, sequence.metadata.lim_max, maxx
        ).to_type(volume.typecode)
      else # 'mip' ('*' is also handled here)
        slice = maximum_intensity_projection(volume, X_AXIS)
      end
      output_image = output_file_name(extract_dir, 'sagittal_', "#{options[:sagittal]}")
      save_pixels slice, output_image,
        bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
        normalize: NORMALIZE_PROJECTION_IMAGES
    end
    float_v = nil
  end

  private

  X_AXIS = 0
  Y_AXIS = 1
  Z_AXIS = 2

  def update_min_max_contents(pos, max, ref_max, current_min, current_max)
    if max/ref_max.to_f >= 0.05
      current_min = [current_min, pos].min
      current_max = [current_max, pos].max
    end
    [current_min, current_max]
  end

  def maximum_intensity_projection(v, axis)
    v.max(axis)
  end

  def accumulated_attenuation_projection(float_v, axis, max_output_level, max=500)
    k = 0.02
    if ADJUST_AAP_FOR_WIDTH
      k *= 500.0/max
    end
    v = float_v.sum(axis)
    v.mul! -k
    v = NMath.exp(v)
    # Invert result (from attenuation to transmission)
    v.mul! -max_output_level
    v.add! max_output_level
    v
  end

  def axis_index(v, maxv, reverse)
    reverse ? maxv - v : v
  end

  def aggregate_projection?(axis_selection)
    ['*', 'mip', 'aap'].include?(axis_selection)
  end

  def full_projection?(axis_selection)
    axis_selection == '*'
  end

  def single_slice_projection?(axis_selection)
    axis_selection.is_a?(String) && /\A\d+\Z/i =~ axis_selection
  end

  def center_slice_projection?(axis_selection)
    axis_selection.downcase == 'c'
  end

  def middle_slice_projection?(axis_selection)
    axis_selection.downcase == 'm'
  end

  def save_pixels(pixels, output_image, options = {})
    bits = options[:bit_depth] || 16
    reverse_x = options[:reverse_x]
    reverse_y = options[:reverse_y]
    normalize = options[:normalize]
    columns, rows = pixels.shape

    if ASSIGN_IMAGE_PIXELS_AS_ARRAY
      # assign from array
      if Magick::MAGICKCORE_QUANTUM_DEPTH != bits
        if bits == 8
          # scale up the data
          pixels = pixels.to_type(NArray::INT)
          pixels.mul! 256
        else
          # scale down
          pixels.div! 256
          pixels = pixels.to_type(NArray::BYTE) # FIXME: necessary?
        end
      end
      image = Magick::Image.new(columns, rows).import_pixels(0, 0, columns, rows, 'I', pixels.flatten)
    else
      # Pack to a String (blob) and let Magick do the conversion
      if bits == 8
        rm_type = Magick::CharPixel
        blob = pixels.flatten.to_a.pack('C*')
      else
        rm_type = Magick::ShortPixel
        blob = pixels.flatten.to_a.pack('S<*')
      end
      image = Magick::Image.new(columns, rows).import_pixels(0, 0, columns, rows, 'I', blob, rm_type)
    end

    image.flip! if reverse_y
    image.flop! if reverse_x
    image = image.normalize if normalize
    image.write(output_image)
  end

end
