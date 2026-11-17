import simd

/// A triangle mesh for a scene's static world, built in code. Shapes stand on the origin or are
/// centered on it; place them with `transformed(_:)` or the transforms given to `SaverWorld.add`.
struct Mesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// Coordinates across the surface, as `h.uv`: parametric shapes run 0 to 1 over i and j; empty
    /// for none, which reads as zero.
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    static func + (a: Mesh, b: Mesh) -> Mesh {
        var mesh = a
        mesh += b
        return mesh
    }

    static func += (a: inout Mesh, b: Mesh) {
        let base = UInt32(a.positions.count)
        if !a.uvs.isEmpty || !b.uvs.isEmpty {
            a.uvs += Array(repeating: .zero, count: a.positions.count - a.uvs.count)
            a.uvs += b.uvs + Array(repeating: .zero, count: b.positions.count - b.uvs.count)
        }
        a.positions += b.positions
        a.normals += b.normals
        a.indices += b.indices.map { $0 + base }
    }
}

// MARK: Shapes

extension Mesh {
    /// A surface through `point(i, j)` for i in 0...columns and j in 0...rows, its front facing
    /// the way of cross(∂i, ∂j). `wrap` joins row `rows` back onto row 0, so j stops before it.
    static func parametric(_ columns: Int, _ rows: Int, wrap: Bool = false, _ point: (Int, Int) -> SIMD3<Float>) -> Mesh {
        let ring = wrap ? rows : rows + 1
        var mesh = Mesh()
        mesh.positions.reserveCapacity((columns + 1) * ring)
        for i in 0...columns {
            for j in 0..<ring {
                mesh.positions.append(point(i, j))
                mesh.uvs.append(SIMD2(Float(i) / Float(columns), Float(j) / Float(rows)))
            }
        }
        mesh.indices.reserveCapacity(columns * rows * 6)
        for i in 0..<columns {
            for j in 0..<rows {
                let a = UInt32(i * ring + j), b = UInt32((i + 1) * ring + j)
                let a1 = UInt32(i * ring + (j + 1) % ring), b1 = UInt32((i + 1) * ring + (j + 1) % ring)
                mesh.indices += [a, b, a1, b, b1, a1]
            }
        }
        return mesh.withSmoothNormals()
    }

    /// A box centered on `center`, each face split into `segments`² quads.
    static func box(_ size: SIMD3<Float>, center: SIMD3<Float> = .zero, segments: Int = 1) -> Mesh {
        var mesh = Mesh()
        for axis in 0..<3 {
            for sign: Float in [-1, 1] {
                var n = SIMD3<Float>.zero, u = n, v = n
                n[axis] = sign
                u[(axis + 1) % 3] = 1
                v[(axis + 2) % 3] = 1
                if sign < 0 { swap(&u, &v) }
                mesh += parametric(segments, segments) { i, j in
                    (n / 2 + u * (Float(i) / Float(segments) - 0.5) + v * (Float(j) / Float(segments) - 0.5)) * size
                }
            }
        }
        return center == .zero ? mesh : mesh.transformed(.translation(center))
    }

    /// A sphere centered on the origin: a subdivided icosahedron, 20 × 4^subdivisions triangles.
    static func sphere(radius: Float, subdivisions: Int = 3) -> Mesh {
        let g: Float = (1 + Float(5).squareRoot()) / 2
        let corners: [SIMD3<Float>] = [
            [-1, g, 0], [1, g, 0], [-1, -g, 0], [1, -g, 0], [0, -1, g], [0, 1, g],
            [0, -1, -g], [0, 1, -g], [g, 0, -1], [g, 0, 1], [-g, 0, -1], [-g, 0, 1],
        ].map { simd_normalize($0) }
        var mesh = Mesh(positions: corners, normals: corners,
                        indices: [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                                  3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1])
        for _ in 0..<subdivisions {
            let kept = mesh.positions.count
            mesh = mesh.subdivided()
            // Only the new vertices, from their edge's sum rather than its midpoint: any other rounding
            // shifts what scenes scatter over spheres.
            for i in kept..<mesh.positions.count { mesh.positions[i] = simd_normalize(mesh.positions[i] * 2) }
        }
        return Mesh(positions: mesh.positions.map { $0 * radius }, normals: mesh.positions, indices: mesh.indices)
    }

    /// A surface of revolution about the y axis through `profile`, given bottom to top as
    /// (radius, y). Split the profile into separate lathes where it should have a sharp edge.
    static func lathe(_ profile: [SIMD2<Float>], segments: Int = 32) -> Mesh {
        parametric(profile.count - 1, segments, wrap: true) { i, j in
            let angle = Float(j) / Float(segments) * 2 * .pi
            return SIMD3(profile[i].x * cos(angle), profile[i].y, profile[i].x * sin(angle))
        }
    }

