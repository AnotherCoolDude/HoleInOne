import SwiftUI

// MARK: - CoursePhotoView
//
// Lazily loads and displays a representative photo for a golf course.
//
// On first appearance it fires a background task that queries CoursePhotoService
// (Wikipedia → og:image, both cached). Subsequent appearances are instant.
//
// Two size variants:
//   • thumbnail  — square, rounded corners; for use in List rows
//   • banner     — full-width, fixed height; for use at the top of a detail view

enum CoursePhotoSize {
    case thumbnail(side: CGFloat = 52)
    case banner(height: CGFloat = 200)
}

struct CoursePhotoView: View {
    let courseId: String
    let clubName: String
    let city: String
    let country: String
    var size: CoursePhotoSize = .thumbnail()

    @State private var photoURL: URL?

    var body: some View {
        Group {
            switch size {
            case .thumbnail(let side):
                thumbnailView(side: side)
            case .banner(let height):
                bannerView(height: height)
            }
        }
        .task(id: courseId) {
            photoURL = await CoursePhotoService.shared.photoURL(
                courseId: courseId,
                clubName: clubName,
                city: city,
                country: country
            )
        }
    }

    // MARK: - Thumbnail (list rows)

    private func thumbnailView(side: CGFloat) -> some View {
        AsyncImage(url: photoURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            case .failure:
                placeholderThumbnail(side: side)
            default:
                placeholderThumbnail(side: side)
                    .overlay { if photoURL != nil { ProgressView().scaleEffect(0.6) } }
            }
        }
        .frame(width: side, height: side)
    }

    private func placeholderThumbnail(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray5))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: "flag.fill")
                    .font(.system(size: side * 0.35))
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: - Banner (detail / setup views)

    private func bannerView(height: CGFloat) -> some View {
        AsyncImage(url: photoURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                    .clipped()
                    .overlay(alignment: .bottomLeading) { bannerBadge }
            case .failure:
                EmptyView()   // Don't show placeholder banner — just collapse
            default:
                if photoURL != nil {
                    // Image URL known but still loading — show a shimmer placeholder
                    Color(.systemGray6)
                        .frame(maxWidth: .infinity, minHeight: height * 0.4, maxHeight: height * 0.4)
                        .overlay { ProgressView().tint(.secondary) }
                }
                // photoURL == nil: nothing yet, hide entirely (no layout shift)
            }
        }
    }

    private var bannerBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo.fill")
                .font(.caption2)
            Text(photoSourceLabel)
                .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    // The badge label updates once the URL is known — Wikipedia vs club website
    private var photoSourceLabel: String {
        guard let host = photoURL?.host?.lowercased() else { return "Photo" }
        if host.contains("wikimedia") || host.contains("wikipedia") { return "Wikipedia" }
        return "Club photo"
    }
}
