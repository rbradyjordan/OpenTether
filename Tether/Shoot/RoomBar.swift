import SwiftUI
import TetherCore

/// The listing's rooms as a chip strip above the filmstrip: tap one before
/// shooting it and every frame that lands is filed under it. Counts show
/// what's covered; "Next" walks the list in order.
struct RoomBar: View {
    @Bindable var model: ShootViewModel
    @Binding var showRooms: Bool

    var body: some View {
        if let list = model.roomList {
            HStack(spacing: TetherSpace.s) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TetherSpace.xs) {
                            ForEach(list.rooms) { room in
                                chip(room, count: model.roomCounts[room.slug] ?? 0, selected: room.slug == model.currentRoom)
                                    .id(room.slug)
                            }
                        }
                        .padding(.horizontal, TetherSpace.m)
                    }
                    .onChange(of: model.currentRoom) { _, slug in
                        if let slug { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(slug, anchor: .center) } }
                    }
                }
                coverage(list)
                Button { model.nextRoom() } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TetherColor.ink0)
                        .frame(width: TetherHit.min, height: TetherHit.min)
                        .tetherGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Next room")
                .padding(.trailing, TetherSpace.s)
            }
            .frame(height: 48)
            .background(TetherColor.surface0)
            .overlay(alignment: .top) { Rectangle().fill(TetherColor.hairline).frame(height: 0.5) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rooms")
        }
    }

    private func chip(_ room: RoomShotList.Room, count: Int, selected: Bool) -> some View {
        Button { model.selectRoom(selected ? nil : room.slug) } label: {
            HStack(spacing: 6) {
                if count > 0 {
                    Image(systemName: room.target > 0 && count >= room.target ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? TetherColor.ink0 : TetherColor.ok)
                }
                Text(room.name).font(TetherFont.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                if count > 0 {
                    Text("\(count)").font(TetherFont.hud).foregroundStyle(selected ? TetherColor.ink0.opacity(0.8) : TetherColor.ink1)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(selected ? TetherColor.ink0 : (count > 0 ? TetherColor.ink1 : TetherColor.ink0))
            .padding(.horizontal, TetherSpace.m)
            .frame(minHeight: 34)
            .background(selected ? TetherColor.accent : Color.clear, in: Capsule())
            .tetherGlass(in: Capsule(), interactive: !selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(room.name), \(count) frames\(selected ? ", shooting now" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button { showRooms = true } label: { Label("Edit shot list…", systemImage: "list.bullet") }
        }
    }

    private func coverage(_ list: RoomShotList) -> some View {
        let c = list.coverage(counts: model.roomCounts)
        return Button { showRooms = true } label: {
            VStack(spacing: 1) {
                Text("\(c.covered)/\(c.total)").font(TetherFont.hud.weight(.semibold)).foregroundStyle(c.covered == c.total ? TetherColor.ok : TetherColor.ink0)
                    .contentTransition(.numericText())
                Text("rooms").font(.system(size: 9, weight: .medium)).foregroundStyle(TetherColor.ink2)
            }
            .frame(minWidth: 44, minHeight: TetherHit.min)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.covered) of \(c.total) rooms covered. Edit shot list")
    }
}

/// Edit the listing's rooms: reorder, rename, add, start from a preset, or
/// turn the list off for this session.
struct RoomsSheet: View {
    @Bindable var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [RoomShotList.Room] = []
    @State private var newRoom = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($rooms) { $room in
                        HStack {
                            TextField("Room", text: $room.name)
                            Spacer()
                            let count = model.roomCounts[room.slug] ?? 0
                            if count > 0 { Text("\(count)").font(TetherFont.hud).foregroundStyle(TetherColor.ink1) }
                        }
                    }
                    .onDelete { rooms.remove(atOffsets: $0) }
                    .onMove { rooms.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("Add a room", text: $newRoom)
                            .onSubmit(add)
                        Button(action: add) { Image(systemName: "plus.circle.fill") }
                            .disabled(newRoom.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("Add room")
                    }
                } header: { Text("Rooms, in walking order") } footer: {
                    Text("Tap a room on the shoot screen before shooting it; every frame is filed under it and exports as Address_Room_01.jpg.")
                }
                Section("Start from") {
                    ForEach(RoomShotList.presets, id: \.name) { preset in
                        Button(preset.name) { rooms = preset.list.rooms }
                    }
                }
                Section {
                    Button("Turn off the shot list for this session", role: .destructive) {
                        model.setRoomList(nil)
                        dismiss()
                    }
                }
            }
            .tetherList()
            .navigationTitle("Shot list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let cleaned = rooms.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                        model.setRoomList(RoomShotList(rooms: cleaned))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .onAppear { rooms = model.roomList?.rooms ?? RoomShotList.listing.rooms }
        }
        .forceDark()
    }

    private func add() {
        let name = newRoom.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        rooms.append(RoomShotList.Room(name: name))
        newRoom = ""
    }
}
