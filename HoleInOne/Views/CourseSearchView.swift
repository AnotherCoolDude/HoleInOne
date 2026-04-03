import SwiftData
import SwiftUI

struct CourseSearchView: View {
    @State private var viewModel = CourseSearchViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerProfile.self) private var profile

    private var isSearching: Bool { viewModel.query.count >= 2 }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchSection
                } else {
                    favouritesSection
                    recentSection
                    browseSection
                }
            }
            .navigationTitle(profile.name.isEmpty ? "HoleInOne" : "Hi, \(profile.name) 👋")
            .searchable(text: $viewModel.query, prompt: "Course name or city")
            .onChange(of: viewModel.query) { _, new in viewModel.onQueryChange(new) }
            .task {
                await viewModel.loadFirstPage()
                viewModel.loadRecentCourses(store: SwingHistoryStore(modelContext: modelContext))
                viewModel.loadFavourites(store: SwingHistoryStore(modelContext: modelContext))
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { SwingHistoryView() } label: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
        }
    }

    // MARK: - Favourites section (pinned at top, always visible when not searching)

    @ViewBuilder
    private var favouritesSection: some View {
        if !viewModel.favouriteCourses.isEmpty {
            Section {
                ForEach(viewModel.favouriteCourses, id: \.courseId) { saved in
                    NavigationLink {
                        RoundSetupView(
                            courseId: saved.courseId,
                            preloadName: saved.courseName,
                            preloadCity: saved.city,
                            preloadCountry: saved.country
                        )
                    } label: {
                        courseRowContent(
                            name: saved.courseName,
                            subtitle: "\(saved.city), \(saved.country)"
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            unfavourite(courseId: saved.courseId, courseName: saved.courseName,
                                        city: saved.city, country: saved.country)
                        } label: {
                            Label("Remove", systemImage: "heart.slash")
                        }
                    }
                }
            } header: {
                Label("Favourites", systemImage: "heart.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Recently played section

    @ViewBuilder
    private var recentSection: some View {
        if !viewModel.recentCourses.isEmpty {
            Section("Recently Played") {
                ForEach(viewModel.recentCourses, id: \.courseId) { saved in
                    NavigationLink {
                        RoundSetupView(
                            courseId: saved.courseId,
                            preloadName: saved.courseName,
                            preloadCity: saved.city,
                            preloadCountry: saved.country
                        )
                    } label: {
                        courseRowContent(
                            name: saved.courseName,
                            subtitle: "\(saved.city), \(saved.country)",
                            isFavourite: saved.isFavourite
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        favouriteSwipeButton(
                            courseId: saved.courseId, courseName: saved.courseName,
                            city: saved.city, country: saved.country,
                            isCurrent: saved.isFavourite
                        )
                    }
                }
            }
        }
    }

    // MARK: - Browse section

    @ViewBuilder
    private var browseSection: some View {
        Section {
            ForEach(viewModel.browseResults, id: \.id) { course in
                apiCourseRow(course)
            }
            if viewModel.isLoading {
                loadingRow("Loading courses…")
            } else if viewModel.isLoadingMore {
                loadingRow("Loading more…")
            } else if viewModel.hasMorePages {
                Button("Load More") { Task { await viewModel.loadNextPage() } }
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("\(viewModel.totalCourses.formatted()) courses worldwide")
        }
    }

    // MARK: - Search results section

    @ViewBuilder
    private var searchSection: some View {
        if viewModel.isLoading {
            loadingRow("Searching across \(viewModel.totalCourses.formatted()) courses…")
        } else if let error = viewModel.errorMessage {
            Text(error).foregroundStyle(.secondary).font(.caption)
        } else if viewModel.searchResults.isEmpty {
            ContentUnavailableView(
                "No Results", systemImage: "magnifyingglass",
                description: Text("Try a different name or city.")
            )
        } else {
            Section("Results for \"\(viewModel.query)\"") {
                ForEach(viewModel.searchResults, id: \.id) { course in
                    apiCourseRow(course)
                }
            }
        }
    }

    // MARK: - Shared sub-views

    private func apiCourseRow(_ course: CourseAPIResult) -> some View {
        let courseId  = String(course.id)
        let name      = course.courseName.isEmpty ? course.clubName : course.courseName
        let subtitle  = [course.location.city, course.location.state, course.location.country]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let teeCount  = course.tees.male.count + course.tees.female.count
        let fav       = viewModel.isFavourite(courseId: courseId)

        return NavigationLink {
            RoundSetupView(
                courseId: courseId,
                preloadName: name,
                preloadCity: course.location.city,
                preloadCountry: course.location.country
            )
        } label: {
            courseRowContent(name: name, subtitle: subtitle, teeCount: teeCount, isFavourite: fav)
        }
        .swipeActions(edge: .trailing) {
            favouriteSwipeButton(
                courseId: courseId, courseName: name,
                city: course.location.city, country: course.location.country,
                isCurrent: fav
            )
        }
    }

    private func courseRowContent(
        name: String,
        subtitle: String,
        teeCount: Int = 0,
        isFavourite: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                HStack(spacing: 6) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    if teeCount > 0 {
                        Text("· \(teeCount) tees").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if isFavourite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func favouriteSwipeButton(
        courseId: String, courseName: String,
        city: String, country: String,
        isCurrent: Bool
    ) -> some View {
        Button {
            let store = SwingHistoryStore(modelContext: modelContext)
            store.toggleFavourite(courseId: courseId, courseName: courseName, city: city, country: country)
            viewModel.loadFavourites(store: store)
            viewModel.loadRecentCourses(store: store)
        } label: {
            Label(
                isCurrent ? "Unfavourite" : "Favourite",
                systemImage: isCurrent ? "heart.slash" : "heart"
            )
        }
        .tint(isCurrent ? .gray : .red)
    }

    private func unfavourite(courseId: String, courseName: String, city: String, country: String) {
        let store = SwingHistoryStore(modelContext: modelContext)
        store.toggleFavourite(courseId: courseId, courseName: courseName, city: city, country: country)
        viewModel.loadFavourites(store: store)
        viewModel.loadRecentCourses(store: store)
    }

    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .listRowBackground(Color.clear)
    }
}

