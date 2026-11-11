# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

unless file_loaded?(__FILE__)
  extension = SketchupExtension.new('TOPO_ROAD', 'skp_topo_vias/main')
  extension.description = 'Genera geometría vial sobre una malla topográfica.'
  extension.version = '0.4.2'
  extension.creator = 'TOPO_ROAD'
  Sketchup.register_extension(extension, true)
  file_loaded(__FILE__)
end
