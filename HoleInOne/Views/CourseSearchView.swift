import SwiftData
import SwiftUI

struct CourseSearchView: View {
    @State private var viewModel = CourseSearchViewModel()
    @Environment(\.modelContext) private var modelContext

    private var isSearching: Bool { viewModel.query.count >= 2 }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchSection
                } else {
                    recentSection
                    browseSection
                }
            }
            .navigationTitle("HoleInOne")
            .searchable(text: $viewModel.query, prompt: "Course name or city")
            .onChange(of: viewModel.query) { _, new in viewModel.onQueryChange(new) }
            .task { await viewModel.loadFirstPage()
                    viewModel.loadRecentCourses(store: SwingHistoryStore(modelContext: modelContext)) }
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

    // MARK: - Search results section

    @ViewBuilder
    private var searchSection: some View {
        if viewModel.isLoading {
            loadingRow("Searching across \(viewModel.totalCourses.formatted()) courses…")
        } else if let error = viewModel.errorMessage {
            Text(error).foregroundStyle(.secondary).font(.caption)
        } else if viewModel.searchResults.isEmpty {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                description: Text("Try a different name or city. Search scans up to 200 courses per query."))
        } else {
            Section("Results for "\(viewModel.query)"") {
                ForEach(viewModel.searchResults, id: \.id) { course in
                    courseRow(course)
                }
            }
        }
    }

    // MARK: - Recent + browse sections

    @ViewBuilder
    private var recentSection: some View {
        if !viewModel.recentCourses.isEmpty {
            Section("Recently Played") {
                ForEach(viewModel.recentCourses, id: \.courseId) { saved in
                    NavigationLink {
                        CourseDetailLoader(courseId: saved.courseId,
                                           courseName: saved.courseName,
                                           viewModel: viewModel)
                    } label: {
                        courseRowContent(name: saved.courseName,
                                         subtitle: "\(saved.city), \(saved.country)",
                                         hasGPS: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var browseSection: some View {
        Section {
            ForEach(viewModel.browseResults, id: \.id) { course in
                courseRow(course)
            }

            if viewModel.isLoading {
                loadingRow("Loading courses…")
            } else if viewModel.isLoadingMore {
                loadingRow("Loading more…")
            } else if viewModel.hasMorePages {
                Button("Load More") {
                    Task { await viewModel.loadNextPage() }
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            Text("\(viewModel.totalCourses.formatted()) courses worldwide")
        }
    }

    // MARK: - Shared sub-views

    private func courseRow(_ course: CourseAPIResult) -> some View {
        NavigationLink {
            CourseDetailLoader(courseId: String(course.id),
                               courseName: course.courseName.isEmpty ? course.clubName : course.courseName,
                               viewModel: viewModel)
        } label: {
            courseRowContent(
                name: course.courseName.isEmpty ? course.clubName : course.courseName,
                subtitle: [course.location.city, course.location.state, course.location.country]
                    .filter { !$0.isEmpty }.joined(separator: ", "),
                hasGPS: false,
                teeCount: (course.tees.male.count + course.tees.female.count)
            )
        }
    }

    private func courseRowContent(name: String, subtitle: String, hasGPS: Bool, teeCount: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.body)
            HStack(spacing: 6) {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if teeCount > 0 {
                    Text("· \(teeCount) tees").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Course detail loader

/// Fetches full course detail from the API before showing RoundSetupView.
private struct CourseDetailLoader: View {
    let courseId: String
    let courseName: String
    let viewModel: CourseSearchViewModel

    @State private var golfCourse: GolfCourse?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let course = golfCourse {
                RoundSetupView(course: course)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(courseName)…")
                        .font(.subheadline)
                    Text("Finding hole locations via OpenStreetMap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .task {
            do {
                guard let id = Int(courseId) else {
                    // Bundled course (non-integer String ID) — load from bundle.
                    // Bundled courses already carry real GPS coords so no OSM lookup needed.
                    let courses = try GolfAPIService.shared.loadBundledCourses()
                    golfCourse = courses.first(where: { $0.id == courseId })
                    if golfCourse == nil { errorMessage = "Course not found." }
                    isLoading = false
                    return
                }
                // Fetch course detail from API, then enrich with OSM GPS data.
                // toGolfCourse() is async — it transparently calls OSMGolfService
                // and may take a few seconds on the first lookup for a given course.
                let apiResult = try await GolfAPIService.shared.fetchCourse(id: id)
                golfCourse = await GolfAPIService.shared.toGolfCourse(apiResult)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
