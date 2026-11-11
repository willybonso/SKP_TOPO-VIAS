# frozen_string_literal: true

require 'set'

module TopoVias
  module TerrainAdapter
    extend self

    MATCH_TOLERANCE = 1.0
    GRID_SIZE = 100.0

    def trim_and_stitch(model, terrain, analysis, parameters, frame, slope_group)
      stations = analysis[:stations]
      closed = analysis[:closed]
      half_width = RoadGenerator.meters_to_inches(parameters['road_width_m'].to_f) / 2.0
      sidewalk_width = RoadGenerator.meters_to_inches(parameters['sidewalk_width_m'].to_f)
      slope_width = RoadGenerator.meters_to_inches(parameters['slope_width_m'].to_f)
      outer_offset = half_width + sidewalk_width + slope_width
      validate_clearance!(stations, closed, half_width * 2.0)

      left_path = frame.map { |station| RoadGenerator.offset_point(station, 1, outer_offset, boundary_z(station, 1, slope_width)) }
      right_path = frame.map { |station| RoadGenerator.offset_point(station, -1, outer_offset, boundary_z(station, -1, slope_width)) }
      region = build_region(left_path, right_path, closed)
      cutter = model.entities.add_group
      create_cutter_walls(cutter.entities, left_path, right_path, closed, terrain.bounds)
      raise ArgumentError, 'No se pudo construir la huella de corte del terreno.' if cutter.entities.grep(Sketchup::Face).empty?

      terrain_to_cutter = cutter.transformation.inverse * terrain.transformation
      cut_edges = terrain.entities.intersect_with(
        false,
        terrain_to_cutter,
        terrain.entities,
        terrain_to_cutter,
        true,
        cutter.entities.to_a
      )
      cut_edges = Array(cut_edges).select { |edge| edge.valid? }
      raise ArgumentError, 'Las superficies de corte no intersectaron la malla del terreno. Verifica que el eje y su huella estén sobre el terreno.' if cut_edges.empty?

      faces_to_remove = terrain.entities.grep(Sketchup::Face).select do |face|
        vertices = face.vertices.map { |vertex| terrain.transformation * vertex.position }
        center = Geom::Point3d.new(
          vertices.inject(0.0) { |sum, point| sum + point.x } / vertices.length,
          vertices.inject(0.0) { |sum, point| sum + point.y } / vertices.length,
          vertices.inject(0.0) { |sum, point| sum + point.z } / vertices.length
        )
        inside_region?(center, region)
      end
      if faces_to_remove.empty?
        raise ArgumentError, 'La huella no cubre caras del terreno; no se modificó la malla.'
      end
      terrain.entities.erase_entities(faces_to_remove)

      stitched_faces = 0
      matched_edges = 0
      if slope_width.positive?
        stitch_result = stitch_cut_edges(cut_edges, terrain, frame, slope_group, closed, outer_offset)
        stitched_faces = stitch_result[:faces]
        matched_edges = stitch_result[:matched_edges]
        if matched_edges.zero?
          raise ArgumentError, 'Se recortó el terreno, pero no se pudo encontrar el borde de corte para coserlo con el talud.'
        end
      end

      cutter.erase!
      { removed_faces: faces_to_remove.length, cut_edges: cut_edges.length, stitched_faces: stitched_faces, matched_edges: matched_edges }
    end

    def validate_clearance!(stations, closed, road_width)
      return if road_width <= 0.0 || stations.length < 4

      segment_count = closed ? stations.length : stations.length - 1
      segments = segment_count.times.map do |index|
        following = (index + 1) % stations.length
        [
          [stations[index][:x], stations[index][:y]],
          [stations[following][:x], stations[following][:y]]
        ]
      end
      local_gap = [(road_width / AxisEngine::SAMPLE_SPACING).ceil * 2, 3].max
      buckets = Hash.new { |hash, key| hash[key] = [] }
      candidates = Set.new

      segments.each_with_index do |segment, index|
        a, b = segment
        min_x = [a[0], b[0]].min - road_width
        max_x = [a[0], b[0]].max + road_width
        min_y = [a[1], b[1]].min - road_width
        max_y = [a[1], b[1]].max + road_width
        cells(min_x, max_x, min_y, max_y, road_width).each do |cell|
          buckets[cell].each do |other|
            gap = (index - other).abs
            gap = [gap, segment_count - gap].min if closed
            next if gap <= local_gap && same_local_course?(segments[other], segment, gap)

            candidates << [other, index]
          end
          buckets[cell] << index
        end
      end

      candidates.each do |first_index, second_index|
        distance = segment_distance(segments[first_index][0], segments[first_index][1], segments[second_index][0], segments[second_index][1])
        if distance <= road_width
          raise ArgumentError, 'Hay tramos del eje demasiado próximos: la separación es menor o igual al ancho de calle. Ajusta el trazado antes de generar la vía.'
        end
      end
    end

    def build_region(left_path, right_path, closed)
      if closed
        left_area = polygon_area(left_path)
        right_area = polygon_area(right_path)
        raise ArgumentError, 'La huella del circuito se cruza o colapsa. Revisa el radio de las curvas.' if (left_area - right_area).abs < 1.0

        validate_ring_paths!([left_path, right_path])
        outer, inner = left_area.abs > right_area.abs ? [left_path, right_path] : [right_path, left_path]
        { closed: true, outer: outer, inner: inner }
      else
        polygon = left_path + right_path.reverse
        raise ArgumentError, 'La huella abierta del eje tiene área nula o se autointersecta.' if polygon_area(polygon).abs < 1.0

        validate_ring_paths!([polygon])
        { closed: false, polygon: polygon }
      end
    end

    def validate_ring_paths!(rings)
      records = []
      rings.each_with_index do |ring, ring_index|
        segment_count(ring, true).times do |index|
          following = (index + 1) % ring.length
          records << {
            ring: ring_index,
            index: index,
            count: ring.length,
            a: [ring[index].x, ring[index].y],
            b: [ring[following].x, ring[following].y]
          }
        end
      end
      buckets = Hash.new { |hash, key| hash[key] = [] }
      pairs = Set.new
      records.each_with_index do |record, record_index|
        cells(
          [record[:a][0], record[:b][0]].min,
          [record[:a][0], record[:b][0]].max,
          [record[:a][1], record[:b][1]].min,
          [record[:a][1], record[:b][1]].max,
          GRID_SIZE
        ).each do |cell|
          buckets[cell].each do |other_index|
            other = records[other_index]
            if other[:ring] == record[:ring]
              gap = (record[:index] - other[:index]).abs
              gap = [gap, record[:count] - gap].min
              next if gap <= 1
            end
            pairs << [other_index, record_index]
          end
          buckets[cell] << record_index
        end
      end

      crossed = pairs.any? do |first, second|
        a = records[first]
        b = records[second]
        segments_intersect?(a[:a], a[:b], b[:a], b[:b])
      end
      raise ArgumentError, 'La huella exterior del talud se autointersecta; corrige el eje o reduce el ancho de talud.' if crossed
    end

    def create_cutter_walls(entities, left_path, right_path, closed, bounds)
      margin = [bounds.diagonal * 0.1, 1000.0].max
      bottom = bounds.min.z - margin
      top = bounds.max.z + margin
      [left_path, right_path].each do |path|
        segment_count(path, closed).times do |index|
          following = (index + 1) % path.length
          add_wall_quad(entities, path[index], path[following], bottom, top)
        end
      end
      unless closed
        add_wall_quad(entities, left_path.first, right_path.first, bottom, top)
        add_wall_quad(entities, right_path.last, left_path.last, bottom, top)
      end
    end

    def add_wall_quad(entities, a, b, bottom, top)
      a_low = Geom::Point3d.new(a.x, a.y, bottom)
      b_low = Geom::Point3d.new(b.x, b.y, bottom)
      b_high = Geom::Point3d.new(b.x, b.y, top)
      a_high = Geom::Point3d.new(a.x, a.y, top)
      add_triangle(entities, a_low, b_low, b_high)
      add_triangle(entities, a_low, b_high, a_high)
    end

    def add_triangle(entities, a, b, c)
      return if triangle_area_squared(a, b, c) < 1.0e-10

      entities.add_face([a, b, c])
    end

    def inside_region?(point, region)
      if region[:closed]
        point_in_polygon?(point, region[:outer]) && !point_in_polygon?(point, region[:inner])
      else
        point_in_polygon?(point, region[:polygon])
      end
    end

    def point_in_polygon?(point, polygon)
      x = point.x
      y = point.y
      inside = false
      polygon.each_index do |index|
        a = polygon[index]
        b = polygon[(index + 1) % polygon.length]
        return true if point_segment_distance([x, y], [a.x, a.y], [b.x, b.y]) < 1.0e-5

        if (a.y > y) != (b.y > y)
          cross_x = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
          inside = !inside if x < cross_x
        end
      end
      inside
    end

    def stitch_cut_edges(cut_edges, terrain, frame, slope_group, closed, outer_offset)
      records = boundary_segments(frame, closed, outer_offset)
      buckets = Hash.new { |hash, key| hash[key] = [] }
      records.each do |record|
        a = record[:a]
        b = record[:b]
        cells(
          [a.x, b.x].min - MATCH_TOLERANCE,
          [a.x, b.x].max + MATCH_TOLERANCE,
          [a.y, b.y].min - MATCH_TOLERANCE,
          [a.y, b.y].max + MATCH_TOLERANCE,
          GRID_SIZE
        ).each { |cell| buckets[cell] << record }
      end

      initial_face_count = slope_group.entities.grep(Sketchup::Face).length
      matched_edges = 0
      cut_edges.each do |edge|
        next unless edge.valid? && edge.faces.length == 1

        a = terrain.transformation * edge.start.position
        b = terrain.transformation * edge.end.position
        midpoint = [(a.x + b.x) / 2.0, (a.y + b.y) / 2.0]
        record = (buckets[cell_key(midpoint[0], midpoint[1], GRID_SIZE)] || []).find do |candidate|
          segment_match?(a, b, candidate)
        end
        next unless record

        matched_edges += 1
        slope_a = boundary_point(a, record)
        slope_b = boundary_point(b, record)
        desired = Geom::Vector3d.new(record[:normal_x], record[:normal_y], 0)
        RoadGenerator.add_quad(slope_group.entities, a, b, slope_b, slope_a, desired)
      end
      {
        faces: slope_group.entities.grep(Sketchup::Face).length - initial_face_count,
        matched_edges: matched_edges
      }
    end

    def boundary_segments(frame, closed, outer_offset)
      segment_count(frame, closed).times.flat_map do |index|
        following = (index + 1) % frame.length
        [-1, 1].map do |side|
          first = frame[index]
          second = frame[following]
          {
            a: RoadGenerator.offset_point(first, side, outer_offset, first[:terrain_edges][side]),
            b: RoadGenerator.offset_point(second, side, outer_offset, second[:terrain_edges][side]),
            z_a: first[:terrain_edges][side],
            z_b: second[:terrain_edges][side],
            normal_x: side * first[:normal_x],
            normal_y: side * first[:normal_y]
          }
        end
      end
    end

    def segment_match?(a, b, record)
      start = [record[:a].x, record[:a].y]
      finish = [record[:b].x, record[:b].y]
      p1 = [a.x, a.y]
      p2 = [b.x, b.y]
      return false if point_segment_distance(p1, start, finish) > MATCH_TOLERANCE
      return false if point_segment_distance(p2, start, finish) > MATCH_TOLERANCE

      t1 = segment_parameter(p1, start, finish)
      t2 = segment_parameter(p2, start, finish)
      t1 >= -0.01 && t1 <= 1.01 && t2 >= -0.01 && t2 <= 1.01
    end

    def boundary_point(point, record)
      start = [record[:a].x, record[:a].y]
      finish = [record[:b].x, record[:b].y]
      t = [[segment_parameter([point.x, point.y], start, finish), 0.0].max, 1.0].min
      Geom::Point3d.new(point.x, point.y, record[:z_a] + (record[:z_b] - record[:z_a]) * t)
    end

    def boundary_z(station, side, slope_width)
      slope_width.positive? ? station[:terrain_edges][side] : station[:z]
    end

    def polygon_area(polygon)
      sum = 0.0
      polygon.each_index do |index|
        a = polygon[index]
        b = polygon[(index + 1) % polygon.length]
        sum += a.x * b.y - b.x * a.y
      end
      sum / 2.0
    end

    def segment_distance(a, b, c, d)
      return 0.0 if segments_intersect?(a, b, c, d)

      [
        point_segment_distance(a, c, d),
        point_segment_distance(b, c, d),
        point_segment_distance(c, a, b),
        point_segment_distance(d, a, b)
      ].min
    end

    def same_local_course?(first, second, gap)
      a, b = first
      c, d = second
      ux = b[0] - a[0]
      uy = b[1] - a[1]
      vx = d[0] - c[0]
      vy = d[1] - c[1]
      u_length = Math.sqrt(ux * ux + uy * uy)
      v_length = Math.sqrt(vx * vx + vy * vy)
      return false if u_length.zero? || v_length.zero?

      direction_dot = (ux * vx + uy * vy) / (u_length * v_length)
      return false if direction_dot < 0.5

      mid_dx = (c[0] + d[0] - a[0] - b[0]) / 2.0
      mid_dy = (c[1] + d[1] - a[1] - b[1]) / 2.0
      direction_x = (ux / u_length + vx / v_length)
      direction_y = (uy / u_length + vy / v_length)
      direction_length = Math.sqrt(direction_x * direction_x + direction_y * direction_y)
      return false if direction_length.zero?

      along = (mid_dx * direction_x + mid_dy * direction_y).abs / direction_length
      lateral = (mid_dx * direction_y - mid_dy * direction_x).abs / direction_length
      along >= gap * AxisEngine::SAMPLE_SPACING * 0.5 && lateral < along * 0.35
    end

    def segments_intersect?(a, b, c, d)
      o1 = cross(a, b, c)
      o2 = cross(a, b, d)
      o3 = cross(c, d, a)
      o4 = cross(c, d, b)
      o1 * o2 <= 1.0e-8 && o3 * o4 <= 1.0e-8 &&
        [a[0], b[0]].min - 1.0e-5 <= [c[0], d[0]].max && [c[0], d[0]].min - 1.0e-5 <= [a[0], b[0]].max &&
        [a[1], b[1]].min - 1.0e-5 <= [c[1], d[1]].max && [c[1], d[1]].min - 1.0e-5 <= [a[1], b[1]].max
    end

    def point_segment_distance(point, start, finish)
      dx = finish[0] - start[0]
      dy = finish[1] - start[1]
      length_squared = dx * dx + dy * dy
      return Math.sqrt((point[0] - start[0])**2 + (point[1] - start[1])**2) if length_squared.zero?

      t = segment_parameter(point, start, finish)
      t = [[t, 0.0].max, 1.0].min
      px = start[0] + t * dx
      py = start[1] + t * dy
      Math.sqrt((point[0] - px)**2 + (point[1] - py)**2)
    end

    def segment_parameter(point, start, finish)
      dx = finish[0] - start[0]
      dy = finish[1] - start[1]
      length_squared = dx * dx + dy * dy
      return 0.0 if length_squared.zero?

      ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length_squared
    end

    def cross(a, b, c)
      (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    end

    def triangle_area_squared(a, b, c)
      ab = a.vector_to(b)
      ac = a.vector_to(c)
      cross_product = ab.cross(ac)
      cross_product.length**2
    end

    def segment_count(path, closed)
      closed ? path.length : path.length - 1
    end

    def cells(min_x, max_x, min_y, max_y, size)
      result = []
      (min_x / size).floor.upto((max_x / size).floor) do |x|
        (min_y / size).floor.upto((max_y / size).floor) { |y| result << [x, y] }
      end
      result
    end

    def cell_key(x, y, size)
      [(x / size).floor, (y / size).floor]
    end
  end
end
