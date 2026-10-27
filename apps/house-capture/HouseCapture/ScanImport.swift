import Foundation

/// Imports an extracted room/session folder. A new house is committed only after
/// every room has copied successfully; never overwrites an existing capture.
enum ScanImport {
  static func importFolder(_ source: URL) throws -> String {
    let fm = FileManager.default
    let root = source.resolvingSymlinksInPath().standardizedFileURL
    guard let manifest = ScanBundle(url: root).manifest, !manifest.rooms.isEmpty,
          manifest.format.hasPrefix("house-capture/"),
          Set(manifest.rooms.map(\.index)).count == manifest.rooms.count,
          manifest.rooms.allSatisfy({ $0.index >= 0 }) else {
      throw CaptureReadinessError(message: NSLocalizedString("Choose an extracted 3D Model Anything room or session folder containing manifest.json. In Files, tap the shared ZIP to extract it first.", comment: ""))
    }
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
    var enumerationError: Error?
    guard let files = fm.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in enumerationError = error; return false }) else {
      throw CocoaError(.fileReadUnknown)
    }
    var bytes: Int64 = 0
    for case let file as URL in files {
      let values = try file.resourceValues(forKeys: Set(keys))
      guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
        throw CaptureReadinessError(message: NSLocalizedString("This folder contains unsupported file links. Import an original 3D Model Anything export.", comment: ""))
      }
      bytes += Int64(values.fileSize ?? 0)
    }
    if let enumerationError { throw enumerationError }
    try fm.createDirectory(at: HouseProject.root, withIntermediateDirectories: true)
    try CaptureReadiness.requireStorage(at: HouseProject.root, bytes: bytes + CaptureReadiness.reserve)
    let id = "import-" + UUID().uuidString
    var house = HouseProject(id: id, name: manifest.rooms.count == 1 ? manifest.rooms[0].name : (manifest.houseName ?? "Imported rooms"), createdAt: Date())
    var committed = false
    defer { if !committed { try? fm.removeItem(at: house.url) } }
    let zone = house.addZone(named: "Imported rooms")
    for room in manifest.rooms {
      let sessionID = "room-\(room.index)"
      let bundle = try ScanBundle.create(in: house, id: sessionID)
      try ScanBundle(url: root).exportRoom(index: room.index, name: room.name, to: bundle.url)
      guard var exported = bundle.manifest else { throw CocoaError(.fileReadCorruptFile) }
      exported.house = id; exported.houseName = house.name
      exported.session = sessionID; exported.zone = zone.id; exported.alignment = .init(method: "first")
      try bundle.writeManifest(exported)
      house.beginSession(id: sessionID, zone: zone.id, alignment: .init(method: "first"), at: room.capturedAt)
      house.recordRoomScan(name: room.name, session: sessionID, index: room.index, capturedAt: room.capturedAt, matchName: false)
      house.endSession(sessionID)
    }
    try house.save()
    committed = true
    return id
  }
}
