require 'histogram/narray'

class DicomS
  def histogram(dicom_directory, options = {})
    bins, freqs = compute_histogram(dicom_directory, options)
    print_histogram bins, freqs, options
  end

  def compute_histogram(dicom_directory, options = {})
    sequence = Sequence.new(dicom_directory)
    bin_width = options[:bin_width]

    if sequence.size == 1
      data = sequence.first.narray
    else
      maxx = sequence.metadata.nx
      maxy = sequence.metadata.ny
      maxz = sequence.metadata.nz
      data = NArray.sfloat(maxx, maxy, maxz)
      sequence.each do |dicom, z, file|
        data[true, true, z] = sequence.dicom_pixels(dicom)
      end
    end
    bins, freqs = data.histogram(:scott, :bin_boundary => :min, bin_width: bin_width)
    [bins, freqs]
  end

  def print_histogram(bins, freqs, options = {})
    compact = options[:compact]
    bin_labels = bins.to_a.map { |v| v.round.to_s }
    label_width = bin_labels.map(&:size).max
    sep = ": "
    bar_width  = terminal_size.last.to_i - label_width - sep.size
    div = [1, freqs.max / bar_width.to_f].max
    compact = true
    empty = false
    bin_labels.zip(freqs.to_a).each do |bin, freq|
      rep = ((freq/div).round)
      if compact && rep == 0
        unless empty
          puts "%#{label_width}s" % ['...']
          empty = true
        end
        next
      end
      puts "%#{label_width}s#{sep}%-#{bar_width}s" % [bin, '#'*rep]
      empty = false
    end
  end
end
