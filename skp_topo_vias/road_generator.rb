# frozen_string_literal: true

module TopoVias
  module RoadGenerator
    extend self

    def generate(model, terrain, analysis, parameters)
      stations = analysis[:stations]
      closed = analysis[:closed]
      raise ArgumentError, 'No hay suficientes estaciones para generar la vía.' if stations.length < 2

      road_half = meters_to_inches(parameters['road_width_m'].to_f) / 2.0
      curb_width = parameters['curb_enabled'] ? meters_to_inches(parameters['curb_width_m'].to_f) : 0.0
      sidewalk_width = meters_to_inches(parameters['sidewalk_width_m'].to_f)
      sidewalk_height = meters_to_inches(parameters['sidewalk_height_m'].to_f)
      slope_width = meters_to_inches(parameters['slope_width_m'].to_f)
      if curb_width > sidewalk_width
        raise ArgumentError, 'El ancho de bordillo no puede superar el ancho de acera, porque está incluido en él.'
      end

      terrain_top = terrain.bounds.max.z
      terrain_margin = [terrain.bounds.diagonal * 0.1, 1000.0].max
      frame = build_station_frames(stations, closed)
      frame.each do |station|
        station[:terrain_edges] = {}
        next unless slope_width.positive?

        [-1, 1].each do |side|
          edge = offset_point(station, side, road_half + sidewalk_width + slope_width, station[:z])
          station[:terrain_edges][side] = AxisEngine.terrain_elevation(
            model,
            terrain,
            edge,
            terrain_top + terrain_margin
          )
        end
      end

      groups = nil
      model.start_operation('Generar vía TOPO_ROAD', true)
      begin
        road_group = model.entities.add_group
        sidewalk_group = model.entities.add_group
        curb_group = model.entities.add_group
        slope_group = model.entities.add_group
        road_group.name = 'Grupo de Vía'
        sidewalk_group.name = 'Grupo de Acera'
        curb_group.name = 'Grupo de Bordillo'
        slope_group.name = 'Grupo de Talud'

        segment_count(stations, closed).times do |index|
          next_index = (index + 1) % stations.length
          add_road_segment(road_group.entities, frame[index], frame[next_index], road_half)
          [-1, 1].each do |side|
            add_sidewalk_segment(
              sidewalk_group.entities,
              frame[index], frame[next_index], side, road_half,
              curb_width, sidewalk_width, sidewalk_height
            )
            if parameters['curb_enabled'] && curb_width.positive?
              add_curb_segment(
                curb_group.entities,
                frame[index], frame[next_index], side, road_half, curb_width, sidewalk_height
              )
            end
            if slope_width.positive?
              add_slope_segment(
                slope_group.entities,
                frame[index], frame[next_index], side, road_half, sidewalk_width,
                sidewalk_height, slope_width
              )
            end
          end
        end

        groups = [road_group, sidewalk_group, curb_group, slope_group]
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      model.selection.clear
      groups.each { |group| model.selection.add(group) }
      groups
    end

    def build_station_frames(stations, closed)
      stations.each_with_index.map do |station, index|
        if closed
          previous = stations[(index - 1) % stations.length]
          following = stations[(index + 1) % stations.length]
        else
          previous = stations[[index - 1, 0].max]
          following = stations[[index + 1, stations.length - 1].min]
        end
        dx = following[:x] - previous[:x]
        dy = following[:y] - previous[:y]
        length = Math.sqrt(dx * dx + dy * dy)
        raise ArgumentError, 'El eje tiene estaciones consecutivas sin dirección horizontal.' if length < 1.0e-8

        {
          x: station[:x], y: station[:y], z: station[:z],
          normal_x: -dy / length, normal_y: dx / length
        }
      end
    end

    def add_road_segment(entities, first, second, half_width)
      left_first = offset_point(first, 1, half_width, first[:z])
      left_second = offset_point(second, 1, half_width, second[:z])
      right_first = offset_point(first, -1, half_width, first[:z])
      right_second = offset_point(second, -1, half_width, second[:z])
      add_quad(entities, left_first, left_second, right_second, right_first, Geom::Vector3d.new(0, 0, 1))
    end

    def add_sidewalk_segment(entities, first, second, side, road_half, curb_width, sidewalk_width, height)
      inner = road_half + (curb_width > 0 ? curb_width : 0.0)
      outer = road_half + sidewalk_width
      return if outer - inner < 1.0e-6

      points = [
        offset_point(first, side, inner, first[:z] + height),
        offset_point(second, side, inner, second[:z] + height),
        offset_point(second, side, outer, second[:z] + height),
        offset_point(first, side, outer, first[:z] + height)
      ]
      add_quad(entities, *points, Geom::Vector3d.new(0, 0, 1))
    end

    def add_curb_segment(entities, first, second, side, road_half, curb_width, height)
      inner_first = offset_point(first, side, road_half, first[:z])
      inner_second = offset_point(second, side, road_half, second[:z])
      inner_top_first = offset_point(first, side, road_half, first[:z] + height)
      inner_top_second = offset_point(second, side, road_half, second[:z] + height)
      outer_first = offset_point(first, side, road_half + curb_width, first[:z])
      outer_second = offset_point(second, side, road_half + curb_width, second[:z])
      outer_top_first = offset_point(first, side, road_half + curb_width, first[:z] + height)
      outer_top_second = offset_point(second, side, road_half + curb_width, second[:z] + height)

      add_quad(entities, inner_top_first, inner_top_second, outer_top_second, outer_top_first, Geom::Vector3d.new(0, 0, 1))
      inward = Geom::Vector3d.new(-side * first[:normal_x], -side * first[:normal_y], 0)
      outward = Geom::Vector3d.new(side * first[:normal_x], side * first[:normal_y], 0)
      add_quad(entities, inner_first, inner_top_first, inner_top_second, inner_second, inward)
      add_quad(entities, outer_first, outer_second, outer_top_second, outer_top_first, outward)
    end

    def add_slope_segment(entities, first, second, side, road_half, sidewalk_width, sidewalk_height, slope_width)
      outer_offset = road_half + sidewalk_width + slope_width
      start_first = offset_point(first, side, road_half + sidewalk_width, first[:z] + sidewalk_height)
      start_second = offset_point(second, side, road_half + sidewalk_width, second[:z] + sidewalk_height)
      end_first = offset_point(first, side, outer_offset, first[:terrain_edges][side])
      end_second = offset_point(second, side, outer_offset, second[:terrain_edges][side])
      normal = Geom::Vector3d.new(side * first[:normal_x], side * first[:normal_y], 0)
      add_quad(entities, start_first, start_second, end_second, end_first, normal)
    end

    def add_quad(entities, a, b, c, d, desired_normal)
      add_triangle(entities, a, b, c, desired_normal)
      add_triangle(entities, a, c, d, desired_normal)
    end

    def add_triangle(entities, a, b, c, desired_normal)
      face = entities.add_face([a, b, c])
      return unless face

      face.reverse! if face.normal.dot(desired_normal) < 0
      face
    end

    def offset_point(frame, side, offset, z)
      Geom::Point3d.new(
        frame[:x] + frame[:normal_x] * side * offset,
        frame[:y] + frame[:normal_y] * side * offset,
        z
      )
    end

    def segment_count(stations, closed)
      closed ? stations.length : stations.length - 1
    end

    def meters_to_inches(meters)
      meters * AxisEngine::INCHES_PER_METER
    end
  end
end
