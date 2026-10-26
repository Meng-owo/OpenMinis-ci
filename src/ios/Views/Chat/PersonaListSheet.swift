import SwiftUI

// MARK: - PersonaListSheet
//
// 人设列表：点一行就切换；每行可进编辑、复制、删除。
// 内置人设（小管家）不可删除；不许删到只剩一个。

struct PersonaListSheet: View {
    @ObservedObject var store: PersonaStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingPersona: Persona?
    @State private var newName = ""
    @State private var showNewAlert = false
    @State private var deleteTarget: Persona?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.chatSelectablePersonas) { persona in
                    Button {
                        store.setCurrent(persona.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PersonaAvatarView(iconRef: persona.avatar, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(persona.name)
                                        .font(.body)
                                    if persona.isBuiltIn {
                                        Text("内置")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                            .foregroundStyle(MinisTheme.secondaryText)
                                    }
                                }
                                if persona.id == store.currentPersonaID {
                                    Text("当前使用中")
                                        .font(.caption)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                            Spacer()
                            if persona.id == store.currentPersonaID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !persona.isBuiltIn {
                            Button(role: .destructive) {
                                deleteTarget = persona
                            } label: {
                                Label("删除", systemImage: "trash.fill")
                            }
                            .disabled(store.chatSelectablePersonas.count <= 1)
                        }
                        Button {
                            if let copy = store.duplicatePersona(persona.id) {
                                editingPersona = copy
                            }
                        } label: {
                            Label("复制", systemImage: "doc.on.doc.fill")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            editingPersona = persona
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        Button {
                            if let copy = store.duplicatePersona(persona.id) {
                                editingPersona = copy
                            }
                        } label: {
                            Label("复制", systemImage: "doc.on.doc.fill")
                        }
                        if !persona.isBuiltIn && store.chatSelectablePersonas.count > 1 {
                            Button(role: .destructive) {
                                deleteTarget = persona
                            } label: {
                                Label("删除", systemImage: "trash.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("人设")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("新建人设", isPresented: $showNewAlert) {
                TextField("名字", text: $newName)
                Button("取消", role: .cancel) { newName = "" }
                Button("创建") {
                    let created = store.addPersona(name: newName)
                    newName = ""
                    editingPersona = created
                }
            }
            .alert("删除人设？", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    if let t = deleteTarget { store.deletePersona(t.id) }
                    deleteTarget = nil
                }
            } message: {
                Text("「\(deleteTarget?.name ?? "")」的聊天记录和记忆会一起删掉，这个删了就回不来了。")
            }
            .sheet(item: $editingPersona) { persona in
                PersonaSettingsView(store: store, personaID: persona.id)
            }
        }
    }
}
