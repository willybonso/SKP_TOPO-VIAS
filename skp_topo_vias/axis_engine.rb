# frozen_string_literal: true

module TopoVias
  module AxisEngine
    extend self

    class AnalysisError < StandardError; end

    INCHES_PER_METER = 39.37007874015748
    SAMPLE_SPACING = INCHES_PER_METER
    GRADE_EPSILON = 1.0e-5

    class TerrainSampler
      EDGE_SNAP_TOLERANCE = 9.842519685 # 0.25 m in SketchUp inches

      def initialize(terrain)
        @triangles = []
        @grid = Hash.new { |hash, key| hash[key] = [] }
        @terrain_bounds = bounds_data(terrain.bounds)
        @cell_size = [[terrain.bounds.diagonal / 40.0, 100.0].max, 1000.0].min
        collect_faces(terrain.entities, terrain.transformation).each do |face, transform|
          mesh = face.mesh(0)
          mesh.polygons.each do |polygon|
            points = polygon.map { |index| transform * mesh.point_at(index.abs) }
            next if points.length < 3

            (1...(points.length - 1)).each do |index|
              triangle = [points[0], points[index], points[index + 1]]
              next if projected_area_twice(triangle).abs < 1.0e-8

              triangle_id = @triangles.length
              @triangles << triangle
              min_x = triangle.map(&:x).min
              max_x = triangle.map(&:x).max
              min_y = triangle.map(&:y).min
              max_y = triangle.map(&:y).max
              (min_x / @cell_size).floor.upto((max_x / @cell_size).floor) do |cell_x|
                (min_y / @cell_size).floor.upto((max_y / @cell_size).floor) do |cell_y|
                  @grid[[cell_x, cell_y]] << triangle_id
                end
              end
            end
          end
        end
        raise AnalysisError, 'El grupo de terreno no contiene una malla de caras proyectable en planta.' if @triangles.empty?
      end

      def elevation_at(point, strict: true)
        cell_x = (point.x / @cell_size).floor
        cell_y = (point.y / @cell_size).floor
        candidates = {}
        (-1..1).each do |dx|
          (-1..1).each do |dy|
            (@grid[[cell_x + dx, cell_y + dy]] || []).each { |id| candidates[id] = true }
          end
        end

        elevations = candidates.keys.map { |id| interpolated_z(@triangles[id], point.x, point.y) }.compact
        if elevations.empty? && strict
          # SketchUp linework often sits a few millimetres outside an irregular
          # mesh boundary. Snap only that small XY error to the nearest edge.
          snapped = candidates.keys.filter_map do |id|
            nearest_z_on_triangle_edge(@triangles[id], point.x, point.y)
          end
          elevations = snapped unless snapped.empty?
        end
        if elevations.empty?
          terrain_bounds = @terrain_bounds
          triangle_count = @triangles.length
          cell_size = @cell_size
          candidate_count = candidates.length
          snapped_count = snapped&.length || 0
          error = AnalysisError.new(
            "No se encontró terreno bajo una estación del eje (X=#{point.x.round(2)}, Y=#{point.y.round(2)} pulgadas). " \
            'El eje y el terreno deben coincidir en planta y estar dentro del contorno de la malla.'
          )
          error.define_singleton_method(:diagnostics) do
            {
              station_xy_in: [point.x, point.y],
              terrain_bounds: terrain_bounds,
              terrain_triangle_count: triangle_count,
              spatial_cell_size_in: cell_size,
              nearby_triangle_candidates: candidate_count,
              snapped_triangles_within_tolerance: snapped_count
            }
          end
          raise error
        end
        return nil if elevations.empty?

        elevations.max
      end

      private

      def projected_area_twice(triangle)
        a, b, c = triangle
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
      end

      def collect_faces(entities, transform, result = [])
        entities.each do |entity|
          case entity
          when Sketchup::Face
            result << [entity, transform]
          when Sketchup::Group
            collect_faces(entity.entities, transform * entity.transformation, result)
          when Sketchup::ComponentInstance
            collect_faces(entity.definition.entities, transform * entity.transformation, result)
          end
        end
        result
      end

      def bounds_data(bounds)
        { min: bounds.min.to_a, max: bounds.max.to_a }
      end

      def interpolated_z(triangle, x, y)
        a, b, c = triangle
        denominator = projected_area_twice(triangle)
        return nil if denominator.abs < 1.0e-10

        weight_a = ((b.x - x) * (c.y - y) - (b.y - y) * (c.x - x)) / denominator
        weight_b = ((c.x - x) * (a.y - y) - (c.y - y) * (a.x - x)) / denominator
        weight_c = 1.0 - weight_a - weight_b
        tolerance = 1.0e-8
        return nil if [weight_a, weight_b, weight_c].any? { |weight| weight < -tolerance || weight > 1.0 + tolerance }

        weight_a * a.z + weight_b * b.z + weight_c * c.z
      end

      def nearest_z_on_triangle_edge(triangle, x, y)
        a, b, c = triangle
        denominator = projected_area_twice(triangle)
        return nil if denominator.abs < 1.0e-10

        wa = ((b.x - x) * (c.y - y) - (b.y - y) * (c.x - x)) / denominator
        wb = ((c.x - x) * (a.y - y) - (c.y - y) * (a.x - x)) / denominator
        weights = [wa, wb, 1.0 - wa - wb].map { |weight| [weight, 0.0].max }
        total = weights.sum
        return nil if total.zero?

        weights.map! { |weight| weight / total }
        projected_x = weights[0] * a.x + weights[1] * b.x + weights[2] * c.x
        projected_y = weights[0] * a.y + weights[1] * b.y + weights[2] * c.y
        distance = Math.hypot(projected_x - x, projected_y - y)
        return nil if distance > EDGE_SNAP_TOLERANCE

        weights[0] * a.z + weights[1] * b.z + weights[2] * c.z
      end
    end

    def analyze(terrain, axis, max_grade_percent, corridor_half_width = 0.0)
      axis_points, closed = ordered_axis_points(axis)
      curve = sample_curve(axis_points, closed)
      raise AnalysisError, 'El eje es demasiado corto para generar estaciones.' if curve.length < 2

      terrain_sampler = TerrainSampler.new(terrain)
      original_length = path_length(curve, closed)
      trimmed = { start: false, end: false }
      unless closed
        curve, trimmed = trim_open_curve_to_terrain(curve, terrain_sampler, corridor_half_width)
      end
      raise AnalysisError, 'El tramo coincidente con el terreno es demasiado corto para generar la vía.' if curve.length < 2
      elevations = curve.map { |point| terrain_sampler.elevation_at(point) }
      smoothed = smooth_profile(elevations, closed)
      grade_limit = max_grade_percent.to_f / 100.0
      monotonic_exception = !closed && monotonic_downhill_profile?(smoothed) && exceeds_grade?(curve, smoothed, grade_limit)
      profile = monotonic_exception ? smoothed : limit_grade(curve, smoothed, closed, grade_limit)
      measured_grade = maximum_grade(curve, profile, closed) * 100.0

      stations = curve.each_with_index.map do |point, index|
        { x: point.x, y: point.y, ground_z: elevations[index], z: profile[index] }
      end
      {
        closed: closed,
        length: path_length(curve, closed),
        station_count: stations.length,
        max_grade_percent: measured_grade,
        grade_limit_percent: max_grade_percent.to_f,
        monotonic_exception: monotonic_exception,
        terrain_trimmed: trimmed,
        original_length: original_length,
        terrain_sampler: terrain_sampler,
        stations: stations
      }
    end

    def trim_open_curve_to_terrain(points, sampler, corridor_half_width)
      covered = points.each_with_index.map do |point, index|
        previous = points[[index - 1, 0].max]
        following = points[[index + 1, points.length - 1].min]
        corridor_covered?(point, previous, following, sampler, corridor_half_width)
      end
      runs = []
      covered.each_with_index do |is_covered, index|
        if is_covered
          runs << [index, index] if runs.empty? || runs[-1][1] != index - 1
          runs[-1][1] = index
        end
      end
      raise AnalysisError, 'La polilínea no intersecta en planta el terreno con el ancho completo de la sección vial.' if runs.empty?
      if runs.length > 1
        raise AnalysisError, 'El eje entra y sale varias veces del área topográfica. Divide el eje en tramos continuos dentro del terreno.'
      end

      first_index, last_index = runs.first
      start_trimmed = first_index.positive?
      end_trimmed = last_index < points.length - 1
      trimmed_points = points[first_index..last_index]
      if start_trimmed
        boundary = corridor_boundary(points[first_index - 1], points[first_index], sampler, corridor_half_width, entering: true)
        trimmed_points.unshift(boundary)
      end
      if end_trimmed
        boundary = corridor_boundary(points[last_index], points[last_index + 1], sampler, corridor_half_width, entering: false)
        trimmed_points << boundary
      end
      [trimmed_points, { start: start_trimmed, end: end_trimmed }]
    end

    def corridor_covered?(point, previous, following, sampler, half_width)
      return !sampler.elevation_at(point, strict: false).nil? if half_width <= 0.0

      dx = following.x - previous.x
      dy = following.y - previous.y
      length = Math.hypot(dx, dy)
      return false if length.zero?

      nx = -dy / length
      ny = dx / length
      center = Geom::Point3d.new(point.x, point.y, 0)
      [-1.0, 0.0, 1.0].all? do |side|
        sample = Geom::Point3d.new(center.x + nx * half_width * side, center.y + ny * half_width * side, 0)
        !sampler.elevation_at(sample, strict: false).nil?
      end
    end

    def corridor_boundary(outside, inside, sampler, half_width, entering:)
      low = 0.0
      high = 1.0
      32.times do
        middle = (low + high) / 2.0
        point = interpolate_point(outside, inside, middle)
        covered = corridor_covered?(point, outside, inside, sampler, half_width)
        if entering
          covered ? high = middle : low = middle
        else
          covered ? low = middle : high = middle
        end
      end
      interpolate_point(outside, inside, entering ? high : low)
    end

    def interpolate_point(a, b, t)
      Geom::Point3d.new(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t
      )
    end

    def ordered_axis_points(axis)
      edges = axis.entities.grep(Sketchup::Edge)
      raise AnalysisError, 'El grupo de eje no contiene aristas.' if edges.empty?

      adjacency = Hash.new { |hash, key| hash[key] = [] }
      points = {}
      transform = axis.transformation
      edges.each do |edge|
        a = edge.start
        b = edge.end
        points[a.entityID] = transform * a.position
        points[b.entityID] = transform * b.position
        adjacency[a.entityID] << [b.entityID, edge]
        adjacency[b.entityID] << [a.entityID, edge]
      end

      if adjacency.values.any? { |neighbors| neighbors.length > 2 }
        raise AnalysisError, 'El eje tiene ramificaciones o uniones en T. Usa una sola línea continua sin ramas.'
      end
      endpoints = adjacency.select { |_id, neighbors| neighbors.length == 1 }.keys
      closed = endpoints.empty?
      unless closed || endpoints.length == 2
        raise AnalysisError, 'El eje debe ser una sola cadena abierta o un circuito cerrado.'
      end

      seen = {}
      stack = [adjacency.keys.first]
      until stack.empty?
        current = stack.pop
        next if seen[current]

        seen[current] = true
        adjacency[current].each { |neighbor, _edge| stack << neighbor }
      end
      unless seen.length == adjacency.length
        raise AnalysisError, 'El grupo contiene más de una línea desconectada. Une todos los tramos del eje.'
      end

      start_id = closed ? adjacency.keys.min : endpoints.min
      ordered_ids = [start_id]
      visited_edges = {}
      current = start_id
      loop do
        step = adjacency[current].find { |_neighbor, edge| !visited_edges[edge.entityID] }
        break unless step

        neighbor, edge = step
        visited_edges[edge.entityID] = true
        break if closed && neighbor == start_id

        ordered_ids << neighbor
        current = neighbor
      end
      unless visited_edges.length == edges.length
        raise AnalysisError, 'No se pudo ordenar la topología completa del eje.'
      end
      [ordered_ids.map { |id| points.fetch(id) }, closed]
    end

    def sample_curve(points, closed)
      result = []
      segment_count = closed ? points.length : points.length - 1
      segment_count.times do |index|
        p1 = points[index]
        p2 = points[(index + 1) % points.length]
        p0 = closed ? points[(index - 1) % points.length] : points[[index - 1, 0].max]
        p3 = closed ? points[(index + 2) % points.length] : points[[index + 2, points.length - 1].min]
        span = horizontal_distance(p1, p2)
        steps = [(span / SAMPLE_SPACING).ceil, 1].max
        steps.times do |step|
          t = step.to_f / steps
          result << catmull_rom(p0, p1, p2, p3, t)
        end
      end
      result << points.last unless closed
      result
    end

    def catmull_rom(p0, p1, p2, p3, t)
      t2 = t * t
      t3 = t2 * t
      components = [0, 1].map do |axis|
        a = p0.to_a[axis]
        b = p1.to_a[axis]
        c = p2.to_a[axis]
        d = p3.to_a[axis]
        0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (-a + 3.0 * b - 3.0 * c + d) * t3)
      end
      Geom::Point3d.new(components[0], components[1], p1.z + (p2.z - p1.z) * t)
    end

    def smooth_profile(values, closed)
      return values.dup if values.length < 3

      values.each_index.map do |index|
        if !closed && (index.zero? || index == values.length - 1)
          values[index]
        else
          previous = values[(index - 1) % values.length]
          following = values[(index + 1) % values.length]
          (previous + 2.0 * values[index] + following) / 4.0
        end
      end
    end

    def monotonic_downhill_profile?(values)
      return false if values.length < 3

      tolerance = 0.01 * INCHES_PER_METER
      deltas = values.each_cons(2).map { |a, b| b - a }
      deltas.all? { |delta| delta <= tolerance } && values.first > values.last
    end

    def limit_grade(points, values, closed, limit)
      profile = values.dup
      if closed
        200.times do
          changed = false
          profile.each_index do |index|
            next_index = (index + 1) % profile.length
            distance = horizontal_distance(points[index], points[next_index])
            allowed = limit * distance
            delta = profile[next_index] - profile[index]
            if delta > allowed
              correction = (delta - allowed) / 2.0
              profile[index] += correction
              profile[next_index] -= correction
              changed = true
            elsif delta < -allowed
              correction = (-allowed - delta) / 2.0
              profile[index] -= correction
              profile[next_index] += correction
              changed = true
            end
          end
          break unless changed
        end
      else
        20.times do
          (1...profile.length).each do |index|
            allowed = limit * horizontal_distance(points[index - 1], points[index])
            profile[index] = [[profile[index], profile[index - 1] - allowed].max, profile[index - 1] + allowed].min
          end
          (0...(profile.length - 1)).to_a.reverse_each do |index|
            allowed = limit * horizontal_distance(points[index], points[index + 1])
            profile[index] = [[profile[index], profile[index + 1] - allowed].max, profile[index + 1] + allowed].min
          end
        end
      end

      if exceeds_grade?(points, profile, limit, closed, tolerance: GRADE_EPSILON)
        raise AnalysisError, 'La pendiente máxima no es compatible con el desnivel entre extremos del eje. Ajusta el límite o la rasante de referencia.'
      end
      profile
    end

    def exceeds_grade?(points, values, limit, closed = false, tolerance: 1.0e-8)
      maximum_grade(points, values, closed) > limit + tolerance
    end

    def maximum_grade(points, values, closed)
      segment_count = closed ? points.length : points.length - 1
      segment_count.times.map do |index|
        next_index = (index + 1) % points.length
        distance = horizontal_distance(points[index], points[next_index])
        distance.zero? ? 0.0 : (values[next_index] - values[index]).abs / distance
      end.max || 0.0
    end

    def path_length(points, closed)
      total = points.each_cons(2).inject(0.0) { |sum, pair| sum + horizontal_distance(pair[0], pair[1]) }
      total += horizontal_distance(points.last, points.first) if closed && points.length > 1
      total
    end

    def horizontal_distance(a, b)
      Math.sqrt((b.x - a.x)**2 + (b.y - a.y)**2)
    end
  end
end
