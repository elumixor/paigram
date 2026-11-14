import SwiftUI
import SwiftSignalKit

/// An agent's portrait in a circle, its initials on its colour until the portrait loads.
@available(iOS 16.0, *)
struct AgentFace: View {
    struct Who: Equatable {
        let slug: String
        let name: String
        let avatar: String?
    }

    let who: Who
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image ?? who.avatar.flatMap(PaiAvatars.cached) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(uiImage: PaiAvatars.placeholder(name: who.name, slug: who.slug, size: size)).resizable()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: who.avatar) {
            guard let url = who.avatar, PaiAvatars.cached(url) == nil else { return }
            image = await withCheckedContinuation { continuation in
                let _ = PaiAvatars.image(url).start(next: { continuation.resume(returning: $0) })
            }
        }
    }
}
