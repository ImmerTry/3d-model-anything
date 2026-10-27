import Foundation
import simd

/// One room's LiDAR mesh (`mesh/room-N.ply`, written by `CoverageEngine.writePLY`), loaded into flat
/// arrays that go straight into SceneKit buffers, already transformed into the house frame.
///
/// The app's format is binary little-endian:
///     vertex  x y z nx ny nz coverage (float) · red green blue inroom (uchar)      32 bytes
///     face    uchar count (3) · 3 × uint · uchar class                             14 bytes
/// The reader parses the header, so other binary PLYs (e.g. Open3D's double-precision output) load too;
/// missing properties get defaults (inroom = 1, gray color).
final class PLYMesh: @unchecked Sendable {
  let url: URL
  let vertexCount: Int
  /// packed xyz, house frame
  let positions: [Float]
  /// packed xyz, unit length (zero if the file has none)
  let normals: [Float]
  /// the PLY's own colors (the capture-time coverage bands), RGBA
  let coverageColors: [UInt8]
  let inRoom: [UInt8]
  /// all triangles
  let indices: [UInt32]
  let boundsMin: SIMD3<Float>
  let boundsMax: SIMD3<Float>
  /// seconds spent reading + parsing
  let loadSeconds: Double

  var faceCount: Int { indices.count / 3 }
  let hasInRoomFlags: Bool
  var center: SIMD3<Float> { (boundsMin + boundsMax) / 2 }

  @inline(__always) func position(_ i: Int) -> SIMD3<Float> {
    SIMD3(positions[3 * i], positions[3 * i + 1], positions[3 * i + 2])
  }

  @inline(__always) func normal(_ i: Int) -> SIMD3<Float> {
    SIMD3(normals[3 * i], normals[3 * i + 1], normals[3 * i + 2])
  }

  private init(url: URL, vertexCount: Int, positions: [Float], normals: [Float], coverageColors: [UInt8], inRoom: [UInt8],
               hasInRoomFlags: Bool, indices: [UInt32], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, loadSeconds: Double) {
    self.url = url
    self.vertexCount = vertexCount
    self.positions = positions
    self.normals = normals
    self.coverageColors = coverageColors
    self.inRoom = inRoom
    self.hasInRoomFlags = hasInRoomFlags
    self.indices = indices
    self.boundsMin = boundsMin
    self.boundsMax = boundsMax
    self.loadSeconds = loadSeconds
  }

  enum LoadError: LocalizedError {
    case notPLY, unsupported(String), truncated, empty
    var errorDescription: String? {
      switch self {
      case .notPLY: NSLocalizedString("Not a PLY file", comment: "")
      case .unsupported(let what): String(format: NSLocalizedString("Unsupported PLY: %@", comment: ""), what)
      case .truncated: NSLocalizedString("The PLY file is truncated", comment: "")
      case .empty: NSLocalizedString("The mesh is empty", comment: "")
      }
    }
  }

  // MARK: - loading

  private enum PType {
    case i8, u8, i16, u16, i32, u32, f32, f64
    init?(_ s: Substring) {
      switch s {
      case "char", "int8": self = .i8
      case "uchar", "uint8": self = .u8
      case "short", "int16": self = .i16
      case "ushort", "uint16": self = .u16
      case "int", "int32": self = .i32
      case "uint", "uint32": self = .u32
      case "float", "float32": self = .f32
      case "double", "float64": self = .f64
      default: return nil
      }
    }
    var size: Int {
      switch self {
      case .i8, .u8: 1
      case .i16, .u16: 2
      case .i32, .u32, .f32: 4
      case .f64: 8
      }
    }
  }

  private struct Field { var type: PType; var offset: Int }

