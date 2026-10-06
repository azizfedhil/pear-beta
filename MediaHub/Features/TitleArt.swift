import SwiftUI

/// The title as a logo when one exists, otherwise as text. The text is shown from the very first frame and only
/// swaps to the logo once the logo image has actually loaded, so the title can never vanish.
struct TitleArt: View {
    let item: MetaPreview
    var maxWidth: CGFloat = 260
    var maxHeight: CGFloat = 90
    var font: Font = .largeTitle.bold()
    var alignment: Alignment = .leading
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: alignment) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
                    .shadow(color: .black.opacity(0.45), radius: 8)
                    .accessibilityLabel(item.name)
                    .transition(.opacity)
            } else {
                Text(item.name).font(font)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .animation(.easeOut(duration: 0.3), value: image == nil)
        .task(id: item.id) {
            image = nil
            guard let url = await LogoResolver.shared.logo(for: item) else { return }
            let img = await ImagePipeline.shared.image(for: url, maxPixel: 900)
            guard !Task.isCancelled else { return }
            image = img
        }
    }
}
