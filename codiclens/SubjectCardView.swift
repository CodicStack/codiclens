import SwiftUI
import UniformTypeIdentifiers

struct SubjectCardView: View {
    @Bindable var coordinator: CommandCoordinator

    /// The Card row's glass namespace, so this Card's glass is the one the
    /// Action Card grows out of.
    let glassNamespace: Namespace.ID

    @FocusState private var isEditorFocused: Bool

    /// The editor's caret. Put at the end as the editor opens, so ⌘E on a
    /// Query carries on typing where the Query left off.
    @State private var editorSelection: TextSelection?

    @FocusState private var isRenameFocused: Bool

    /// The name editor's selection: the name without its extension, set once
    /// the field has focus.
    @State private var renameSelection: TextSelection?

    /// Whether the Query is still the question being asked.
    ///
    /// This is the distinction the Card turns on, and it decides two separate
    /// things: whether the Card *follows the selection* or *names the chosen
    /// Subject*, and whether the displayed name is marked up against the Query
    /// at all. The Phases where the Query is still live happen to be exactly the
    /// Phases where this Card holds the keyboard, which is why `isFocused` is
    /// the same set — if the two ever come apart, they come apart here.
    private var isQueryPhase: Bool {
        switch coordinator.phase {
        case .searchingSubject, .browsingClipboard, .browsingEmoji: true
        default: false
        }
    }

    /// Renaming is the exception: the name editor holds the keyboard on the
    /// Action Phase, so Emphasis comes to this Card for as long as it is open.
    private var isFocused: Bool { isQueryPhase || coordinator.isRenaming }

    /// Whether the Card is holding text rather than naming something, which is
    /// the one case that needs a near-solid ground to stay readable.
    private var isWriting: Bool {
        isClipboardText || previewedText != nil
    }

    /// What the Card is about — and it is two different things by Phase.
    ///
    /// While the Query is still the question, the Card previews the highlighted
    /// Result, so it reads `subjectVM.cardSubject` and moves as the selection
    /// moves — and between a keystroke and its answer it keeps what it showed,
    /// never blank. Once a Subject has been **chosen**, the Card is about that
    /// Subject and the Query's matches are no longer what it is showing.
    ///
    /// Those are not the same value, and reading only the first is how "Use as
    /// Subject" left Finder sitting on the Card after promoting a file out of
    /// it: the promotion writes `selectedSubject`, while `subjectVM.results`
    /// still holds whatever the Query matched. `retargetedText` already solved
    /// exactly this for OCR Text and a transform's output — but only for a
    /// `.text` Subject, and a promoted file or app is not one, so it fell
    /// straight through to the stale Result.
    ///
    /// The Last Subject is a Query Phase's exception: it stands with the Query
    /// empty and was never a Result, so it is read from the coordinator.
    private var subject: Subject? {
        if !isQueryPhase, let chosen = coordinator.selectedSubject { return chosen }
        if let standing = coordinator.standingSubject { return standing }
        return coordinator.subjectVM.cardSubject
    }

    /// The text of a text Subject: OCR Text or a transform's output once
    /// chosen, or a Query turned into text with ⌘E.
    ///
    /// A text Subject is *previewed* rather than named, so the Card needs the
    /// string and not the Subject. The editor's insets are measured against
    /// `textPreview`, so the text does not jump as ⌘E opens or saves it.
    private var previewedText: String? {
        guard case .text(let rawText)? = subject?.kind else { return nil }
        return rawText
    }

    /// The Subject search Result under the selection, or the one held while
    /// the Query is out, while the Query is the question. A Clipboard Item or
    /// an Emoji from the list below the apps is previewed as its own Mode
    /// previews it.
    private var searchedResult: Subject? {
        guard coordinator.phase == .searchingSubject, coordinator.standingSubject == nil else { return nil }
        return coordinator.subjectVM.cardSubject
    }

    private var isClipboardMode: Bool {
        coordinator.isClipboardBrowsing
            || (coordinator.phase == .pickingAction && coordinator.selectedClipboardItem != nil)
            || coordinator.standingSubject?.clipboardItem != nil
            || searchedResult?.clipboardItem != nil
    }

