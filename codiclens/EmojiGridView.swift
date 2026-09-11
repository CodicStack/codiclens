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

    /// Apple Color Emoji has bitmap strikes at 20/26/32/40/48/64px. Anything
    /// between them resamples and reads soft, so the glyph is pinned to 32.
    private static let glyphSize: CGFloat = 32

    /// The cell is sized explicitly rather than left to intrinsic sizing: at
    /// point size 32 an emoji line is 42pt tall against the system font's 37.7,
    /// so intrinsic emoji cells come out taller than text cells and the grid
    /// goes ragged.
    private static let cellSize: CGFloat = 40

    /// Between two cells, and between one section's block and the next.
    private static let cellSpacing: CGFloat = 2
    private static let sectionSpacing: CGFloat = 4

    /// A pinned section heading: the chip, plus the padding around it.
    ///
    /// Rounded up rather than measured, for the same reason as
    /// `PanelLayout.resultsHeaderHeight`: it is added to what the grid asks for,
    /// and asking for a couple of points more than the rows need costs a couple
    /// of points of slack inside a scrolling area, while asking for less would
    /// scroll a grid that fits — and clip the bottom row of cells doing it.
    private static let sectionHeaderHeight: CGFloat = 26

    /// The Skin Tone picker and its divider — fixed furniture above the grid,
    /// which the grid's ceiling has to leave room for while it is open.
    private static let tonePickerHeight: CGFloat =
        cellSize + Style.resultInset * 2 + Style.hairline

    private var vm: EmojiSearchVM { coordinator.emojiVM }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(Self.cellSize), spacing: Self.cellSpacing),
            count: EmojiSearchVM.columnCount
        )
    }

    /// The height the grid's content wants, for sections holding these many
    /// cells each.
    ///
    /// Arithmetic rather than a measurement, because the Slab is sized to it:
    /// fixed cells in a fixed number of columns, one heading per section, and
    /// the stack's spacing between them. Asking SwiftUI instead would mean
    /// proposing an unspecified height to a `LazyVStack`, which is how you make
    /// a lazy container build all 1,914 cells to answer.
    static func contentHeight(sectionCellCounts: [Int]) -> CGFloat {
        guard !sectionCellCounts.isEmpty else { return 0 }
        var total: CGFloat = 0
        for count in sectionCellCounts {
            let perRow = EmojiSearchVM.columnCount
            let rows = CGFloat((max(count, 0) + perRow - 1) / perRow)
            let cells = rows * cellSize + max(rows - 1, 0) * cellSpacing
            // The heading, the stack's spacing under it, and the rows.
            total += sectionHeaderHeight + sectionSpacing + cells
        }
        // The spacing between one section's block and the next, and the inset
        // under the last row.
        return total + CGFloat(sectionCellCounts.count - 1) * sectionSpacing + Style.resultInset
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

    /// The cells, in an area as tall as the cells are — up to what is left of
    /// the Slab once the Query field and any open Skin Tone picker have had
    /// theirs. Ten matching Emoji make two rows and a short Slab.
    private var grid: some View {
        let height = PanelLayout.resultsAreaHeight(
            contentHeight: Self.contentHeight(sectionCellCounts: vm.sections.map(\.emoji.count)),
            chromeHeight: vm.isTonePickerOpen ? Self.tonePickerHeight : 0
        )

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: Self.sectionSpacing,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(Array(vm.sections.enumerated()), id: \.element.id) { number, section in
                        Section {
                            LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
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
                // The area's size springs; the cells inside it do not.
                .hardCut()
            }
            .frame(height: height)
            // A Slab following its content is a surface changing size, which is
            // what `resize` is for. Keyed to the height, so it is the height and
            // nothing else that animates: moving the selection cannot change
            // this value, so the highlight still lands on the frame the key was
            // pressed.
            .animation(Motion.resize, value: height)
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
    /// `tonePickerHeight` is this: one cell row, its inset, and the divider
    /// under it.
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
