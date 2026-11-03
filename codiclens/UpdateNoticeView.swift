import SwiftUI

/// The Update Notice (`GLOSSARY.md`): a glass strip under the Results Slab,
/// the preview, or the Card row when neither is there, saying a newer
/// Codiclens is waiting, with ⌘U in its corner. A click acts on it as ⌘U does.
///
/// It is never a Result: it holds no selection and Enter never reaches it.
struct UpdateNoticeView: View {
    let notice: UpdateNotice
    let act: () -> Void

    var body: some View {
        HStack(spacing: Style.rowPaddingH) {
            Text(notice.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            KeyHintChip(keys: UpdateNotice.keyHint)
        }
        .padding(.horizontal, Style.padding)
        .frame(height: PanelLayout.updateNoticeHeight)
        .contentShape(Style.noticeShape)
        .onTapGesture(perform: act)
        .noticeSurface()
    }
}