    /// A cylinder standing on the origin, up the y axis.
    static func cylinder(radius: Float, height: Float, segments: Int = 32, rings: Int = 1, caps: Bool = true) -> Mesh {
        var mesh = lathe((0...rings).map { SIMD2(radius, height * Float($0) / Float(rings)) }, segments: segments)
        if caps { mesh += lathe([[0, 0], [radius, 0]], segments: segments) + lathe([[radius, height], [0, height]], segments: segments) }
        return mesh
    }

    /// A cone standing on the origin, its tip up the y axis.
    static func cone(radius: Float, height: Float, segments: Int = 32, rings: Int = 1, base: Bool = true) -> Mesh {
        var mesh = lathe((0...rings).map { SIMD2(radius, height) * SIMD2(1 - Float($0) / Float(rings), Float($0) / Float(rings)) }, segments: segments)
        if base { mesh += lathe([[0, 0], [radius, 0]], segments: segments) }
        return mesh
    }

    /// A tube through `points`, `radius(t)` thick where t runs from 0 at the first point to 1 at the
    /// last. Its rings turn with the curve without twisting.
    static func tube(_ points: [SIMD3<Float>], radius: (Float) -> Float, segments: Int = 12, caps: Bool = false) -> Mesh {
        let last = points.count - 1
        let tangents = points.indices.map { simd_normalize(points[min($0 + 1, last)] - points[max($0 - 1, 0)]) }
        var normal = simd_normalize(simd_cross(tangents[0], abs(tangents[0].y) < 0.9 ? [0, 1, 0] : [1, 0, 0]))
        var frames: [SIMD3<Float>] = []
        for i in points.indices {
            if i > 0 { normal = rotation(from: tangents[i - 1], to: tangents[i]).act(normal) }
            normal = simd_normalize(normal - tangents[i] * simd_dot(normal, tangents[i]))
            frames.append(normal)
        }
        func ring(_ i: Int) -> [SIMD3<Float>] {
            let r = radius(Float(i) / Float(last)), n = frames[i], b = simd_cross(n, tangents[i])
            return (0..<segments).map { j in
                let angle = Float(j) / Float(segments) * 2 * .pi
                return points[i] + (n * cos(angle) + b * sin(angle)) * r
            }
        }
        let rings = points.indices.map(ring)
        var mesh = parametric(last, segments, wrap: true) { i, j in rings[i][j] }
        if caps { mesh += fan(points[0], rings[0], facing: -tangents[0]) + fan(points[last], rings[last], facing: tangents[last]) }
        return mesh
    }

    /// A straight tube from `a` to `b`, split into `rings` lengthwise so it can be displaced.
    static func tube(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, segments: Int = 24, rings: Int = 8, caps: Bool = true) -> Mesh {
        tube((0...rings).map { a + (b - a) * Float($0) / Float(rings) }, radius: { _ in radius }, segments: segments, caps: caps)
    }

    /// A heightfield over the xz plane, centered on the origin.
    static func grid(size: SIMD2<Float>, cells: SIMD2<Int>, height: (SIMD2<Float>) -> Float = { _ in 0 }) -> Mesh {
        parametric(cells.y, cells.x) { i, j in
            let p = (SIMD2(Float(j) / Float(cells.x), Float(i) / Float(cells.y)) - 0.5) * size
            return SIMD3(p.x, height(p), p.y)
        }
    }

    /// A prism: `outline`, as (x, z) points around a simple polygon, extruded up the y axis from 0
    /// to `height`, with flat walls.
    static func extrusion(_ outline: [SIMD2<Float>], height: Float, caps: Bool = true) -> Mesh {
        var points = outline
        let area = zip(points, points.dropFirst() + [points[0]]).reduce(Float(0)) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        if area < 0 { points.reverse() }
        var mesh = Mesh()
        for (p, q) in zip(points, points.dropFirst() + [points[0]]) {
            mesh += parametric(1, 1) { i, j in
                let e = j == 0 ? p : q
                return SIMD3(e.x, height * Float(i), e.y)
            }
        }
        guard caps else { return mesh }
        let triangles = triangulate(points)
        for (y, up) in [(Float(0), false), (height, true)] {
            var cap = Mesh(positions: points.map { SIMD3($0.x, y, $0.y) },
                           normals: Array(repeating: [0, up ? 1 : -1, 0], count: points.count))
            for t in stride(from: 0, to: triangles.count, by: 3) {
                cap.indices += up ? [triangles[t], triangles[t + 2], triangles[t + 1]] : [triangles[t], triangles[t + 1], triangles[t + 2]]
            }
            mesh += cap
        }
        return mesh
    }