    private var isClipboardText: Bool {
        if isClipboardMode, let item = clipboardItem, !item.isImage { return true }
        if coordinator.isEditingTextSubject { return true }
        return false
    }

    private var clipboardItem: ClipboardItem? {
        if let item = coordinator.standingSubject?.clipboardItem { return item }
        if let item = searchedResult?.clipboardItem { return item }
        if let item = coordinator.selectedClipboardItem,
           (coordinator.phase == .pickingAction || coordinator.phase == .browsingClipboard) {
            return item
        }
        return coordinator.currentClipboardItem
    }

    /// **A `ZStack`, never a `Group`.** A `Group` hands its modifiers to each
    /// view inside it, so the glass belonged to whichever branch was showing:
    /// "Type..." giving way to FindMy, or one Subject to the next (`.id`),
    /// took the glass away and put a new one in. The first keystroke does that
    /// inside the Slab's arriving animation, and the Card's glass, content and
    /// all, was gone for the length of it. Here the glass is the stack's and
    /// stays; only what is in it changes, and that hard-cuts.
    var body: some View {
        ZStack {
            if case .showingResult(let result) = coordinator.phase {
                resultPreview(result)
            } else if coordinator.isEditingTextSubject {
                textSubjectEditor
            } else if coordinator.isRenaming, let subject {
                renameEditor(subject)
            } else if isClipboardMode {
                clipboardPreview
            } else if coordinator.isEmojiBrowsing {
                emojiContent(coordinator.currentEmoji, query: coordinator.emojiVM.searchText)
            } else if let emoji = coordinator.standingSubject?.emoji {
                emojiContent(emoji, query: "")
            } else if let emoji = searchedResult?.emoji {
                emojiContent(emoji, query: coordinator.subjectVM.searchText)
            } else if let previewedText {
                textPreview(previewedText)
            } else if let subject {
                subjectContent(subject)
            } else {
                placeholder
            }
        }
        .hardCut()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { corner }
        .cardSurface(focused: isFocused, writing: isWriting, phase: .subject, in: glassNamespace)
        .padding(Style.cardInset)
    }

    /// The Card's bottom-trailing corner: what it holds, and what acts on it.
    private var corner: some View {
        HStack(spacing: 4) {
            if let note = coordinator.fileOperationNote ?? coordinator.transcriptionNote ?? coordinator.momentOpenNote {
                Text(note)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .chipSurface()
            }
            // Without Codictate, the next Enter on Transcribe opens its
            // website; the key says so beside the note.
            if coordinator.transcriptionFailure?.offersDownload == true {
                KeyHintChip(keys: "⏎")
            }
            if let characterCount {
                Text("\(characterCount) chars")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .chipSurface()
            }
            if let keyHint {
                KeyHintChip(keys: keyHint)
            }
        }
        .padding(Style.padding)
    }

    /// Shown wherever the Card is previewing text rather than naming
    /// something: how long the thing being previewed actually is. A page of OCR
    /// Text needs that as much as a clipboard entry does.
    private var characterCount: Int? {
        guard !coordinator.isEditingTextSubject else { return nil }
        if let previewedText { return previewedText.count }
        guard isClipboardMode, let item = clipboardItem, !item.isImage else { return nil }
        return item.content.count
    }

    /// The key that acts on this Card. Only while the Card has the keyboard, and
    /// only when there is something for the key to act on.
    private var keyHint: String? {
        // Editing is the one case where the Card holds the keyboard without
        // being the focused Card of the Phase — the editor has it, wherever the
        // Phase happens to be — so this is asked before `isFocused`.
        if coordinator.isEditingTextSubject { return "⌘E" }
        if coordinator.isRenaming { return "⏎" }
        guard isFocused else { return nil }
        // A text preview already says what it is with its count; the Return chip beside it was noise.
        if characterCount != nil { return nil }
        if coordinator.isEmojiBrowsing { return coordinator.currentEmoji == nil ? nil : "⏎" }
        if isClipboardMode { return clipboardItem == nil ? nil : "⏎" }
        return subject == nil ? nil : "⏎"
    }

