# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

unless file_loaded?(__FILE__)
  extension = SketchupExtension.new('Vías Topográficas', 'skp_topo_vias/main')
  extension.description = 'Herramientas para generar vías topográficas sobre una malla de terreno.'
  extension.version = '0.2.0'
  extension.creator = 'Vías Topográficas'
  Sketchup.register_extension(extension, true)
  file_loaded(__FILE__)
end
