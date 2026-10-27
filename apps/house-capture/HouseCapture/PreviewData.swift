import Foundation
import simd
import UIKit

// What the 3D preview shows, gathered from a house (or one session), in the
// house frame. Everything here decodes its own minimal view of the bundle files so the preview keeps
// working while the capture side's types evolve.

/// One capture session as the preview sees it
struct PreviewSession: Identifiable {
  let index: Int
  let id: String
  let folder: URL
  let startedAt: Date?
  /// session ARKit world → house frame
  let toHouse: simd_float4x4
  let alignment: String
  /// placed in the house (first / relocalized / icp / manual, in an aligned zone)
  let aligned: Bool
  let zoneName: String?

  var title: String {
    guard let startedAt else { return id }
    return startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
  }

  /// Polycam-style: the first session green, later ones pink, then blue, orange, purple, teal
  var hue: UIColor { PreviewSession.hues[index % PreviewSession.hues.count] }

  static let hues: [UIColor] = [
    UIColor(red: 0.20, green: 0.84, blue: 0.47, alpha: 1),
    UIColor(red: 1.00, green: 0.35, blue: 0.67, alpha: 1),
    UIColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1),
    UIColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1),
    UIColor(red: 0.69, green: 0.45, blue: 1.00, alpha: 1),
    UIColor(red: 0.20, green: 0.83, blue: 0.87, alpha: 1),
  ]
}

/// One room scan to show: its LiDAR mesh + RoomPlan model
struct PreviewRoom: Identifiable, Hashable {
  let session: Int
  let index: Int
  let name: String
  let mesh: URL
  let usdz: URL?
  var id: String { "\(session)/\(index)" }
}

/// A posed reference photo, pose already in the house frame
struct PreviewPhoto: Identifiable {
  let id: Int
  let session: Int
  let url: URL
  let room: Int
  let timestamp: Double
  /// camera → house; the camera looks down −Z, +X right / +Y up in sensor (landscape) orientation
  let cameraToHouse: simd_float4x4
  let fx: Float, fy: Float, cx: Float, cy: Float
  /// JPEG pixel size in sensor orientation (the file shows upright via EXIF orientation 6)
  let width: Int, height: Int
  /// 1 = sharp, lower for motion blur
  let sharpness: Float
  /// brightness normalization toward the session's median exposure (1 when unknown)
  let gain: Float

  var position: SIMD3<Float> { simd_make_float3(cameraToHouse.columns.3) }
  var forward: SIMD3<Float> { -simd_normalize(simd_make_float3(cameraToHouse.columns.2)) }
}

struct PreviewSource {
  var title: String
  var subtitle: String
  var sessions: [PreviewSession]
  var rooms: [PreviewRoom]
  /// sessions the house view leaves out by default (not placed in the house frame yet)
  var hiddenSessions: Set<Int> = []

  // MARK: builders

  /// Every room's active scan, across sessions
  static func house(_ house: HouseProject) -> PreviewSource {
    var sessions: [PreviewSession] = []
    for (i, s) in house.sessions.sorted(by: { $0.startedAt < $1.startedAt }).enumerated() {
      let zone = house.zone(s.zone)
      let aligned = (zone?.aligned ?? true) && s.alignment.method != "unaligned"
      sessions.append(PreviewSession(index: i, id: s.id, folder: house.url.appendingPathComponent(s.folder, isDirectory: true),
                                     startedAt: s.startedAt, toHouse: house.toHouse(s), alignment: s.alignment.method,
                                     aligned: aligned, zoneName: zone?.name))
    }
    var rooms: [PreviewRoom] = []
    let active = house.rooms.compactMap { r in r.active.map { (r, $0) } }
    if !active.isEmpty {
      for (room, ref) in active {
        guard let s = sessions.first(where: { $0.id == ref.session }) else { continue }
        rooms.append(roomEntry(s, index: ref.index, name: room.name))
      }
    }
    rooms.sort { ($0.session, $0.index) < ($1.session, $1.index) }
    // Keep aligned earlier sessions available as photo sources for the active room meshes.
    let hidden = Set(sessions.filter { !$0.aligned && $0.index != sessions.first?.index }.map(\.index))
    let n = rooms.count
    return PreviewSource(title: house.name,
                         subtitle: [n == 1 ? String(localized: "1 room") : String(localized: "\(n) rooms"),
                                    sessions.count == 1 ? String(localized: "1 session") : String(localized: "\(sessions.count) sessions")].joined(separator: " · "),
                         sessions: sessions, rooms: rooms, hiddenSessions: hidden)
  }

  /// Every room scanned in one session (in the house frame, so it lines up with the house view)
  static func session(_ house: HouseProject, _ session: HouseProject.Session) -> PreviewSource {
    let zone = house.zone(session.zone)
    let s = PreviewSession(index: 0, id: session.id, folder: house.url.appendingPathComponent(session.folder, isDirectory: true),
                           startedAt: session.startedAt, toHouse: house.toHouse(session), alignment: session.alignment.method,
                           aligned: (zone?.aligned ?? true) && session.alignment.method != "unaligned", zoneName: zone?.name)
    let deleted = house.deletedRooms.flatMap { $0.room.history }.filter { $0.session == session.id }
    let rooms = roomsInBundle(s).filter { room in !deleted.contains { $0.index == room.index } }
    return PreviewSource(title: s.title,
                         subtitle: (rooms.count == 1 ? String(localized: "1 room") : String(localized: "\(rooms.count) rooms")) + " · \(s.alignment)",
                         sessions: [s], rooms: rooms)
  }

