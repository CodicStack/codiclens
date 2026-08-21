import SwiftUI

/// The Results Slab in grid Mode.
///
/// Everything cosmetic here comes from `Style.swift`: a cell is a Result, so it
/// wears the same `resultSurface(selected:)` as a row in the list Mode, and the
/// section headers and the tone picker use the same chip the list header's
/// keyboard hints do. Nothing in this file holds a radius or a colour.
///
/// Two numbers are measurements rather than taste and are not tokens: the glyph
/// strike and the cell frame, both explained below.
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
                Divider().padding(.horizontal, Style.padding)
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
                                    // The cell draws the Emoji in the user's
                                    // default Skin Tone, which is what the
                                    // Subject Card shows and what Enter pastes.
                                    // Drawing the untoned base here made the
                                    // Card look like it was showing a different
                                    // emoji — see `EmojiSearchVM.displayed`.
                                    // Selection, order and identity are still
                                    // the base's: a variant is never a Result.
                                    cell(vm.displayed(emoji), isSelected: flatIndex == vm.selectedIndex)
                                        .id(flatIndex)
                                        .onTapGesture {
                                            vm.selectedIndex = flatIndex
                                            coordinator.submit()
                                        }
                                }
                            }
                        } header: {
                            sectionHeader(section.title)
                        }
                    }
                }
                .padding(.horizontal, Style.rowPaddingH)
                .padding(.bottom, Style.resultInset)
            }
            .frame(maxHeight: 260)
            .onChange(of: vm.selectedIndex) { _, index in
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    /// Pinned, so cells scroll underneath it. The chip is what keeps the title
    /// legible while they do — a bare label over passing glyphs is unreadable.
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .chipSurface()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func cell(_ emoji: Emoji, isSelected: Bool) -> some View {
        Text(emoji.string)
            .font(.system(size: Self.glyphSize))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .resultSurface(selected: isSelected)
    }

    /// The six-tone override, opened with ⌥Enter on an Emoji that takes tones.
    private var tonePicker: some View {
        HStack(spacing: 2) {
            ForEach(Array(vm.tonePickerChoices.enumerated()), id: \.offset) { offset, choice in
                Text(choice.string)
                    .font(.system(size: Self.glyphSize))
                    .frame(width: Self.cellSize, height: Self.cellSize)
                    .resultSurface(selected: offset == vm.toneIndex)
                    .onTapGesture {
                        vm.toneIndex = offset
                        coordinator.submit()
                    }
            }
            Spacer()
        }
        .padding(.horizontal, Style.rowPaddingH)
        .padding(.vertical, Style.resultInset)
    }
}
