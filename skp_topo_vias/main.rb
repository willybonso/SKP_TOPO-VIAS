# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require 'time'
require_relative 'axis_engine'
require_relative 'road_generator'
require_relative 'terrain_adapter'

module TopoVias
  module Plugin
    extend self

    ROOT = File.dirname(__FILE__)
    VERSION = '0.4.9'
    DIAGNOSTIC_FILE = File.join(ENV['TEMP'] || ROOT, 'TOPO_ROAD_diagnostics.log')

    def open_dialog
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: 'TOPO_ROAD — Parámetros',
        preferences_key: 'topo_vias.parameters',
        scrollable: true,
        resizable: true,
        width: 470,
        height: 740,
        min_width: 420,
        min_height: 620,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(ROOT, 'ui', 'dialog.html'))
      @dialog.add_action_callback('check_selection') do |_context|
        @dialog.execute_script("window.selectionResult(#{JSON.generate(selection_result)});")
      end
      @dialog.add_action_callback('submit_parameters') do |_context, json|
        handle_parameters(json)
      end
      @dialog.set_on_closed { @dialog = nil }
      @dialog.show
    end

    def selection_result
      result = resolve_selection
      return result unless result[:ok]

      {
        ok: true,
        message: 'Selección válida.',
        terrain: entity_label(result[:terrain_group]),
        axis: entity_label(result[:axis_group])
      }
    end

    def resolve_selection
      selection = Sketchup.active_model.selection.to_a
      unless selection.length == 2
        return { ok: false, message: 'Selecciona exactamente dos grupos: terreno y eje.' }
      end

      unless selection.all? { |entity| entity.is_a?(Sketchup::Group) }
        return { ok: false, message: 'La selección debe contener exactamente dos grupos (no componentes ni entidades sueltas).' }
      end

      terrain_candidates = selection.select { |group| group.entities.any? { |entity| entity.is_a?(Sketchup::Face) } }
      axis_candidates = selection.select do |group|
        entities = group.entities.to_a
        entities.any? { |entity| entity.is_a?(Sketchup::Edge) } && entities.none? { |entity| entity.is_a?(Sketchup::Face) }
      end

      if terrain_candidates.length != 1 || axis_candidates.length != 1 || terrain_candidates.first == axis_candidates.first
        return { ok: false, message: 'No se pudo distinguir el terreno del eje. El terreno debe contener caras y el eje debe contener solo aristas.' }
      end

      { ok: true, terrain_group: terrain_candidates.first, axis_group: axis_candidates.first }
    end

    def entity_label(group)
      label = group.name.to_s.strip
      label.empty? ? "Grupo ##{group.entityID}" : label
    end

    def handle_parameters(json)
      selected = nil
      data = nil
      data = JSON.parse(json)
      unless valid_parameters?(data)
        @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: false, message: 'Revisa los valores numéricos del formulario.' )});")
        return
      end

      result = selection_result
      unless result[:ok]
        @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: false, message: result[:message])});")
        return
      end

      selected = resolve_selection
      corridor_half_width = (
        data['road_width_m'] / 2.0 + data['sidewalk_width_m'] + data['slope_width_m']
      ) * AxisEngine::INCHES_PER_METER
      analysis = AxisEngine.analyze(
        selected[:terrain_group],
        selected[:axis_group],
        data['max_grade_percent'],
        corridor_half_width
      )
      generated = RoadGenerator.generate(
        Sketchup.active_model,
        selected[:terrain_group],
        analysis,
        data
      )
      groups = generated[:groups]
      @last_parameters = data
      @last_analysis = analysis
      @last_output_groups = groups
      kind = analysis[:closed] ? 'circuito cerrado' : 'tramo abierto'
      grade_note = analysis[:monotonic_exception] ? ' Se permitió superar la pendiente máxima por el descenso monotónico entre extremos.' : ' Se aplicó el límite de pendiente.'
      terrain_note = "Terreno recortado: #{generated[:terrain_result][:removed_faces]} caras retiradas; costura de talud: #{generated[:terrain_result][:stitched_faces]} caras."
      trim_note = analysis[:terrain_trimmed].values.any? ? ' Se recortaron los extremos del eje al tramo donde cabe la sección completa dentro del terreno.' : ''
      message = "TOPO_ROAD generado (#{kind}): #{(analysis[:length] / AxisEngine::INCHES_PER_METER).round(1)} m, #{analysis[:station_count]} estaciones y 4 grupos: Vía, Acera, Bordillo y Talud. #{terrain_note} Pendiente máxima: #{analysis[:max_grade_percent].round(2)} %.#{grade_note}#{trim_note}"
      @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: true, message: message, parameters: data)});")
    rescue StandardError => error
      diagnostic_id, log_path = write_diagnostic(error, selected, data)
      message = "Error [#{diagnostic_id}]: #{error.message}. Diagnóstico guardado en: #{log_path}"
      @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: false, message: message)});")
    end

    def write_diagnostic(error, selected, data)
      diagnostic_id = "TR-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{rand(1000..9999)}"
      model = Sketchup.active_model
      axis_sampling = begin
        error.respond_to?(:diagnostics) ? error.diagnostics : nil
      rescue StandardError => diagnostic_error
        { diagnostic_collection_error: "#{diagnostic_error.class}: #{diagnostic_error.message}" }
      end
      report = {
        id: diagnostic_id,
        time: Time.now.iso8601,
        plugin_version: VERSION,
        error_class: error.class.name,
        error_message: error.message,
        backtrace: error.backtrace,
        axis_sampling: axis_sampling,
        parameters: data,
        selection: selected && {
          terrain: group_diagnostics(selected[:terrain_group]),
          axis: group_diagnostics(selected[:axis_group])
        },
        model_path: model.path
      }
      File.open(DIAGNOSTIC_FILE, 'a:utf-8') do |file|
        file.puts(JSON.pretty_generate(report))
        file.puts
      end
      [diagnostic_id, DIAGNOSTIC_FILE]
    rescue StandardError => log_error
      [diagnostic_id || 'TR-LOG-ERROR', "No se pudo escribir la bitácora: #{log_error.message}"]
    end

    def group_diagnostics(group)
      return nil unless group && group.valid?

      bounds = group.bounds
      {
        name: group.name,
        entity_id: group.entityID,
        transformation: group.transformation.to_a,
        transformation_translation_units: 'SketchUp internal units',
        bounds_units: 'm',
        bounds_min: bounds.min.to_a.map { |coordinate| coordinate / AxisEngine::INCHES_PER_METER },
        bounds_max: bounds.max.to_a.map { |coordinate| coordinate / AxisEngine::INCHES_PER_METER },
        direct_faces: group.entities.grep(Sketchup::Face).length,
        direct_edges: group.entities.grep(Sketchup::Edge).length,
        direct_groups: group.entities.grep(Sketchup::Group).length,
        direct_components: group.entities.grep(Sketchup::ComponentInstance).length
      }
    end

    def valid_parameters?(data)
      return false unless data.is_a?(Hash)

      road = data['road_width_m']
      sidewalk = data['sidewalk_width_m']
      height = data['sidewalk_height_m']
      slope = data['slope_width_m']
      curb_width = data['curb_width_m']
      grade = data['max_grade_percent']
      numbers = [road, sidewalk, height, slope, curb_width, grade]
      numbers.all? { |value| value.is_a?(Integer) || (value.is_a?(Float) && value.finite?) } &&
        road > 0 && sidewalk >= 0 && height >= 0 && slope >= 0 && curb_width >= 0 && grade > 0 && grade <= 100 &&
        [true, false].include?(data['curb_enabled'])
    end

    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu('TOPO_ROAD')
      menu.add_item('Configurar vía…') { open_dialog }
      toolbar = UI::Toolbar.new('TOPO_ROAD')
      command = UI::Command.new('Configurar TOPO_ROAD') { open_dialog }
      command.tooltip = 'Configurar y generar una vía topográfica'
      command.status_bar_text = 'Abre el formulario de parámetros y valida la selección.'
      toolbar.add_item(command)
      toolbar.restore
      file_loaded(__FILE__)
    end
  end
end