  /// Reads `url`, applying `transform` (session → house) to positions and normals.
  /// `progress` (0…1) is called from background threads.
  static func load(url: URL, transform: simd_float4x4 = matrix_identity_float4x4,
                   progress: (@Sendable (Double) -> Void)? = nil) throws -> PLYMesh {
    let t0 = CFAbsoluteTimeGetCurrent()
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    guard data.count > 16, data.prefix(3) == Data("ply".utf8) else { throw LoadError.notPLY }
    // header
    guard let end = data.range(of: Data("end_header\n".utf8), in: 0..<min(data.count, 16384)) else { throw LoadError.notPLY }
    let header = String(decoding: data[0..<end.lowerBound], as: UTF8.self)
    let bodyStart = end.upperBound
    var vertexCount = 0, faceCount = 0
    var vertexFields: [String: Field] = [:]
    var vertexStride = 0
    var faceCountType: PType?, faceIndexType: PType?, faceExtra = 0
    var current = ""
    for line in header.split(separator: "\n") {
      let parts = line.split(separator: " ")
      guard let head = parts.first else { continue }
      switch head {
      case "format":
        guard parts.count > 1, parts[1] == "binary_little_endian" else { throw LoadError.unsupported("format \(parts.dropFirst().joined(separator: " "))") }
      case "element":
        guard parts.count == 3 else { continue }
        current = String(parts[1])
        if current == "vertex" { vertexCount = Int(parts[2]) ?? 0 }
        if current == "face" { faceCount = Int(parts[2]) ?? 0 }
        if current != "vertex" && current != "face" && Int(parts[2]) != 0 {
          throw LoadError.unsupported("element \(current)")
        }
      case "property":
        if current == "vertex" {
          guard parts.count == 3, let t = PType(parts[1]) else { throw LoadError.unsupported("vertex property \(line)") }
          vertexFields[String(parts[2])] = Field(type: t, offset: vertexStride)
          vertexStride += t.size
        } else if current == "face" {
          if parts.count == 5, parts[1] == "list" {
            if faceIndexType == nil {
              faceCountType = PType(parts[2])
              faceIndexType = PType(parts[3])
            } else {
              throw LoadError.unsupported("second face list")
            }
          } else if parts.count == 3, let t = PType(parts[1]) {
            if faceIndexType == nil { throw LoadError.unsupported("face property before the index list") }
            faceExtra += t.size
          }
        }
      default: break
      }
    }
    guard vertexCount > 0, faceCount > 0 else { throw LoadError.empty }
    guard let fx = vertexFields["x"], let fy = vertexFields["y"], let fz = vertexFields["z"] else { throw LoadError.unsupported("no x/y/z") }
    guard faceCountType == .u8, let idxType = faceIndexType, idxType == .u32 || idxType == .i32 else {
      throw LoadError.unsupported("face index list must be uchar + (u)int")
    }
    let vertexBytes = vertexCount * vertexStride
    guard data.count >= bodyStart + vertexBytes + faceCount * 13 else { throw LoadError.truncated }

    let nfx = vertexFields["nx"], nfy = vertexFields["ny"], nfz = vertexFields["nz"]
    let hasNormals = nfx != nil && nfy != nil && nfz != nil
    let fr = vertexFields["red"], fg = vertexFields["green"], fb = vertexFields["blue"]
    let hasColor = fr?.type == .u8 && fg?.type == .u8 && fb?.type == .u8
    let fin = vertexFields["inroom"]
    let isIdentity = transform == matrix_identity_float4x4

    let chunk = 1 << 16
    let chunks = (vertexCount + chunk - 1) / chunk
    // per chunk: min xyz, max xyz
    var boxes = [Float](repeating: 0, count: chunks * 6)
    var positions = [Float](repeating: 0, count: vertexCount * 3)
    var normals = [Float](repeating: 0, count: vertexCount * 3)
    var colors = [UInt8](repeating: 160, count: vertexCount * 4)
    var inRoom = [UInt8](repeating: 1, count: vertexCount)
    guard fx.type == .f32 || fx.type == .f64 else { throw LoadError.unsupported("x must be float/double") }
    // offsets (-1 = absent) and whether coordinates are doubles; plain scalars so the loop is fast at -Onone
    let isDouble = fx.type == .f64
    let ox = fx.offset, oy = fy.offset, oz = fz.offset
    let onx = hasNormals ? nfx!.offset : -1, ony = hasNormals ? nfy!.offset : -1, onz = hasNormals ? nfz!.offset : -1
    let normalsDouble = nfx?.type == .f64
    let or_ = hasColor ? fr!.offset : -1, og = hasColor ? fg!.offset : -1, ob = hasColor ? fb!.offset : -1
    let oin = fin?.type == .u8 ? fin!.offset : -1
    let t = transform
    let m00 = t.columns.0.x, m01 = t.columns.1.x, m02 = t.columns.2.x, m03 = t.columns.3.x
    let m10 = t.columns.0.y, m11 = t.columns.1.y, m12 = t.columns.2.y, m13 = t.columns.3.y
    let m20 = t.columns.0.z, m21 = t.columns.1.z, m22 = t.columns.2.z, m23 = t.columns.3.z
    let stride = vertexStride

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let body = raw.baseAddress! + bodyStart
      positions.withUnsafeMutableBufferPointer { posb in
        normals.withUnsafeMutableBufferPointer { norb in
          colors.withUnsafeMutableBufferPointer { colb in
            inRoom.withUnsafeMutableBufferPointer { inrb in
              boxes.withUnsafeMutableBufferPointer { boxb in
                let pos = posb.baseAddress!, nor = norb.baseAddress!, col = colb.baseAddress!, inr = inrb.baseAddress!, box = boxb.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                  Self.parseVertices(body: body, stride: stride, from: c * chunk, to: Swift.min(vertexCount, (c + 1) * chunk),
                                     isDouble: isDouble, ox: ox, oy: oy, oz: oz,
                                     normalsDouble: normalsDouble, onx: onx, ony: ony, onz: onz,
                                     or: or_, og: og, ob: ob, oin: oin, identity: isIdentity,
                                     m: (m00, m01, m02, m03, m10, m11, m12, m13, m20, m21, m22, m23),
                                     pos: pos, nor: nor, col: col, inr: inr, box: box + 6 * c)
                }
              }
            }
          }
        }
      }
    }
    progress?(0.5)

    // faces: fast path when every face is a triangle (always true for the app's files)
    let faceStart = bodyStart + vertexBytes
    let faceStride = 1 + 3 * 4 + faceExtra
    var indices: [UInt32]
    var allTriangles = data.count >= faceStart + faceCount * faceStride
    if allTriangles {
      indices = [UInt32](repeating: 0, count: faceCount * 3)
      let fchunk = 1 << 17
      let fchunks = (faceCount + fchunk - 1) / fchunk
      var bad = [Bool](repeating: false, count: fchunks)
      data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let body = raw.baseAddress! + faceStart
        indices.withUnsafeMutableBufferPointer { idxb in
          bad.withUnsafeMutableBufferPointer { badb in
            let idx = idxb.baseAddress!, badp = badb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: fchunks) { c in
              badp[c] = !Self.parseTriangles(body: body, stride: faceStride, from: c * fchunk, to: Swift.min(faceCount, (c + 1) * fchunk),
                                             limit: UInt32(vertexCount), idx: idx)
            }
          }
        }
      }
      if bad.contains(true) { allTriangles = false }
    } else {
      indices = []
    }
    if !allTriangles {
      // slow path: polygons, fan-triangulated
      indices = []
      indices.reserveCapacity(faceCount * 3)
      try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var o = faceStart
        let limit = UInt32(vertexCount)
        for _ in 0..<faceCount {
          guard o < raw.count else { throw LoadError.truncated }
          let n = Int(raw.load(fromByteOffset: o, as: UInt8.self))
          o += 1
          guard o + n * 4 + faceExtra <= raw.count else { throw LoadError.truncated }
          var poly: [UInt32] = []
          for k in 0..<n {
            let v = raw.loadUnaligned(fromByteOffset: o + 4 * k, as: UInt32.self)
            poly.append(v < limit ? v : 0)
          }
          o += n * 4 + faceExtra
          if n >= 3 {
            for k in 1..<(n - 1) { indices.append(contentsOf: [poly[0], poly[k], poly[k + 1]]) }
          }
        }
      }
    }
    // SceneKit culls clockwise faces. ARKit meshes wind counter-clockwise around their normals, but other
    // tools (e.g. Open3D's marching cubes) don't: flip the winding when it disagrees with the normals.
    if hasNormals, indices.count >= 3 {
      positions.withUnsafeBufferPointer { pb in
        normals.withUnsafeBufferPointer { nb in
          indices.withUnsafeMutableBufferPointer { ib in
            Self.fixWinding(pos: pb.baseAddress!, nor: nb.baseAddress!, idx: ib.baseAddress!, faces: ib.count / 3)
          }
        }
      }
    }
    progress?(1)

    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    for c in 0..<chunks {
      lo = simd_min(lo, SIMD3(boxes[6 * c], boxes[6 * c + 1], boxes[6 * c + 2]))
      hi = simd_max(hi, SIMD3(boxes[6 * c + 3], boxes[6 * c + 4], boxes[6 * c + 5]))
    }
    return PLYMesh(url: url, vertexCount: vertexCount, positions: positions, normals: normals, coverageColors: colors,
                   inRoom: inRoom, hasInRoomFlags: fin != nil, indices: indices, boundsMin: lo, boundsMax: hi,
                   loadSeconds: CFAbsoluteTimeGetCurrent() - t0)
  }

  @_optimize(speed)
  private static func parseTriangles(body: UnsafeRawPointer, stride: Int, from start: Int, to end: Int,
                                     limit: UInt32, idx: UnsafeMutablePointer<UInt32>) -> Bool {
    var f = start
    while f < end {
      let p = body + f * stride
      if p.load(as: UInt8.self) != 3 { return false }
      let a = p.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
      let b = p.loadUnaligned(fromByteOffset: 5, as: UInt32.self)
      let c = p.loadUnaligned(fromByteOffset: 9, as: UInt32.self)
      idx[3 * f] = a < limit ? a : 0
      idx[3 * f + 1] = b < limit ? b : 0
      idx[3 * f + 2] = c < limit ? c : 0
      f += 1
    }
    return true
  }

  /// SceneKit culls clockwise faces. ARKit meshes wind counter-clockwise around their normals, but other
  /// tools (e.g. Open3D's marching cubes) may not: flip the winding when it disagrees with the normals.
  @_optimize(speed)
  private static func fixWinding(pos: UnsafePointer<Float>, nor: UnsafePointer<Float>, idx: UnsafeMutablePointer<UInt32>, faces: Int) {
    var agree = 0, disagree = 0
    let step = Swift.max(1, faces / 20_000)
    var f = 0
    while f < faces {
      let a = Int(idx[3 * f]) * 3, b = Int(idx[3 * f + 1]) * 3, c = Int(idx[3 * f + 2]) * 3
      let ux = pos[b] - pos[a], uy = pos[b + 1] - pos[a + 1], uz = pos[b + 2] - pos[a + 2]
      let vx = pos[c] - pos[a], vy = pos[c + 1] - pos[a + 1], vz = pos[c + 2] - pos[a + 2]
      let cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx
      let nx = nor[a] + nor[b] + nor[c], ny = nor[a + 1] + nor[b + 1] + nor[c + 1], nz = nor[a + 2] + nor[b + 2] + nor[c + 2]
      let d = cx * nx + cy * ny + cz * nz
      if d > 0 { agree += 1 } else if d < 0 { disagree += 1 }
      f += step
    }
    guard disagree > agree else { return }
    f = 0
    while f < faces {
      let t = idx[3 * f + 1]
      idx[3 * f + 1] = idx[3 * f + 2]
      idx[3 * f + 2] = t
      f += 1
    }
  }

  @_optimize(speed)
  private static func parseVertices(body: UnsafeRawPointer, stride: Int, from start: Int, to end: Int,
                                    isDouble: Bool, ox: Int, oy: Int, oz: Int,
                                    normalsDouble: Bool, onx: Int, ony: Int, onz: Int,
                                    or: Int, og: Int, ob: Int, oin: Int, identity: Bool,
                                    m: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float),
                                    pos: UnsafeMutablePointer<Float>, nor: UnsafeMutablePointer<Float>,
                                    col: UnsafeMutablePointer<UInt8>, inr: UnsafeMutablePointer<UInt8>, box: UnsafeMutablePointer<Float>) {
    var lx = Float.greatestFiniteMagnitude, ly = lx, lz = lx
    var hx = -lx, hy = -lx, hz = -lx
    var i = start
    while i < end {
      let v = body + i * stride
      var x: Float, y: Float, z: Float
      if isDouble {
        x = Float(v.loadUnaligned(fromByteOffset: ox, as: Double.self))
        y = Float(v.loadUnaligned(fromByteOffset: oy, as: Double.self))
        z = Float(v.loadUnaligned(fromByteOffset: oz, as: Double.self))
      } else {
        x = v.loadUnaligned(fromByteOffset: ox, as: Float.self)
        y = v.loadUnaligned(fromByteOffset: oy, as: Float.self)
        z = v.loadUnaligned(fromByteOffset: oz, as: Float.self)
      }
      if !identity {
        let tx = m.0 * x + m.1 * y + m.2 * z + m.3
        let ty = m.4 * x + m.5 * y + m.6 * z + m.7
        let tz = m.8 * x + m.9 * y + m.10 * z + m.11
        x = tx; y = ty; z = tz
      }
      pos[3 * i] = x; pos[3 * i + 1] = y; pos[3 * i + 2] = z
      if x < lx { lx = x }; if x > hx { hx = x }
      if y < ly { ly = y }; if y > hy { hy = y }
      if z < lz { lz = z }; if z > hz { hz = z }
      if onx >= 0 {
        var nx: Float, ny: Float, nz: Float
        if normalsDouble {
          nx = Float(v.loadUnaligned(fromByteOffset: onx, as: Double.self))
          ny = Float(v.loadUnaligned(fromByteOffset: ony, as: Double.self))
          nz = Float(v.loadUnaligned(fromByteOffset: onz, as: Double.self))
        } else {
          nx = v.loadUnaligned(fromByteOffset: onx, as: Float.self)
          ny = v.loadUnaligned(fromByteOffset: ony, as: Float.self)
          nz = v.loadUnaligned(fromByteOffset: onz, as: Float.self)
        }
        if !identity {
          let tx = m.0 * nx + m.1 * ny + m.2 * nz
          let ty = m.4 * nx + m.5 * ny + m.6 * nz
          let tz = m.8 * nx + m.9 * ny + m.10 * nz
          nx = tx; ny = ty; nz = tz
        }
        let l = (nx * nx + ny * ny + nz * nz).squareRoot()
        // ARKit can supply zero normals; older captures may contain NaN from normalizing them.
        // Keep unknown directions at zero so shading and photo-color conversion stay finite.
        if l.isFinite && l > 1e-6 {
          nx /= l; ny /= l; nz /= l
        } else {
          nx = 0; ny = 0; nz = 0
        }
        nor[3 * i] = nx; nor[3 * i + 1] = ny; nor[3 * i + 2] = nz
      }
      if or >= 0 {
        col[4 * i] = v.load(fromByteOffset: or, as: UInt8.self)
        col[4 * i + 1] = v.load(fromByteOffset: og, as: UInt8.self)
        col[4 * i + 2] = v.load(fromByteOffset: ob, as: UInt8.self)
      }
      col[4 * i + 3] = 255
      if oin >= 0 { inr[i] = v.load(fromByteOffset: oin, as: UInt8.self) }
      i += 1
    }
    box[0] = lx; box[1] = ly; box[2] = lz; box[3] = hx; box[4] = hy; box[5] = hz
  }

  // MARK: - derived data

  /// Triangles split into the ones inside the room outline (any corner in the room, like the capture
  /// overlay) and the rest ("surroundings": hallways and neighbouring rooms seen through doorways).
  @_optimize(speed)
  func splitByRoom() -> (inside: [UInt32], outside: [UInt32]) {
    guard hasInRoomFlags else { return (indices, []) }
    let total = indices.count
    var flags = [UInt8](repeating: 0, count: total / 3)
    var insideCount = 0
    indices.withUnsafeBufferPointer { ib in
      inRoom.withUnsafeBufferPointer { rb in
        flags.withUnsafeMutableBufferPointer { fb in
          let idx = ib.baseAddress!, r = rb.baseAddress!, fl = fb.baseAddress!
          var f = 0
          while f < total / 3 {
            if r[Int(idx[3 * f])] | r[Int(idx[3 * f + 1])] | r[Int(idx[3 * f + 2])] != 0 { fl[f] = 1; insideCount += 1 }
            f += 1
          }
        }
      }
    }
    var inside = [UInt32](repeating: 0, count: insideCount * 3)
    var outside = [UInt32](repeating: 0, count: total - insideCount * 3)
    indices.withUnsafeBufferPointer { ib in
      flags.withUnsafeBufferPointer { fb in
        inside.withUnsafeMutableBufferPointer { inb in
          outside.withUnsafeMutableBufferPointer { outb in
            let idx = ib.baseAddress!, fl = fb.baseAddress!
            var i = 0, o = 0, f = 0
            while f < total / 3 {
              if fl[f] != 0 {
                inb[i] = idx[3 * f]; inb[i + 1] = idx[3 * f + 1]; inb[i + 2] = idx[3 * f + 2]; i += 3
              } else {
                outb[o] = idx[3 * f]; outb[o + 1] = idx[3 * f + 1]; outb[o + 2] = idx[3 * f + 2]; o += 3
              }
              f += 1
            }
          }
        }
      }
    }
    return (inside, outside)
  }

  /// Floor and ceiling heights from the up- and down-facing vertices (2 cm histogram peaks).
  func levels() -> (floor: Float, ceiling: Float) {
    let lo = boundsMin.y, hi = boundsMax.y
    let bins = max(1, Int((hi - lo) / 0.02) + 1)
    var up = [Int](repeating: 0, count: bins), down = [Int](repeating: 0, count: bins)
    let step = max(1, vertexCount / 400_000)
    var i = 0
    while i < vertexCount {
      let ny = normals[3 * i + 1]
      let b = min(bins - 1, max(0, Int((positions[3 * i + 1] - lo) / 0.02)))
      if ny > 0.85 { up[b] += 1 } else if ny < -0.85 { down[b] += 1 }
      i += step
    }
    // floor: the biggest up-facing peak in the lowest metre; ceiling: biggest down-facing peak in the top metre
    let lowLimit = min(bins, Int(1.0 / 0.02))
    var floorBin = 0
    for b in 0..<lowLimit where up[b] > up[floorBin] { floorBin = b }
    var ceilBin = bins - 1
    for b in max(0, bins - lowLimit)..<bins where down[b] > down[ceilBin] { ceilBin = b }
    let floor = up[floorBin] > 0 ? lo + (Float(floorBin) + 0.5) * 0.02 : lo
    let ceiling = down[ceilBin] > 0 ? lo + (Float(ceilBin) + 0.5) * 0.02 : hi
    return (floor, max(ceiling, floor + 1))
  }

  // MARK: - photo color cache (mesh/room-N-colors.bin: uchar r g b per vertex)

  var colorCacheURL: URL {
    url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-colors.bin")
  }

  /// RGBA, or nil when there's no cache, it's the wrong size, or it's older than the mesh
  func loadCachedColors() -> [UInt8]? {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: colorCacheURL.path),
          let size = attrs[.size] as? Int, size == vertexCount * 3 else { return nil }
    if let cacheDate = attrs[.modificationDate] as? Date,
       let meshDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
       cacheDate < meshDate { return nil }
    guard let data = try? Data(contentsOf: colorCacheURL) else { return nil }
    var rgba = [UInt8](repeating: 255, count: vertexCount * 4)
    data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
      rgba.withUnsafeMutableBufferPointer { Self.expand(src.bindMemory(to: UInt8.self).baseAddress!, $0.baseAddress!, vertexCount) }
    }
    return rgba
  }

  func saveColors(_ rgba: [UInt8]) throws {
    var rgb = [UInt8](repeating: 0, count: vertexCount * 3)
    rgba.withUnsafeBufferPointer { src in
      rgb.withUnsafeMutableBufferPointer { Self.pack(src.baseAddress!, $0.baseAddress!, vertexCount) }
    }
    try Data(rgb).write(to: colorCacheURL, options: .atomic)
  }

  @_optimize(speed)
  private static func expand(_ s: UnsafePointer<UInt8>, _ d: UnsafeMutablePointer<UInt8>, _ n: Int) {
    var i = 0
    while i < n { d[4 * i] = s[3 * i]; d[4 * i + 1] = s[3 * i + 1]; d[4 * i + 2] = s[3 * i + 2]; i += 1 }
  }

  @_optimize(speed)
  private static func pack(_ s: UnsafePointer<UInt8>, _ d: UnsafeMutablePointer<UInt8>, _ n: Int) {
    var i = 0
    while i < n { d[3 * i] = s[4 * i]; d[3 * i + 1] = s[4 * i + 1]; d[3 * i + 2] = s[4 * i + 2]; i += 1 }
  }
}
