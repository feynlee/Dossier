import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Scanning documents with the camera, like Notes: the page is outlined live and taken automatically when
/// it's steady (or with the shutter); keep taking pages, review, retake or re-crop any of them, then save
/// them as one PDF to iCloud Drive, where the vault reads it like any other file.
struct DocumentScanner: View {
    /// Called after the scan was saved and added to the vault.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ScanFolders.autoCaptureKey) private var autoCaptureSetting = true
    @State private var session: ScanSession?
    @State private var reviewing: Int?
    @State private var isSaving = false
    @State private var confirmDiscard = false
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                camera(session)
            }
        }
        .statusBarHidden()
        .task {
            let session = ScanSession(autoCapture: autoCaptureSetting)
            self.session = session
            await session.start()
        }
        .onDisappear { session?.stop() }
        .onChange(of: scenePhase) { _, phase in
            guard let session else { return }
            if phase == .background { session.stop() } else if phase == .active { Task { await session.start() } }
        }
    }

    @ViewBuilder
    private func camera(_ session: ScanSession) -> some View {
        ZStack {
            ScanCameraPreview(camera: session.camera)
                .ignoresSafeArea()
            if let outline = session.outline {
                OutlineOverlay(outline: outline)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            Color.white.opacity(flash ? 0.7 : 0).ignoresSafeArea().allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: session.outline == nil)
        .safeAreaInset(edge: .top) { topBar(session) }
        .safeAreaInset(edge: .bottom) { bottomBar(session) }
        .sensoryFeedback(.impact(weight: .medium), trigger: session.captureCount)
        .onChange(of: session.captureCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.35)) { flash = false }
        }
        .fullScreenCover(item: Binding(get: { reviewing.map(PageIndex.init) }, set: { reviewing = $0?.value })) { start in
            ScanReview(session: session, selection: start.value)
        }
        .sheet(isPresented: $isSaving) {
            SaveScanSheet(pages: session.pages) {
                isSaving = false
                session.stop()
                onSaved()
                dismiss()
            }
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(session.pages.count == 1 ? "Discard Page" : "Discard \(session.pages.count) Pages", role: .destructive) {
                session.stop()
                dismiss()
            }
            Button("Keep Scanning", role: .cancel) {}
        }
    }

    private func topBar(_ session: ScanSession) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button("Cancel") {
                    if session.pages.isEmpty {
                        session.stop()
                        dismiss()
                    } else {
                        confirmDiscard = true
                    }
                }
                Spacer()
                Button {
                    session.torchOn.toggle()
                } label: {
                    Image(systemName: session.torchOn ? "bolt.fill" : "bolt.slash")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(session.torchOn ? "Turn off the light" : "Turn on the light")
                Menu {
                    Picker("Capture", selection: Binding(get: { session.autoCapture }, set: { session.autoCapture = $0 })) {
                        Label("Auto", systemImage: "a.circle").tag(true)
                        Label("Manual", systemImage: "hand.tap").tag(false)
                    }
                } label: {
                    Text(session.autoCapture ? "Auto" : "Manual")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal)

            if let retaking = session.retaking {
                HStack(spacing: 8) {
                    Text("Retaking page \(retaking + 1)")
                    Button("Cancel") { session.retaking = nil }
                        .fontWeight(.semibold)
                }
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.dsTintFill, in: Capsule())
            }
            Text(session.status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    private func bottomBar(_ session: ScanSession) -> some View {
        HStack {
            Button {
                if !session.pages.isEmpty { reviewing = session.pages.count - 1 }
            } label: {
                PageStackThumbnail(pages: session.pages)
            }
            .disabled(session.pages.isEmpty)
            .accessibilityLabel(session.pages.isEmpty ? "No pages yet" : "Review \(session.pages.count) pages")
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await session.capture() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(.white).frame(width: 62, height: 62)
                        .scaleEffect(session.isCapturing ? 0.85 : 1)
                }
            }
            .disabled(session.isCapturing)
            .accessibilityLabel("Take photo")

            Button {
                isSaving = true
            } label: {
                Text(session.pages.isEmpty ? "Save" : "Save (\(session.pages.count))")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(session.pages.isEmpty ? Color.white.opacity(0.15) : Color.dsTintFill, in: Capsule())
            }
            .foregroundStyle(.white)
            .disabled(session.pages.isEmpty || session.isCapturing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.35))
    }
}

private struct PageIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// The page outlined on the live camera.
private struct OutlineOverlay: View {
    let outline: PageOutline

    var body: some View {
        GeometryReader { geometry in
            let points = outline.points(inAspectFillViewOf: geometry.size)
            if points.count == 4 {
                let path = Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                path.fill(Color.dsTint.opacity(outline.isTooFar ? 0.12 : 0.28))
                path.stroke(Color.dsTint, style: StrokeStyle(lineWidth: 3, lineJoin: .round, dash: outline.isTooFar ? [10, 6] : []))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The last page taken, with how many there are.
private struct PageStackThumbnail: View {
    let pages: [ScannedPage]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = pages.last?.pageImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2))
                Text("\(pages.count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Color.dsTintFill, in: Circle())
                    .offset(x: 8, y: -8)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.3), lineWidth: 2)
                    .frame(width: 52, height: 64)
            }
        }
        .animation(.snappy, value: pages.count)
    }
}