  private static func roomEntry(_ s: PreviewSession, index: Int, name: String) -> PreviewRoom {
    let usdz = s.folder.appendingPathComponent("rooms/room-\(index).usdz")
    return PreviewRoom(session: s.index, index: index, name: name,
                       mesh: s.folder.appendingPathComponent("mesh/room-\(index).ply"),
                       usdz: FileManager.default.fileExists(atPath: usdz.path) ? usdz : nil)
  }

  private static func roomsInBundle(_ s: PreviewSession) -> [PreviewRoom] {
    if let m = BundleManifest.load(s.folder), !m.rooms.isEmpty {
      return m.rooms.map { roomEntry(s, index: $0.index, name: $0.name) }
    }
    // no manifest (capture still running / interrupted): whatever meshes are there
    let files = (try? FileManager.default.contentsOfDirectory(atPath: s.folder.appendingPathComponent("mesh").path)) ?? []
    return files.compactMap { f -> Int? in
      guard f.hasPrefix("room-"), f.hasSuffix(".ply") else { return nil }
      return Int(f.dropFirst(5).dropLast(4))
    }.sorted().map { roomEntry(s, index: $0, name: "Room \($0 + 1)") }
  }

  // MARK: photos

  /// The session's photos with poses in the house frame; ids continue from `firstID`
  static func photos(of session: PreviewSession, firstID: Int) -> [PreviewPhoto] {
    struct File: Decodable {
      struct Camera: Decodable { var iso: Float?; var shutter: Double? }
      var file: String
      var room: Int?
      var timestamp: Double?
      var width: Int
      var height: Int
      var transform: [Float]
      var intrinsics: [Float]
      var blurPixels: Float?
      var camera: Camera?
    }
    guard let data = try? Data(contentsOf: session.folder.appendingPathComponent("photos/photos.json")),
          let files = try? JSONDecoder().decode([File].self, from: data) else { return [] }
    let exposures = files.compactMap { f -> Float? in
      guard let iso = f.camera?.iso, let shutter = f.camera?.shutter, iso > 0, shutter > 0 else { return nil }
      return iso * Float(shutter)
    }.sorted()
    let median = exposures.isEmpty ? nil : exposures[exposures.count / 2]
    var out: [PreviewPhoto] = []
    for f in files where f.transform.count == 16 && f.intrinsics.count == 9 {
      let url = session.folder.appendingPathComponent(f.file)
      let blur = (f.blurPixels ?? 0) * 1920 / Float(max(1, f.width))
      let sharp: Float = blur <= 1.5 ? 1 : max(0.35, 1 - (blur - 1.5) / 6)
      var gain: Float = 1
      if let median, let iso = f.camera?.iso, let shutter = f.camera?.shutter, iso > 0, shutter > 0 {
        gain = max(0.5, min(2, median / (iso * Float(shutter))))
      }
      out.append(PreviewPhoto(id: firstID + out.count, session: session.index, url: url, room: f.room ?? 0,
                              timestamp: f.timestamp ?? 0,
                              cameraToHouse: session.toHouse * simd_float4x4(columnMajor: f.transform),
                              fx: f.intrinsics[0], fy: f.intrinsics[4], cx: f.intrinsics[6], cy: f.intrinsics[7],
                              width: f.width, height: f.height, sharpness: sharp, gain: gain))
    }
    return out
  }
}

/// The few manifest fields the preview needs
struct BundleManifest: Decodable {
  struct Room: Decodable {
    var index: Int
    var name: String
  }
  var createdAt: Date?
  var rooms: [Room]

  static func load(_ folder: URL) -> BundleManifest? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try? d.decode(BundleManifest.self, from: data)
  }
}

// MARK: - surroundings

/// Each room's PLY holds the whole session's mesh at that point (ARKit anchors accumulate), flagged
/// inside/outside that room. The preview shows each room's inside part, plus the outside part
/// ("surroundings": hallways, views through doors) of the newest room per session, minus anything
/// already covered by a shown room or by a newer session's surroundings.
enum SurroundingsFilter {
  private static let voxel: Float = 0.08

  @inline(__always) private static func key(_ p: SIMD3<Float>) -> Int64 {
    let x = Int64(floor(p.x / voxel)) & 0x1FFFFF, y = Int64(floor(p.y / voxel)) & 0x1FFFFF, z = Int64(floor(p.z / voxel)) & 0x1FFFFF
    return (x << 42) | (y << 21) | z
  }

  static func occupancy(_ mesh: PLYMesh, _ indices: [UInt32], into set: inout Set<Int64>) {
    set.reserveCapacity(set.count + indices.count / 6)
    var f = 0
    while f + 2 < indices.count {
      let c = (mesh.position(Int(indices[f])) + mesh.position(Int(indices[f + 1])) + mesh.position(Int(indices[f + 2]))) / 3
      set.insert(key(c))
      f += 3
    }
  }

  /// the triangles of `indices` whose centroid voxel isn't in `occupied`
  static func subtract(_ mesh: PLYMesh, _ indices: [UInt32], _ occupied: Set<Int64>) -> [UInt32] {
    guard !occupied.isEmpty else { return indices }
    var out: [UInt32] = []
    out.reserveCapacity(indices.count)
    var f = 0
    while f + 2 < indices.count {
      let a = indices[f], b = indices[f + 1], c = indices[f + 2]
      let centroid = (mesh.position(Int(a)) + mesh.position(Int(b)) + mesh.position(Int(c))) / 3
      if !occupied.contains(key(centroid)) { out.append(a); out.append(b); out.append(c) }
      f += 3
    }
    return out
  }
}
