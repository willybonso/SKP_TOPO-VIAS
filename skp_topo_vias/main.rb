# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require_relative 'axis_engine'
require_relative 'road_generator'

module TopoVias
  module Plugin
    extend self

    ROOT = File.dirname(__FILE__)

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
      analysis = AxisEngine.analyze(
        Sketchup.active_model,
        selected[:terrain_group],
        selected[:axis_group],
        data['max_grade_percent']
      )
      groups = RoadGenerator.generate(
        Sketchup.active_model,
        selected[:terrain_group],
        analysis,
        data
      )
      @last_parameters = data
      @last_analysis = analysis
      @last_output_groups = groups
      kind = analysis[:closed] ? 'circuito cerrado' : 'tramo abierto'
      grade_note = analysis[:monotonic_exception] ? ' Se permitió superar la pendiente máxima por el descenso monotónico entre extremos.' : ' Se aplicó el límite de pendiente.'
      message = "TOPO_ROAD generado (#{kind}): #{(analysis[:length] / AxisEngine::INCHES_PER_METER).round(1)} m, #{analysis[:station_count]} estaciones y 4 grupos creados: Vía, Acera, Bordillo y Talud. Pendiente máxima calculada: #{analysis[:max_grade_percent].round(2)} %.#{grade_note}"
      @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: true, message: message, parameters: data)});")
    rescue JSON::ParserError
      @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: false, message: 'No se pudieron leer los parámetros del formulario.' )});")
    rescue AxisEngine::AnalysisError => error
      @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: false, message: error.message)});")
    rescue StandardError => error
      message = "Error al analizar el modelo: #{error.message}"
      @dialog.execute_script("window.parameterResult(#{JSON.generate(ok: false, message: message)});")
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