// MARK: Reviewing pages

/// The pages taken so far, one at a time: retake, crop, turn or delete each.
struct ScanReview: View {
    let session: ScanSession

    @Environment(\.dismiss) private var dismiss
    @State var selection: Int
    @State private var cropping: Int?

    init(session: ScanSession, selection: Int) {
        self.session = session
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                    Group {
                        if let image = page.pageImage {
                            Image(uiImage: image).resizable().scaledToFit().padding()
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .navigationTitle(session.pages.isEmpty ? "" : "Page \(selection + 1) of \(session.pages.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Retake", systemImage: "camera") {
                        session.retaking = selection
                        dismiss()
                    }
                    Spacer()
                    Button("Crop", systemImage: "crop") { cropping = selection }
                    Spacer()
                    Button("Rotate", systemImage: "rotate.right") { session.turn(at: selection) }
                    Spacer()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        session.delete(at: selection)
                        if session.pages.isEmpty { dismiss() } else { selection = min(selection, session.pages.count - 1) }
                    }
                }
            }
            .fullScreenCover(item: Binding(get: { cropping.map(PageIndex.init) }, set: { cropping = $0?.value })) { index in
                if session.pages.indices.contains(index.value) {
                    CropEditor(page: session.pages[index.value]) { session.setOutline($0, at: index.value) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Moving the corners of a page on the photo it was taken from.
struct CropEditor: View {
    let page: ScannedPage
    let onDone: (PageOutline) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var corners: [CGPoint] = []

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let frame = fittedRect(for: page.photoSize, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    if let image = page.photoImage {
                        Image(uiImage: image).resizable().frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                    }
                    if corners.count == 4 {
                        let points = corners.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
                        Path { path in
                            path.addLines(points)
                            path.closeSubpath()
                        }
                        .fill(Color.dsTint.opacity(0.2))
                        Path { path in
                            path.addLines(points)
                            path.closeSubpath()
                        }
                        .stroke(Color.dsTint, lineWidth: 2)
                        ForEach(0..<4, id: \.self) { index in
                            Circle()
                                .fill(.white)
                                .overlay(Circle().stroke(Color.dsTint, lineWidth: 3))
                                .frame(width: 28, height: 28)
                                .contentShape(Circle().inset(by: -16))
                                .position(points[index])
                                .gesture(DragGesture().onChanged { value in
                                    corners[index] = CGPoint(
                                        x: min(max((value.location.x - frame.minX) / frame.width, 0), 1),
                                        y: min(max((value.location.y - frame.minY) / frame.height, 0), 1)
                                    )
                                })
                                .accessibilityLabel(["Top left", "Top right", "Bottom right", "Bottom left"][index] + " corner")
                        }
                    }
                }
            }
            .padding(24)
            .background(Color.black)
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(PageOutline(corners: corners, frameSize: page.photoSize))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Whole Photo") { corners = PageOutline.whole(page.photoSize).corners }
                }
            }
            .onAppear { corners = page.outline.corners }
        }
        .preferredColorScheme(.dark)
    }

    private func fittedRect(for size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}

// MARK: Saving

/// Naming the scan and choosing its folder in iCloud Drive, then adding it to the vault.
struct SaveScanSheet: View {
    let pages: [ScannedPage]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Settings.usePrivateCloudKey) private var usePrivateCloud = true
    @State private var name = ScanFolders.suggestedName()
    @State private var folder = ScanFolders.preferredFolder
    @State private var isChoosingFolder = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(pages) { page in
                                if let image = page.pageImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(uiColor: .separator)))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section("Name") {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                }
                Section {
                    Button {
                        isChoosingFolder = true
                    } label: {
                        HStack {
                            Label {
                                Text(folder.map { FolderAccess.displayPath(for: $0) } ?? "Choose a folder")
                                    .foregroundStyle(folder == nil ? Color.dsTint : .primary)
                            } icon: {
                                Image(systemName: "icloud")
                            }
                            Spacer()
                            Text(folder == nil ? "" : "Change").foregroundStyle(Color.dsTint)
                        }
                    }
                } header: {
                    Text("Save to")
                } footer: {
                    Text("Saved as a PDF in iCloud Drive, then read like any other file you add. Set a default folder in Settings; otherwise Dossier uses the folder you saved to last.")
                }
            }
            .navigationTitle(pages.count == 1 ? "Save 1 Page" : "Save \(pages.count) Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(folder == nil)
                    }
                }
            }
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    if ScanFolders.isInICloud(url) { folder = url } else { errorMessage = ScanFolders.SaveError.notInICloud.localizedDescription }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Couldn’t save the scan", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private func save() {
        guard let folder else { return }
        isWorking = true
        let pages = pages, name = name
        Task {
            defer { isWorking = false }
            guard let pdf = await Self.makePDF(pages) else {
                errorMessage = ScanFolders.SaveError.couldNotWrite.localizedDescription
                return
            }
            do {
                let file = try ScanFolders.save(pdf, named: name, in: folder)
                importer.add([file], within: folder, context: modelContext, preferPrivateCloud: usePrivateCloud)
                onSaved()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @concurrent
    private static func makePDF(_ pages: [ScannedPage]) async -> Data? {
        ScanPDF.make(pages)
    }
}