    /// The Card in Emoji Mode: the glyph where an app icon would be, its CLDR
    /// name where an app name would be, so the Card reads the same either way.
    ///
    /// The glyph goes through `EmojiRenderer` rather than a large `Text`.
    /// Apple Color Emoji is a bitmap font, so an off-strike point size resamples
    /// and reads soft. The renderer picks the nearest strike for the icon slot
    /// the other Cards use, which keeps the Card's metrics identical whether it
    /// holds an app icon or a glyph. The grid's selection, the Last Subject, or
    /// an Emoji row in Subject search.
    @ViewBuilder
    private func emojiContent(_ emoji: Emoji?, query: String) -> some View {
        if let emoji {
            VStack(spacing: 10) {
                Image(nsImage: EmojiRenderer.image(for: emoji.string, box: Style.cardIcon))
                    .frame(width: Style.cardIcon, height: Style.cardIcon)

                // Marked up like an app name, and for the same reason: the Card
                // shows what the Query matched, so it should show *where*. An
                // Emoji found by a keyword has nothing to mark up in its CLDR
                // name, and `highlightedName` leaves that plain rather than
                // underlining the characters that happen to line up.
                Text(highlightedName(emoji.name, query: query))
                    .font(.system(size: 15, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, Style.padding)
        } else {
            placeholder
        }
    }

    private func resultPreview(_ result: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.green)

            Text(result)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(3)
                .foregroundStyle(.primary)

            Text("⏎ to copy")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var clipboardPreview: some View {
        if let item = clipboardItem {
            if let imageURL = coordinator.clipboardVM.imageURL(for: item),
               let nsImage = NSImage(contentsOf: imageURL) {
                // The stored PNG itself, not a thumbnail of it, edge to edge
                // like a file's picture. No caption: a Clipboard Image's name
                // says nothing the picture does not.
                CardPicture(image: nsImage, captioned: false)
            } else {
                ScrollView {
                    Text(item.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "clipboard")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("No items")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    /// The editor for a text Subject, wherever it is being edited from — the
    /// Clipboard browser, OCR Text, a transform's output.
    private var textSubjectEditor: some View {
        TextEditor(text: $coordinator.textSubjectEditText, selection: $editorSelection)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($isEditorFocused)
            // `textPreview` pads 20. An `NSTextView` adds its own line-fragment
            // padding and a top inset, so these are what land the first glyph on
            // the preview's — measured on screen, not derived; anything else
            // makes the text jump on ⌘E.
            .padding(.horizontal, 15)
            .padding(.vertical, 20)
            .onKeyPress { press in
                if press.key == .tab && press.modifiers.isEmpty {
                    coordinator.saveTextSubjectEditAndAdvance()
                    return .handled
                }
                if (press.modifiers.contains(.command) && press.characters == "e")
                    || (press.modifiers.contains(.control) && (press.characters == "e" || press.characters == "\u{05}")) {
                    coordinator.toggleTextSubjectEdit()
                    return .handled
                }
                if press.key == .escape {
                    _ = coordinator.handleEscape()
                    isEditorFocused = false
                    return .handled
                }
                return .ignored
            }
            // Focus has to be taken *after* the update that inserted the editor
            // has committed — assigning it during that update is dropped,
            // because the text view it would move focus to does not exist yet.
            // `task` is the event that says "committed": it starts on the main
            // actor once the view is in the hierarchy. It replaces a fixed
            // 0.1-second delay that was guessing at the same moment.
            .task {
                let text = coordinator.textSubjectEditText
                editorSelection = TextSelection(insertionPoint: text.endIndex)
                isEditorFocused = true
            }
    }

    /// A block of text the Card is holding, scrollable because OCR Text can be
    /// a page of it.
    private func textPreview(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func subjectIcon(_ subject: Subject) -> some View {
        ThumbnailImage(url: subject.thumbnailURL, side: Style.cardIcon) {
            Image(nsImage: subject.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
        .frame(width: Style.cardIcon, height: Style.cardIcon)
        // Rotate rewrites the file under the same URL and answers with a
        // fresh Subject; a fresh view is what checks the file again.
        .id(subject.id)
    }

    /// Rename: the name in an editor where it is shown, as Finder edits a name
    /// in place. Enter or ⌘E renames, Escape leaves it as it was.
    private func renameEditor(_ subject: Subject) -> some View {
        VStack(spacing: 10) {
            subjectIcon(subject)

            TextField("", text: $coordinator.renameText, selection: $renameSelection)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .bold))
                .multilineTextAlignment(.center)
                .focused($isRenameFocused)
                .onSubmit { coordinator.commitRename() }
                .onKeyPress { press in
                    if (press.modifiers.contains(.command) && press.characters == "e")
                        || (press.modifiers.contains(.control) && ControlKey.letter(press.characters) == "e") {
                        coordinator.commitRename()
                        return .handled
                    }
                    if press.key == .escape {
                        coordinator.cancelRename()
                        return .handled
                    }
                    return .ignored
                }
                // A text field selects all of itself as it takes focus, so the
                // base name is selected once it has — not before, where the
                // select-all would land on top of it.
                .onChange(of: isRenameFocused) { _, focused in
                    guard focused else { return }
                    renameSelection = TextSelection(range: coordinator.renameSelectedRange)
                }
                // Focus after the update that inserted the field has committed,
                // as the text editor takes it.
                .task { isRenameFocused = true }
        }
        .padding(.horizontal, Style.padding)
    }

    /// A Subject named on the Card: its icon with its name under it, or — once
    /// Quick Look has drawn what the file holds — that picture, edge to edge,
    /// with the name over its bottom edge.
    ///
    /// The picture is asked for at the Card's own size (`Style.cardSide`),
    /// not the icon's, large enough to cover it, and it replaces the icon
    /// layout the frame it lands — no fade. Everything that is its icon (an
    /// app, a folder, a file Quick Look cannot draw) never gets one and keeps
    /// the icon layout.
    ///
    /// A File Result that matched inside the file shows where (`CardPassage`):
    /// the matched PDF page or video frame as the picture, or the excerpt
    /// with its matched words underlined over the name.
    private func subjectContent(_ subject: Subject) -> some View {
        let passage = CardPassage(subject)
        return ThumbnailReader(url: subject.thumbnailURL, side: Style.cardSide, fills: true,
                               moment: passage?.moment) { thumbnail in
            if let thumbnail {
                CardPicture(
                    image: thumbnail,
                    captioned: true,
                    scrimHeight: passage == nil ? Style.pictureScrimHeight : Style.passageScrimHeight
                )
                .overlay(alignment: .bottom) { pictureCaption(subject, passage: passage) }
            } else {
                VStack(spacing: passage == nil ? 10 : 8) {
                    Image(nsImage: subject.icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: passage == nil ? Style.cardIcon : Style.passageIcon,
                            height: passage == nil ? Style.cardIcon : Style.passageIcon
                        )

                    subjectName(subject)
                        .foregroundStyle(.primary)

                    if let passage {
                        Text(passage.line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, passage == nil ? 0 : Style.padding)
            }
        }
        // Rotate rewrites the file under the same URL and answers with a
        // fresh Subject; a fresh view is what checks the file again.
        .id(subject.id)
    }

    /// The name over a picture: along its bottom edge, leading, on the
    /// picture's scrim.
    ///
    /// The corner chips sit on the same line, drawn by the Card's own overlay.
    /// A hidden copy of `corner` holds their place here, so a long name stops
    /// short of them instead of running underneath — whatever the corner holds
    /// at the time, a ⏎ or a "Moving…". The corner's own padding is the gap
    /// between the two, so the name has none on its trailing side.
    ///
    /// Truncated in the middle, as Finder truncates a file name: what is
    /// pictured here is always a file, and its extension is worth keeping.
    ///
    /// A Passage's line goes above the name, the Card's full width: the
    /// corner's stand-in has no height, so the line sits on the name whether
    /// or not the corner holds a chip.
    private func pictureCaption(_ subject: Subject, passage: CardPassage?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let passage {
                Text(passage.line)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Style.padding)
            }
            HStack(alignment: .bottom, spacing: 0) {
                subjectName(subject)
                    .truncationMode(.middle)
                    .padding([.leading, .bottom], Style.padding)
                Spacer(minLength: 0)
                corner.hidden().frame(height: 0)
            }
        }
        .foregroundStyle(Style.pictureCaption)
    }

    /// Marked up only where the name is what the Query matched. A promoted or
    /// chosen Subject is not, and underlining the characters of `find` that
    /// happen to line up in a file it was found through would be marking a
    /// match that never happened.
    private func subjectName(_ subject: Subject) -> some View {
        Text(
            highlightedName(
                subject.displayName,
                query: isQueryPhase ? coordinator.subjectVM.searchText : ""
            )
        )
        .font(.system(size: 15, weight: .bold))
        .lineLimit(1)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.quaternary)

            Text(placeholderMessage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }

    /// What an empty Card says, and it must not claim more than it knows.
    ///
    /// "No match" is a finding, and the Card is only entitled to it once the
    /// Query has been answered — by the app Index and by the list below the
    /// apps. Before that it has not been looked up, so the Card is still
    /// waiting rather than reporting.
    private var placeholderMessage: String {
        if coordinator.subjectVM.searchText.isEmpty { return "Type..." }
        return coordinator.subjectVM.hasAnswered ? "No match" : "Searching…"
    }
}


/// A picture filling a Card edge to edge: a file's thumbnail, or a Clipboard
/// Image. It is the Card's **content**, so it is laid out in the frame the
/// Card's glass is drawn in and steps back with the rest of the content when
/// the Card is unfocused.
///
/// Aspect-fill, centred, and clipped to `Style.pictureShape` — the picture is
/// clipped, never the glass. With `captioned`, `Style.pictureScrim` darkens its
/// bottom edge for the name drawn over it; the scrim is part of the picture,
/// under the same clip.
struct CardPicture: View {
    let image: NSImage
    let captioned: Bool
    /// How far up the scrim reaches: further when a Passage's lines sit over
    /// the name.
    var scrimHeight = Style.pictureScrimHeight

    var body: some View {
        // `Color.clear` takes the size it is offered and the image fills it;
        // a `scaledToFill` image laid out on its own would size the Card to the
        // picture instead.
        Color.clear
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
            .overlay(alignment: .bottom) {
                if captioned {
                    Style.pictureScrim
                        .frame(height: scrimHeight)
                }
            }
            .clipShape(Style.pictureShape)
    }
}


/// What of a File Result's Passage the Subject Card shows, by what the file is.
///
/// A PDF: the matched page as the picture, and "page 4". A video: the frame
/// at its second, and "at 14:02"; a recording: its picture as ever, and the
/// moment. An image: nothing — its picture is the thing, whatever OCR read in
/// it. Anything else is words: the excerpt, its literally matched words
/// underlined, as the Result's row marks them. One found by meaning alone has
/// no marks, and is shown plain.
struct CardPassage: Equatable {
    /// The place in the file to picture instead of its start.
    let moment: Thumbnails.Moment?
    /// The line over the name.
    let line: AttributedString

    init?(_ subject: Subject) {
        guard let passage = subject.passage, let url = subject.url,
              case .file(let contentType) = subject.kind else { return nil }
        if let page = passage.page, contentType.conforms(to: .pdf), let label = passage.pageLabel {
            moment = .page(page)
            line = AttributedString(label)
        } else if PassagePreview.isRecording(url), let seconds = passage.seconds, let label = passage.momentLabel {
            moment = contentType.conforms(to: .movie) ? .second(seconds) : nil
            line = AttributedString(label)
        } else if contentType.conforms(to: .image) {
            return nil
        } else {
            moment = nil
            line = passage.pageLabel.map { AttributedString($0 + " · ") + passage.markedExcerpt }
                ?? passage.markedExcerpt
        }
    }
}
