# frozen_string_literal: true

module TopoVias
  module AxisEngine
    extend self

    class AnalysisError < StandardError; end

    INCHES_PER_METER = 39.37007874015748
    SAMPLE_SPACING = INCHES_PER_METER
    GRADE_EPSILON = 1.0e-5

    def analyze(model, terrain, axis, max_grade_percent)
      axis_points, closed = ordered_axis_points(axis)
      curve = sample_curve(axis_points, closed)
      raise AnalysisError, 'El eje es demasiado corto para generar estaciones.' if curve.length < 2

      terrain_top = terrain.bounds.max.z
      margin = [terrain.bounds.diagonal * 0.1, 1000.0].max
      elevations = curve.map { |point| terrain_elevation(model, terrain, point, terrain_top + margin) }
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
        stations: stations
      }
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

    def terrain_elevation(model, terrain, point, start_z)
      ray = [Geom::Point3d.new(point.x, point.y, start_z), Geom::Vector3d.new(0, 0, -1)]
      hit = model.raytest(ray, false)
      unless hit && hit[1].include?(terrain)
        raise AnalysisError, 'No se pudo proyectar todo el eje sobre el grupo de terreno. Revisa que el terreno cubra el eje y que no haya geometría encima.'
      end
      hit[0].z
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
            distance = points[index].distance(points[next_index])
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