    /// A lumpy stone about one unit across, flattened underneath.
    static func stone(seed: Int32, roughness: Float = 0.3, subdivisions: Int = 4) -> Mesh {
        let stretch = SIMD3<Float>(1 + 0.3 * Procedural.hash(seed, 1, 0), 0.55 + 0.25 * Procedural.hash(seed, 2, 0), 0.85 + 0.3 * Procedural.hash(seed, 3, 0))
        var mesh = sphere(radius: 1, subdivisions: subdivisions)
        mesh.positions = mesh.positions.map { v in
            var p = v * (1 + roughness * (Procedural.fbm(v * 1.6, octaves: 3, seed: seed) - 0.5) * 2 + 0.06 * (Procedural.fbm(v * 6, octaves: 3, seed: seed + 7) - 0.5))
            p *= stretch * 0.5
            p.y = max(p.y, -0.12)
            return p
        }
        return mesh.withSmoothNormals()
    }
}

// MARK: Changing a mesh

extension Mesh {
    func transformed(_ m: simd_float4x4) -> Mesh {
        let normalMatrix = simd_float3x3(columns: (m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz)).inverse.transpose
        var mesh = self
        mesh.positions = positions.map { (m * SIMD4($0, 1)).xyz }
        mesh.normals = normals.map { simd_normalize(normalMatrix * $0) }
        return mesh
    }

    /// Pushes each vertex along its normal by `offset(position, normal)` and recomputes the
    /// normals. Vertices at the same position are merged first, so the surface doesn't crack.
    func displaced(_ offset: (SIMD3<Float>, SIMD3<Float>) -> Float) -> Mesh {
        var mesh = welded()
        mesh.positions = zip(mesh.positions, mesh.normals).map { p, n in p + n * offset(p, n) }
        return mesh.withSmoothNormals()
    }

    /// Each triangle split into four, for detail to displace.
    func subdivided() -> Mesh {
        var mesh = self
        var middles: [UInt64: UInt32] = [:]
        func middle(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let index = middles[key] { return index }
            mesh.positions.append((positions[Int(a)] + positions[Int(b)]) / 2)
            mesh.normals.append(simd_normalize(normals[Int(a)] + normals[Int(b)]))
            if !uvs.isEmpty { mesh.uvs.append((uvs[Int(a)] + uvs[Int(b)]) / 2) }
            middles[key] = UInt32(mesh.positions.count - 1)
            return UInt32(mesh.positions.count - 1)
        }
        mesh.indices = []
        for t in stride(from: 0, to: indices.count, by: 3) {
            let (a, b, c) = (indices[t], indices[t + 1], indices[t + 2])
            let (ab, bc, ca) = (middle(a, b), middle(b, c), middle(c, a))
            mesh.indices += [a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca]
        }
        return mesh
    }

    /// The same surface with vertices at the same position merged and their normals averaged.
    func welded() -> Mesh {
        var merged: [SIMD3<Int32>: UInt32] = [:]
        var mesh = Mesh()
        var remap: [UInt32] = []
        remap.reserveCapacity(positions.count)
        for (k, (p, n)) in zip(positions, normals).enumerated() {
            let key = SIMD3<Int32>(p * 1e4, rounding: .toNearestOrEven)
            if let index = merged[key] {
                mesh.normals[Int(index)] += n
                remap.append(index)
            } else {
                merged[key] = UInt32(mesh.positions.count)
                remap.append(UInt32(mesh.positions.count))
                mesh.positions.append(p)
                mesh.normals.append(n)
                if !uvs.isEmpty { mesh.uvs.append(uvs[k]) }
            }
        }
        mesh.normals = mesh.normals.map { simd_length($0) > 0 ? simd_normalize($0) : [0, 1, 0] }
        mesh.indices = indices.map { remap[Int($0)] }
        return mesh
    }

