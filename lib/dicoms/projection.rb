require 'rmagick'

class DicomS
  NORMALIZE_PROJECTION_IMAGES = true
  ASSIGN_IMAGE_PIXELS_AS_ARRAY = true
  ADJUST_AAP_FOR_WIDTH = true

  # extract projected images of a set of DICOM files
  def projection(dicom_directory, options = {})
    options = CommandOptions[options]

    progress = Progress.new('projecting', options)
    progress.begin_subprocess 'reading_metadata', 1

    # We can save on memory use by using 8-bit processing, so it will be the default
    strategy = define_transfer(options, :window, output: :byte)
    sequence = Sequence.new(dicom_directory, transfer: strategy)

    extract_dir = options.path_option(
      :output, File.join(File.expand_path(dicom_directory), 'images')
    )
    FileUtils.mkdir_p extract_dir

    if sequence.metadata.lim_max <= 255
       bits = 8
     else
       bits = 16
    end

    reverse_x = sequence.metadata.reverse_x.to_i == 1
    reverse_y = sequence.metadata.reverse_y.to_i == 1
    reverse_z = sequence.metadata.reverse_z.to_i == 1

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

    if full_projection?(options[:axial]) || full_projection?(options[:coronal]) || full_projection?(options[:sagittal])
      percent = 65
    else
      percent = 90
    end
    progress.begin_subprocess 'generating_volume', percent, maxz

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
        progress.update_subprocess z
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

    n = axial_zs.size + sagittal_xs.size + coronal_ys.size

    axial_scale = coronal_scale = sagittal_scale = nil

    progress.begin_subprocess 'generating_slices', -70, n if n > 0
    axial_zs.each_with_index do |(z, suffix), i|
      slice = volume[true, true, z]
      output_image = output_file_name(extract_dir, 'axial_', suffix || z.to_s)
      axial_scale = save_pixels slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
        dx: sequence.metadata.dx, dy: sequence.metadata.dy,
        maxcols: options.maxcols || options.max_x_pixels,
        maxrows: options.maxrows || options.max_y_pixels,
        normalize: NORMALIZE_PROJECTION_IMAGES
      progress.update_subprocess i
    end
    sagittal_xs.each_with_index do |(x, suffix), i|
      slice = volume[x, true, true]
      output_image = output_file_name(extract_dir, 'sagittal_', suffix || x.to_s)
      sagittal_scale = save_pixels slice, output_image,
        bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
        dx: sequence.metadata.dy, dy: sequence.metadata.dz,
        maxcols: options.maxcols || options.max_y_pixels,
        maxrows: options.maxrows || options.max_z_pixels,
        normalize: NORMALIZE_PROJECTION_IMAGES
      progress.update_subprocess axial_zs.size + i
    end
    coronal_ys.each_with_index do |(y, suffix), i|
      slice = volume[true, y, true]
      output_image = output_file_name(extract_dir, 'coronal_', suffix || y.to_s)
      corotnal_scale save_pixels slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
        dx: sequence.metadata.dx, dy: sequence.metadata.dz,
        maxcols: options.maxcols || options.max_x_pixels,
        maxrows: options.maxrows || options.max_z_pixels,
        normalize: NORMALIZE_PROJECTION_IMAGES
      progress.update_subprocess axial_zs.size + sagittal_xs.size + i
    end

    n = [:axial, :coronal, :sagittal].map{ |axis|
      aggregate_projection?(options[axis]) ? 1 : 0
    }.inject(&:+)
    progress.begin_subprocess 'generating_projections', 100, n if n > 0
    i = 0

    float_v = nil
    if options.to_h.values_at(:axial, :coronal, :sagittal).any?{ |sel|
         aggregate_projection_includes?(sel, 'aap')
       }
      # It's gonna take memory... (a whole lot of precious memory)
      float_v ||= volume.to_type(NArray::SFLOAT)
      # To enhance result contrast we will apply a gamma of x**4
      float_v.mul! 1.0/float_v.max
      float_v.mul! float_v
      float_v.mul! float_v
    end
    if aggregate_projection?(options[:axial])
      views = []
      if aggregate_projection_includes?(options[:axial], 'aap')
        slice = accumulated_attenuation_projection(
          float_v, Z_AXIS, sequence.metadata.lim_max, maxz
        ).to_type(volume.typecode)
        views << ['aap', slice]
      end
      if aggregate_projection_includes?(options[:axial], 'mip')
        slice = maximum_intensity_projection(volume, Z_AXIS)
        views << ['mip', slice]
      end
      views.each do |view, slice|
        output_image = output_file_name(extract_dir, 'axial_', view)
        axial_scale = save_pixels slice, output_image,
          bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
          dx: sequence.metadata.dx, dy: sequence.metadata.dy,
          maxcols: options.maxcols || options.max_x_pixels,
          maxrows: options.maxrows || options.max_y_pixels,
          normalize: NORMALIZE_PROJECTION_IMAGES
      end
      i += 1
      progress.update_subprocess i
    end
    if aggregate_projection?(options[:coronal])
      views = []
      if aggregate_projection_includes?(options[:coronal], 'aap')
        # It's gonna take memory... (a whole lot of precious memory)
        float_v ||= volume.to_type(NArray::SFLOAT)
        slice = accumulated_attenuation_projection(
          float_v, Y_AXIS, sequence.metadata.lim_max, maxy
        ).to_type(volume.typecode)
        views << ['aap', slice]
      end
      if aggregate_projection_includes?(options[:coronal], 'mip')
         slice = maximum_intensity_projection(volume, Y_AXIS)
         views << ['mip', slice]
      end
      views.each do |view, slice|
        output_image = output_file_name(extract_dir, 'coronal_', view)
        coronal_scale = save_pixels slice, output_image,
          bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
          dx: sequence.metadata.dx, dy: sequence.metadata.dz,
          maxcols: options.maxcols || options.max_x_pixels,
          maxrows: options.maxrows || options.max_z_pixels,
          normalize: NORMALIZE_PROJECTION_IMAGES
      end
      i += 1
      progress.update_subprocess i
    end
    if aggregate_projection?(options[:sagittal])
      views = []
      if aggregate_projection_includes?(options[:sagittal], 'aap')
        # It's gonna take memory... (a whole lot of precious memory)
        float_v ||= volume.to_type(NArray::SFLOAT)
        slice = accumulated_attenuation_projection(
          float_v, X_AXIS, sequence.metadata.lim_max, maxx
        ).to_type(volume.typecode)
        views << ['aap', slice]
      end
      if aggregate_projection_includes?(options[:sagittal], 'mip')
        slice = maximum_intensity_projection(volume, X_AXIS)
        views << ['mip', slice]
      end
      views.each do |view, slice|
        output_image = output_file_name(extract_dir, 'sagittal_', view)
        sagittal_scale = save_pixels slice, output_image,
          bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
          dx: sequence.metadata.dy, dy: sequence.metadata.dz,
          maxcols: options.maxcols || options.max_y_pixels,
          maxrows: options.maxrows || options.max_z_pixels,
          normalize: NORMALIZE_PROJECTION_IMAGES
      end
      i += 1
      progress.update_subprocess i
    end
    float_v = nil
    sequence.metadata.merge! axial_scale: axial_scale
    sequence.metadata.merge! coronal_scale: coronal_scale
    sequence.metadata.merge! sagittal_scale: sagittal_scale
    options.save_settings 'projection', sequence.metadata
    progress.finish
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
    axis_selection && axis_selection.split(',').any? { |sel|
      ['*', 'mip', 'aap'].include?(sel)
    }
  end

  def full_projection?(axis_selection)
    axis_selection && axis_selection.split(',').any? { |sel| sel == '*' }
  end

  def single_slice_projection?(axis_selection)
    axis_selection.is_a?(String) && /\A\d+\Z/i =~ axis_selection
  end

  def center_slice_projection?(axis_selection)
    axis_selection && axis_selection.split(',').any? { |sel| sel.downcase == 'c' }
  end

  def middle_slice_projection?(axis_selection)
    axis_selection && axis_selection.split(',').any? { |sel| sel.downcase == 'm' }
  end

  def aggregate_projection_includes?(axis_selection, projection)
    axis_selection && axis_selection.split(',').any? { |sel|
      sel == projection
    }
  end

  def save_pixels(pixels, output_image, options = {})
    bits = options[:bit_depth] || 16
    reverse_x = options[:reverse_x]
    reverse_y = options[:reverse_y]
    normalize = options[:normalize]
    # pixel aspect:
    dx = options[:dx] || 1
    dy = options[:dy] || 1
    # max image size
    maxcols = options[:maxcols]
    maxrows = options[:maxrows]

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
    scalex = scaley = 1
    if dx != dy || maxcols || maxrows
      sx = sx0 = image.columns
      sy = sy0 = image.rows
      maxcols ||= sx0
      maxrows ||= sy0
      if dx > dy
        sy *= dy.to_f/dx
      else
        sy *= dx.to_f/dy
      end
      if sx > maxcols || sy > maxrows
        fx = maxcols.to_f/sx
        fy = maxrows.to_f/sy
        f = [fx, fy].min
        sx *= f
        sy *= f
      end
      sx = sx.round
      sy = sy.round
      if sx != sx0 || sy != sy0
        image = image.resize(sx, sy)
        scalex = sx/sx0.to_f
        scaley = sy/sy0.to_f
      end
    end
    image.write(output_image)
    [scalex, scaley]
  end

end
