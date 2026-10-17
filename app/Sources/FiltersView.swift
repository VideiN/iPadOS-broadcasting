import SwiftUI

/// 소스의 필터 목록 (Core/scenes.c의 core_filters_json), 적용 순서대로
struct SourceFilters: Decodable {
    struct Filter: Decodable, Hashable {
        let name: String
        let id: String
        let type_name: String
        let enabled: Bool
    }

    let filters: [Filter]
}

/// 소스에 넣을 수 있는 필터 종류 (core_filter_types_json)
struct FilterTypes: Decodable {
    struct FilterType: Decodable, Hashable {
        let id: String
        let name: String
    }

    let types: [FilterType]
}

/// 소스의 오디오 필터: 추가·삭제·순서·켜기/끄기. 누르면 그 필터의 설정 (속성 편집기를 그대로 쓴다)
struct FiltersView: View {
    let sourceName: String
    var onChange: () -> Void = {}

    @State private var filters: [SourceFilters.Filter] = []
    @State private var types: [FilterTypes.FilterType] = []

    /// 속성 편집기에 넘기는 필터 이름: "소스" + U+001F + "필터"
    static func path(source: String, filter: String) -> String {
        source + "\u{1F}" + filter
    }

    var body: some View {
        List {
            Section {
                if filters.isEmpty {
                    Text("필터가 없습니다. 오른쪽 위 + 로 넣습니다.").foregroundStyle(.secondary)
                }
                ForEach(filters, id: \.name) { filter in
                    HStack(spacing: 12) {
                        Toggle(
                            "켜기",
                            isOn: Binding(get: { filter.enabled }, set: { setEnabled(filter, $0) })
                        )
                        .labelsHidden()

                        NavigationLink {
                            SourcePropertiesView(sourceName: Self.path(source: sourceName, filter: filter.name), onChange: onChange)
                                .navigationTitle(filter.name)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(filter.name)
                                if filter.name != filter.type_name {
                                    Text(filter.type_name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .contextMenu {
                        Button("위로", systemImage: "chevron.up") { move(filter, by: -1) }
                        Button("아래로", systemImage: "chevron.down") { move(filter, by: 1) }
                        Divider()
                        Button("삭제", systemImage: "trash", role: .destructive) { remove(filter) }
                    }
                    .swipeActions {
                        Button("삭제", role: .destructive) { remove(filter) }
                    }
                }
            } footer: {
                Text("위에 있는 필터부터 차례로 적용됩니다. 길게 누르면 순서를 바꾸거나 지울 수 있습니다.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(types, id: \.id) { type in
                        Button(type.name) { add(type) }
                    }
                } label: {
                    Label("필터 추가", systemImage: "plus")
                }
                .disabled(types.isEmpty)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        filters = decodeCoreJSON(core_filters_json(sourceName), as: SourceFilters.self)?.filters ?? []
        types = decodeCoreJSON(core_filter_types_json(sourceName), as: FilterTypes.self)?.types ?? []
    }

    private func add(_ type: FilterTypes.FilterType) {
        if core_filter_add(sourceName, type.id) { changed() }
    }

    private func remove(_ filter: SourceFilters.Filter) {
        core_filter_remove(sourceName, filter.name)
        changed()
    }

    private func setEnabled(_ filter: SourceFilters.Filter, _ enabled: Bool) {
        core_filter_set_enabled(sourceName, filter.name, enabled)
        changed()
    }

    private func move(_ filter: SourceFilters.Filter, by direction: Int32) {
        core_filter_move(sourceName, filter.name, direction)
        changed()
    }

    private func changed() {
        reload()
        onChange()
    }
}
