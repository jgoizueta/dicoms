require 'rmagick'

class DicomS
  # Extract all projected views (all slices in the three axis,
  # plus aap and mip projectios)
  def explode(dicom_directory, options = {})
    options = CommandOptions[options]

    progress = Progress.new('projecting', options)
    progress.begin_subprocess 'reading_metadata', 1

    # Create sequence without a transfer strategy
    # (identity strategy with rescaling would also do)
    # so that we're working with Hounsfield units
    sequence = Sequence.new(
      dicom_directory,
      reorder: options[:reorder]
    )

    slice_transfer = define_transfer(
      options,
      :window,
      output: :unsigned
    )
    mip_transfer = define_transfer(
      { transfer: options[:mip_transfer] },
      :fixed,
      min: -1000, max: 2000,
      output: :unsigned
    )
    aap_transfer = Transfer.strategy :fixed, min: 0.0, max: 1.0, float: true, output: :unsigned

    extract_dir = options.path_option(
      :output, File.join(File.expand_path(dicom_directory), 'images')
    )
    FileUtils.mkdir_p extract_dir

    if sequence.metadata.lim_max <= 255
      bits = 8
    else
      bits = 16
    end

    scaling = projection_scaling(sequence.metadata, options)
    sequence.metadata.merge! scaling
    scaling = Settings[scaling]

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

    progress.begin_subprocess 'generating_volume', 50, maxz

    # Load all the slices into a floating point 3D array
    volume = NArray.sfloat(maxx, maxy, maxz)
    keeping_path do
      sequence.each do |dicom, z, file|
        slice = sequence.dicom_pixels(dicom)
        volume[true, true, z] = slice
        progress.update_subprocess z
      end
    end

    maxv = volume.max

    # Generate slices

    axial_zs = (0...maxz)
    sagittal_xs = (0...maxx)
    coronal_ys = (0...maxy)

    # Will determine first and last slice with noticeable contents in each axis
    # Slices outside the range won't be generated to save space
    # This information will also be used for the app projection
    minx_contents = maxx
    maxx_contents = 0
    miny_contents = maxy
    maxy_contents = 0
    minz_contents = maxz
    maxz_contents = 0

    n = axial_zs.size + sagittal_xs.size + coronal_ys.size

    progress.begin_subprocess 'generating_slices', -70, n if n > 0
    axial_zs.each_with_index do |z, i|
      slice = volume[true, true, z]
      minz_contents, maxz_contents = update_min_max_contents(
        z, slice.max, maxv, minz_contents, maxz_contents
      )
      next unless (minz_contents..maxz_contents).include?(z)
      output_image = output_file_name(extract_dir, 'axial_', z.to_s)
      save_transferred_pixels sequence, slice_transfer, slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
        cols: scaling.scaled_nx, rows: scaling.scaled_ny,
        normalize: false
      progress.update_subprocess i
    end
    sagittal_xs.each_with_index do |x, i|
      slice = volume[x, true, true]
      minx_contents, maxx_contents = update_min_max_contents(
        x, slice.max, maxv, minx_contents, maxx_contents
      )
      next unless (minx_contents..maxx_contents).include?(x)
      output_image = output_file_name(extract_dir, 'sagittal_', x.to_s)
      save_transferred_pixels sequence, slice_transfer, slice, output_image,
        bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
        cols: scaling.scaled_ny, rows: scaling.scaled_nz,
        normalize: false
      progress.update_subprocess axial_zs.size + i
    end
    coronal_ys.each_with_index do |y, i|
      slice = volume[true, y, true]
      miny_contents, maxy_contents = update_min_max_contents(
        y, slice.max, maxv, miny_contents, maxy_contents
      )
      next unless (miny_contents..maxy_contents).include?(y)
      output_image = output_file_name(extract_dir, 'coronal_', y.to_s)
      save_transferred_pixels sequence, slice_transfer, slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
        cols: scaling.scaled_nx, rows: scaling.scaled_nz,
        normalize: false
      progress.update_subprocess axial_zs.size + sagittal_xs.size + i
    end

    progress.begin_subprocess 'generating_projections', 100, 6

    # Generate MIP projections
    slice = maximum_intensity_projection(volume, Z_AXIS)
    output_image = output_file_name(extract_dir, 'axial_', 'mip')
    save_transferred_pixels sequence, mip_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
      cols: scaling.scaled_nx, rows: scaling.scaled_ny,
      normalize: true
    progress.update_subprocess 1

    slice = maximum_intensity_projection(volume, Y_AXIS)
    output_image = output_file_name(extract_dir, 'coronal_', 'mip')
    save_transferred_pixels sequence, mip_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
      cols: scaling.scaled_nx, rows: scaling.scaled_nz,
      normalize: true
    progress.update_subprocess 2

    slice = maximum_intensity_projection(volume, X_AXIS)
    output_image = output_file_name(extract_dir, 'sagittal_', 'mip')
    save_transferred_pixels sequence, mip_transfer, slice, output_image,
      bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
      cols: scaling.scaled_ny, rows: scaling.scaled_nz,
      normalize: true
    progress.update_subprocess 3

    # Generate AAP Projections
    c = dicom_window_center(sequence.first)
    w = dicom_window_width(sequence.first)
    dx = sequence.metadata.dx
    dy = sequence.metadata.dy
    dz = sequence.metadata.dz
    numx = maxx_contents - minx_contents + 1 if minx_contents <= maxx_contents
    numy = maxy_contents - miny_contents + 1 if miny_contents <= maxy_contents
    numz = maxz_contents - minz_contents + 1 if minz_contents <= maxz_contents
    daap = DynamicAap.new(
      volume,
      center: c, width: w, dx: dx, dy: dy, dz: dz,
      numx: numx, numy: numy, numz: numz
    )
    slice = daap.view(Z_AXIS)
    output_image = output_file_name(extract_dir, 'axial_', 'aap')
    save_transferred_pixels sequence, aap_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
      cols: scaling.scaled_nx, rows: scaling.scaled_ny,
      normalize: true
    progress.update_subprocess 4

    slice = daap.view(Y_AXIS)
    output_image = output_file_name(extract_dir, 'coronal_', 'aap')
    save_transferred_pixels sequence, aap_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
      cols: scaling.scaled_nx, rows: scaling.scaled_nz,
      normalize: true
    progress.update_subprocess 5

    slice = daap.view(X_AXIS)
    output_image = output_file_name(extract_dir, 'sagittal_', 'aap')
    save_transferred_pixels sequence, aap_transfer, slice, output_image,
      bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
      cols: scaling.scaled_ny, rows: scaling.scaled_nz,
      normalize: true
    progress.update_subprocess 6

    volume = nil
    sequence.metadata.merge!(
      axial_first: minz_contents, axial_last: maxz_contents,
      coronal_first: miny_contents, coronal_last: maxy_contents,
      sagittal_first: minx_contents, sagittal_last: maxx_contents
    )
    options.save_settings 'projection', sequence.metadata
    progress.finish
  end

  def power(data, factor)
    NMath.exp(factor*NMath.log(data))
  end

  def save_transferred_pixels(sequence, transfer, pixels, output_image, options)
    dicom = sequence.first
    min, max = transfer.min_max(sequence)
    pixels = transfer.transfer_rescaled_pixels(dicom, pixels, min, max)
    save_pixels pixels, output_image, options
  end

  class DynamicAap

    PRE_GAMMA = 8
    SUM_NORMALIZATION = false
    IMAGE_GAMMA = nil
    IMAGE_ADJUSTMENT = true
    WINDOW_BY_DEFAULT = true
    NO_WINDOW = true
    IMAGE_CONTRAST = nil

    def initialize(data, options)
      center = options[:center]
      width = options[:width]
      if center && width && !NO_WINDOW
        # 1. Window level normalization
        if options[:window_sigmod_gamma]
          # 1.a using sigmod
          gamma = options[:window_sigmod_gamma] || 3.0
          k0 = options[:window_sigmod_k0] || 0.06
          sigmoid = Sigmoid.new(center: center, width: width, gamma: gamma, k0: k0)
          data = sigmoid[data]
        elsif options[:k0] || WINDOW_BY_DEFAULT
          # 1.b simpler linear pseudo-sigmoid
          max = data.max
          min = data.min
          k0 = options[:k0] || 0.1
          v_lo = center - width*0.5
          v_hi = center + width*0.5
          low_part = (data < v_lo)
          high_part = (data > v_hi)
          mid_part = (low_part | high_part).not

          data[low_part] -= min
          data[low_part] *= k0/(v_lo - min)

          data[high_part] -= v_hi
          data[high_part] *= k0/(max - v_hi)
          data[high_part] += 1.0 - k0

          data[mid_part] -= v_lo
          data[mid_part] *= (1.0 - 2*k0)/width
          data[mid_part] += k0
        else
          # 1.c clip to window (like 1.b with k0=0)
          max = data.max
          min = data.min
          k0 = options[:k0] || 0.02
          v_lo = center - width*0.5
          v_hi = center + width*0.5

          low_part = (data < v_lo)
          high_part = (data > v_hi)
          mid_part = (low_part | high_part).not

          data[low_part] = 0
          data[high_part] = 1

          data[mid_part] -= v_lo
          data[mid_part] *= 1.0/width
        end
      else
        # Normalize to 0-1
        data.add! -data.min
        data.mul! 1.0/data.max
      end

      if PRE_GAMMA
        if [2, 4, 8].include?(PRE_GAMMA)
          g = PRE_GAMMA
          while g > 1
            data.mul! data
            g /= 2
          end
        else
          data = power(data, PRE_GAMMA)
        end
      end

      @data = data
      @ref_num = 512
      @dx = options[:dx]
      @dy = options[:dy]
      @dz = options[:dz]
      @numx = options[:numx] || @ref_num
      @numy = options[:numy] || @ref_num
      @numz = options[:numz] || @ref_num
      @max_output_level = options[:max] || 1.0
    end

    def view(axis)
      case axis
      when Z_AXIS
        d = @dz
        num = @numz
      when Y_AXIS
        d = @dy
        num = @numy
      when X_AXIS
        d = @dx
        num = @numx
      end

      s = @data.sum(axis)
      s.div! s.max if SUM_NORMALIZATION
      s.mul! -d*@ref_num/num
      s = NMath.exp(s)

      if IMAGE_GAMMA
        s.mul! -1
        s.add! 1
        s = power(s, IMAGE_GAMMA)
        contrast! s, IMAGE_CONTRAST if IMAGE_CONTRAST
        s.mul! @max_output_level if @max_output_level != 1
      elsif IMAGE_ADJUSTMENT
        s = adjust(s)
        contrast! s, IMAGE_CONTRAST if IMAGE_CONTRAST
        s.mul! @max_output_level if @max_output_level != 1
      else
        # since contrast is vertically symmetrical we can apply it
        # to the negative image
        contrast! s, IMAGE_CONTRAST if IMAGE_CONTRAST
        s.mul! -@max_output_level
        s.add! @max_output_level
      end
      s
    end

    private

    def contrast!(data, factor)
      # We use this piecewise sigmoid function:
      #
      # * f(x)       for x <= 1/2
      # * 1 - f(1-x) for x > 1/2
      #
      # With f(x) = pow(2, factor-1)*pow(x, factor)
      # The pow() function will be computed as:
      # pow(x, y) = exp(y*log(x))
      #
      # TODO: consider this alternative:
      # f(x) = (factor*x - x)/(2*factor*x - factor - 1
      #)
      factor = factor.round
      k = 2**(factor-1)
      lo = data <= 0.5
      hi = data >  0.5
      data[lo] = NMath.exp(factor*NMath.log(data[lo]))*k
      data[hi] = (-NMath.exp(NMath.log((-data[hi]) + 1)*factor))*k+1
      data
    end

    def power(data, factor)
      NMath.exp(factor*NMath.log(data))
    end

    def adjust(pixels)
      min = pixels.min
      max = pixels.max
      avg = pixels.mean
      # pixels.sbt! min
      # pixels.mul! 1.0/(max - min)
      pixels.sbt! max
      pixels.div! min - max

      # HUM: target 0.7; frac: target 0.2
      discriminator = (pixels > 0.83).count_true.to_f / (pixels > 0.5).count_true.to_f

      avg_target = 1.0 - discriminator**0.9
      x0 = 0.67
      y0 = 0.72
      gamma = 3.0
      k = - x0**gamma/Math.log(1-y0)
      avg_target = 1.0 - Math.exp(-avg_target**gamma/k)

      if avg_target > 0
        g = Math.log(avg_target)/Math.log(avg)
        power(pixels, g)
      else
        pixels
      end
    end
  end

end