    /// Normals averaged from the faces around each vertex, weighted by their area.
    func withSmoothNormals() -> Mesh {
        var sums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let (a, b, c) = (Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2]))
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            sums[a] += n
            sums[b] += n
            sums[c] += n
        }
        var mesh = self
        mesh.normals = zip(sums, normals.isEmpty ? sums : normals).map { s, old in simd_length(s) > 0 ? simd_normalize(s) : old }
        return mesh
    }

    /// `count` random points on the surface, spread evenly by area, each with its normal.
    func scatter(_ count: Int, seed: UInt64) -> [(position: SIMD3<Float>, normal: SIMD3<Float>)] {
        var total: Float = 0
        let cumulative = stride(from: 0, to: indices.count, by: 3).map { t in
            let (a, b, c) = (positions[Int(indices[t])], positions[Int(indices[t + 1])], positions[Int(indices[t + 2])])
            total += simd_length(simd_cross(b - a, c - a))
            return total
        }
        var random = SeededRandom(seed: seed)
        return (0..<count).map { _ in
            let pick = Float.random(in: 0..<total, using: &random)
            var low = 0, high = cumulative.count - 1
            while low < high {
                let mid = (low + high) / 2
                if cumulative[mid] <= pick { low = mid + 1 } else { high = mid }
            }
            let (ia, ib, ic) = (Int(indices[low * 3]), Int(indices[low * 3 + 1]), Int(indices[low * 3 + 2]))
            let r = Float.random(in: 0...1, using: &random).squareRoot(), s = Float.random(in: 0...1, using: &random)
            let w = SIMD3(1 - r, r * (1 - s), r * s)
            let p = positions[ia] * w.x + positions[ib] * w.y + positions[ic] * w.z
            return (p, simd_normalize(normals[ia] * w.x + normals[ib] * w.y + normals[ic] * w.z))
        }
    }
}

// MARK: Helpers

extension Mesh {
    /// A flat cap over a closed `ring` of points around `center`.
    fileprivate static func fan(_ center: SIMD3<Float>, _ ring: [SIMD3<Float>], facing: SIMD3<Float>) -> Mesh {
        var mesh = Mesh(positions: [center] + ring, normals: Array(repeating: facing, count: ring.count + 1))
        let n = UInt32(ring.count)
        for k in 0..<n {
            let a = k + 1, b = (k + 1) % n + 1
            let front = simd_dot(simd_cross(ring[Int(a - 1)] - center, ring[Int(b - 1)] - center), facing) > 0
            mesh.indices += front ? [0, a, b] : [0, b, a]
        }
        return mesh
    }

    /// Corner indices of triangles covering a counterclockwise simple polygon, by ear clipping.
    fileprivate static func triangulate(_ p: [SIMD2<Float>]) -> [UInt32] {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        var remaining = Array(p.indices)
        var triangles: [UInt32] = []
        while remaining.count > 3 {
            let ear = remaining.indices.first { k in
                let (a, b, c) = (remaining[(k + remaining.count - 1) % remaining.count], remaining[k], remaining[(k + 1) % remaining.count])
                guard cross(p[b] - p[a], p[c] - p[a]) > 0 else { return false }
                return !remaining.contains { i in
                    i != a && i != b && i != c && cross(p[b] - p[a], p[i] - p[a]) >= 0 && cross(p[c] - p[b], p[i] - p[b]) >= 0 && cross(p[a] - p[c], p[i] - p[c]) >= 0
                }
            }
            guard let k = ear else { break }
            triangles += [remaining[(k + remaining.count - 1) % remaining.count], remaining[k], remaining[(k + 1) % remaining.count]].map { UInt32($0) }
            remaining.remove(at: k)
        }
        if remaining.count == 3 { triangles += remaining.map { UInt32($0) } }
        return triangles
    }

    fileprivate static func rotation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        simd_dot(a, b) < -0.9999 ? simd_quatf(angle: .pi, axis: abs(a.x) < 0.9 ? [1, 0, 0] : [0, 0, 1]) : simd_quatf(from: a, to: b)
    }
}

extension simd_float4x4 {
    static let identity = matrix_identity_float4x4

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func rotation(_ angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, 1))
    }

    /// Stands something at `position` with its y axis along `up`, turned `yaw` radians about it.
    static func place(_ position: SIMD3<Float>, up: SIMD3<Float> = [0, 1, 0], yaw: Float = 0, scale s: SIMD3<Float> = [1, 1, 1]) -> simd_float4x4 {
        .translation(position) * simd_float4x4(Mesh.rotation(from: [0, 1, 0], to: simd_normalize(up))) * .rotation(yaw, axis: [0, 1, 0]) * .scale(s)
    }

    /// Lays a shape built `height` tall up the y axis from the origin (cylinder, cone, lathe)
    /// along `a` to `b`, stretched lengthwise to reach.
    static func span(from a: SIMD3<Float>, to b: SIMD3<Float>, height: Float = 1) -> simd_float4x4 {
        place(a, up: b - a, scale: [1, simd_length(b - a) / height, 1])
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
