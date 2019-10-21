# frozen_string_literal: true

require 'mini_magick'
require 'mechanize'

module ActiveShipping
  class Label
    attr_reader :img_data
    attr_accessor :tracking_number, :path, :carrier, :plates, :file_type

    def initialize(tracking_number, img_data)
      @tracking_number = tracking_number
      @img_data = img_data
    end

    # Handles the label to normalize, write
    def handle(carrier, file_type)
      @carrier = carrier
      # Search a path
      pathfind(file_type)

      # Prepare and write out data
      if @img_data.is_a? Prawn::Document
        @img_data.render_file(@path)
      elsif @img_data.is_a? Mechanize::File
        @img_data.save_as(@path)
      elsif @img_data.is_a?(String) && @img_data.include?(Rails.root.to_s)
        FileUtils.mv(@img_data, pathfind(@img_data[/\w+$/]))
      else
        normalize(file_type)
        write_out
      end
    end

    private

    # Normalizes the label image
    def normalize(file_type)
      return @img_data if file_type == 'pdf'

      label_image = MiniMagick::Image.read(@img_data)
      label_image.combine_options do |img|
        img.rotate(90) if label_image.width > label_image.height
        img.rotate(180) if [:fedex].include?(@carrier)
        img.bordercolor('#ffffff')
        img.border('1x1')
        img.trim
      end

      @img_data = label_image.to_blob
    end

    # Creates the path for label image
    def pathfind(file_type)
      image_directory = Rails.root.join('public', 'system', 'shipping_labels', @carrier.to_s)

      FileUtils.mkdir_p(image_directory)
      @path = File.join(image_directory, "#{tracking_number}.#{file_type}")
    end

    # Writes out the label image
    def write_out
      File.delete(@path) if File.exist?(@path)
      File.open(@path, mode: 'w', encoding: @img_data.encoding) { |f| f.write(@img_data) }
    end
  end
end
