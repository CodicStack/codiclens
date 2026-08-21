import SwiftUI

/// The Results Slab in grid Mode.
///
/// Deliberately plain. The visual language — Liquid Glass, radii, the
/// mode-aware slab — arrives in a later phase and will replace everything
/// cosmetic in here. What has to be right now is the data, the keyboard model,
/// and the cell geometry.
struct EmojiGridView: View {
    @Bindable var coordinator: CommandCoordinator

    /// Apple Color Emoji has bitmap strikes at 20/26/32/40/48px. Anything
    /// between them resamples and reads soft, so the glyph is pinned to 32.
    private static let glyphSize: CGFloat = 32

    /// The cell is sized explicitly rather than left to intrinsic sizing: at
    /// point size 32 an emoji line is 42pt tall against the system font's 37.7,
    /// so intrinsic emoji cells come out taller than text cells and the grid
    /// goes ragged.
    private static let cellSize: CGFloat = 40

    private var vm: EmojiSearchVM { coordinator.emojiVM }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(Self.cellSize), spacing: 2),
            count: EmojiSearchVM.columnCount
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isTonePickerOpen {
                tonePicker
            }
            grid
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(vm.sections.enumerated()), id: \.element.id) { number, section in
                        Section {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(Array(section.emoji.enumerated()), id: \.element.id) { offset, emoji in
                                    let flatIndex = vm.start(of: number) + offset
                                    cell(emoji, isSelected: flatIndex == vm.selectedIndex)
                                        .id(flatIndex)
                                        .onTapGesture {
                                            vm.selectedIndex = flatIndex
                                            coordinator.submit()
                                        }
                                }
                            }
                        } header: {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 260)
            .onChange(of: vm.selectedIndex) { _, index in
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func cell(_ emoji: Emoji, isSelected: Bool) -> some View {
        Text(emoji.string)
            .font(.system(size: Self.glyphSize))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }

    /// The six-tone override, opened with ⌥Enter on an Emoji that takes tones.
    private var tonePicker: some View {
        HStack(spacing: 2) {
            ForEach(Array(vm.tonePickerChoices.enumerated()), id: \.offset) { offset, choice in
                Text(choice.string)
                    .font(.system(size: Self.glyphSize))
                    .frame(width: Self.cellSize, height: Self.cellSize)
                    .background(offset == vm.toneIndex ? Color.accentColor.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.toneIndex = offset
                        coordinator.submit()
                    }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
