import SwiftUI

/// The 3D viewers (HouseViewer.swift), in one place
enum HousePreviews {
  static func house(_ house: HouseProject) -> some View { HouseViewer(house: house) }
  static func session(_ house: HouseProject, _ session: HouseProject.Session) -> some View { SessionViewer(house: house, session: session) }
}

/// One house: its areas (zones) with their rooms and scan history, its sessions, and the
/// buttons to continue scanning, start a new area, preview and share.
struct HouseScreen: View {
  let houseID: String
  /// changes when a capture closes
  let generation: Int
  let onCapture: (_ houseID: String, _ zoneID: String?, _ newZone: String?, _ roomID: String?) -> Void
  let onGone: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var house: HouseProject?
  /// session id → its manifest (room coverage etc.), loaded off main
  @State private var manifests: [String: Manifest] = [:]
  @State private var renaming: HouseProject.Room?
  @State private var newRoomName = ""
  @State private var permanentRoomID: String?
  @State private var deletingRoom: HouseProject.Room?
  @State private var sharing: URL?
  @State private var busy: String?
  @State private var error: String?
  @State private var deletingSession: HouseProject.Session?

  var body: some View {
    Group {
      if let house {
        list(house)
      } else {
        ProgressView()
      }
    }
    .disabled(busy != nil)
    .background(Fieldwork.paper)
    .foregroundStyle(Fieldwork.ink)
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .principal) { FieldworkEyebrow(text: "3D Model Anything") }
      ToolbarItem(placement: .topBarTrailing) {
        if let house {
          Menu {
            Button("Share whole house", systemImage: "square.and.arrow.up") { share(house.url, name: house.name) }
            NavigationLink("Preview house in 3D") { HousePreviews.house(house) }
          } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("House options")
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .onAppear(perform: reload)
    .onChange(of: generation) { _, _ in reload() }
    .overlay {
      if let busy {
        ProgressView(busy)
          .padding(24)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") { error = nil }
    } message: {
      Text(error ?? "")
    }
    .confirmationDialog("Move room to Recently Deleted?", isPresented: Binding(get: { deletingRoom != nil }, set: { if !$0 { deletingRoom = nil } }), titleVisibility: .visible) {
      Button("Delete room", role: .destructive) {
        if let room = deletingRoom {
          do { try HouseProject.moveRoomToTrash(houseID: houseID, roomID: room.id) }
          catch { self.error = error.localizedDescription }
          reload()
        }
        deletingRoom = nil
      }
    } message: {
      Text("You can restore this room and its scans from Recently Deleted. Nothing is erased yet.")
    }
    .confirmationDialog("Delete this session?", isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }), titleVisibility: .visible) {
      Button("Delete session", role: .destructive) {
        if let s = deletingSession { delete(s) }
        deletingSession = nil
      }
    } message: {
      Text("Its rooms go back to their previous scans (rooms with no other scan disappear). Photos, meshes and depth of this session are deleted.")
    }
    .alert("Rename room", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Room name", text: $newRoomName)
      Button("Save") { if let room = renaming { perform { try HouseProject.renameRoom(houseID: houseID, roomID: room.id, name: newRoomName) } }; renaming = nil }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
    .confirmationDialog("Permanently delete this room?", isPresented: Binding(get: { permanentRoomID != nil }, set: { if !$0 { permanentRoomID = nil } }), titleVisibility: .visible) {
      Button("Delete permanently", role: .destructive) {
        if let id = permanentRoomID { perform { try HouseProject.permanentlyDeleteRoom(houseID: houseID, roomID: id) } }
        permanentRoomID = nil
      }
    } message: { Text("This cannot be undone. Shared recordings needed by other rooms are kept.") }
    .sheet(item: $sharing) { url in ShareSheet(items: [url]) }
  }

  // MARK: sections

  private func list(_ house: HouseProject) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Text(house.name).font(.largeTitle.weight(.bold)).tracking(-1)
          Text(house.rooms.count == 1 ? "1 room" : "\(house.rooms.count) rooms")
            .font(.title3).foregroundStyle(Fieldwork.secondary)
        }.padding(.top, 12).padding(.bottom, 28)
        FieldworkRule()
        if house.rooms.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "viewfinder").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Fieldwork.orange)
            Text("Every room starts here.").font(.title2.bold())
            Text("Scan a room to save its shape, details and photos. Add the rest of your house whenever you're ready.")
              .foregroundStyle(Fieldwork.secondary)
          }.padding(.vertical, 40)
        }
        ForEach(Array(house.rooms.enumerated()), id: \.element.id) { number, room in
          NavigationLink {
            FieldworkRoomScreen(houseID: house.id, roomID: room.id, generation: generation, onCapture: onCapture)
          } label: {
            roomRow(house, room, number: number + 1)
          }.buttonStyle(.plain)
          .contextMenu {
            Button("Rename", systemImage: "pencil") { newRoomName = room.name; renaming = room }
            Button("Delete room", systemImage: "trash", role: .destructive) { deletingRoom = room }
          }
          FieldworkRule()
        }
        if !house.sessions.isEmpty {
          DisclosureGroup {
            VStack(alignment: .leading, spacing: 22) {
              ForEach(house.sessions.sorted { $0.startedAt > $1.startedAt }) { session in
                sessionRow(house, session)
                FieldworkRule()
              }
            }.padding(.top, 18)
          } label: {
            Label("Sessions · \(house.sessions.count)", systemImage: "square.stack.3d.up")
              .font(.subheadline).foregroundStyle(Fieldwork.secondary)
          }.padding(.vertical, 24)
        }
        if !house.deletedRooms.isEmpty {
          FieldworkRule()
          DisclosureGroup {
            ForEach(house.deletedRooms) { entry in
              VStack(alignment: .leading, spacing: 12) {
                Text(entry.room.name).font(.headline)
                ViewThatFits(in: .horizontal) {
                  HStack { trashActions(entry.id) }
                  VStack(alignment: .leading) { trashActions(entry.id) }
                }
              }.padding(.vertical, 12)
            }
          } label: {
            Label("Recently Deleted", systemImage: "trash").font(.subheadline).foregroundStyle(Fieldwork.secondary)
          }.padding(.vertical, 24)
        }
      }.padding(.horizontal, 24).padding(.bottom, 20)
    }
    .safeAreaInset(edge: .bottom) {
      Button { onCapture(house.id, nil, nil, nil) } label: {
        Label("Scan a room", systemImage: "viewfinder")
      }.buttonStyle(FieldworkButtonStyle()).disabled(!CaptureController.isSupported)
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10).background(Fieldwork.paper)
    }
  }

  @ViewBuilder private func trashActions(_ id: String) -> some View {
    Button("Restore") { perform { try HouseProject.restoreRoom(houseID: houseID, roomID: id) } }.buttonStyle(.bordered)
    Button("Delete permanently", role: .destructive) { permanentRoomID = id }.buttonStyle(.bordered)
  }

  private func roomRow(_ house: HouseProject, _ room: HouseProject.Room, number: Int) -> some View {
    let folder = room.active.flatMap { house.session($0.session) }.map { house.bundle(for: $0).url }
    return Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          roomLabel(room, number: number)
          FieldworkThumbnail(folder: folder, index: room.active?.index ?? 0).frame(height: 180)
        }
      } else {
        HStack(spacing: 8) {
          roomLabel(room, number: number).frame(maxWidth: .infinity, alignment: .leading)
          FieldworkThumbnail(folder: folder, index: room.active?.index ?? 0).frame(width: 160, height: 160)
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(Fieldwork.secondary)
        }
      }
    }.padding(.vertical, 18).contentShape(Rectangle())
  }

  private func roomLabel(_ room: HouseProject.Room, number: Int) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      FieldworkEyebrow(text: String(format: "%02d", number))
      Text(room.name).font(.headline).foregroundStyle(Fieldwork.ink)
      if let active = room.active {
        Text(active.capturedAt.formatted(.dateTime.month(.abbreviated).day().year()))
          .font(.system(.caption, design: .monospaced)).foregroundStyle(Fieldwork.secondary)
        if let detail = record(active)?.photographedPercent {
          Text("\(detail)% photo detail").font(.caption).foregroundStyle(Fieldwork.secondary)
        }
      }
    }
  }

  private func sessionRow(_ house: HouseProject, _ s: HouseProject.Session) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(s.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.body)
        Spacer()
        AlignmentBadge(alignment: s.alignment)
      }
      let names = s.rooms.compactMap { i in manifests[s.id]?.rooms.first { $0.index == i }?.name ?? "Room \(i + 1)" }
      Text("\(names.isEmpty ? "no rooms" : names.joined(separator: ", "))\(s.endedAt == nil ? " · incomplete" : "")")
        .font(.footnote)
        .foregroundStyle(s.endedAt == nil ? .orange : .secondary)
      HStack {
        if !s.rooms.isEmpty {
          NavigationLink {
            HousePreviews.session(house, s)
          } label: {
            Label("Preview", systemImage: "cube")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        Button {
          share(house.bundle(for: s).url, name: "\(house.name) \(s.id)")
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Spacer()
        Button(role: .destructive) { deletingSession = s } label: {
          Image(systemName: "trash").frame(width: 44, height: 44)
        }.accessibilityLabel("Delete session")
      }
    }
    .padding(.vertical, 2)
  }

  // MARK: helpers

  private func perform(_ action: () throws -> Void) {
    do { try action(); reload() } catch { self.error = error.localizedDescription }
  }

  private func record(_ ref: HouseProject.RoomRef) -> RoomRecord? {
    manifests[ref.session]?.rooms.first { $0.index == ref.index }
  }

  private func reload() {
    guard let h = try? HouseProject.load(id: houseID) else {
      if FileManager.default.fileExists(atPath: HouseProject.url(forHouse: houseID).path) {
        error = "Couldn't read house.json."
      } else {
        onGone()
      }
      return
    }
    house = h
    let snapshot = h
    Task.detached(priority: .userInitiated) {
      var out: [String: Manifest] = [:]
      for s in snapshot.sessions { out[s.id] = snapshot.bundle(for: s).manifest }
      let loaded = out
      await MainActor.run { manifests = loaded }
    }
  }

  private func delete(_ s: HouseProject.Session) {
    do {
      try HouseProject.deleteSession(houseID: houseID, sessionID: s.id)
    } catch {
      self.error = error.localizedDescription
    }
    reload()
  }

  private func share(_ folder: URL, name: String) {
    busy = "Zipping…"
    Task.detached {
      let result = Result { try FolderZipper.zip(folder, name: name) }
      await MainActor.run {
        busy = nil
        switch result {
        case .success(let url): sharing = url
        case .failure(let err): error = err.localizedDescription
        }
      }
    }
  }
}
