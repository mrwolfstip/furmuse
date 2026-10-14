import SwiftUI
import AVFoundation

struct CropSource: Identifiable {
    enum Kind { case image(UIImage), video(URL) }
    let id = UUID()
    let kind: Kind
}

// forced crop for artwork you add (png / jpg / video). the window is fixed to a 1:1 or 3:4 shape, you move and zoom the media
// under it, and the result is exactly that shape, which is what the lock screen's animated artwork needs.
// reports the crop as a normalized rect (0...1) of the displayed media; the caller applies it to the real pixels.
struct ArtworkCropView: View {
    let source: CropSource
    let ondone: (CGRect, ArtworkAspect) async -> Void
    let oncancel: () -> Void

    @State private var media: UIImage?
    @State private var aspect: ArtworkAspect = .square
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dz: CGFloat = 1
    @GestureState private var dd: CGSize = .zero
    @State private var busy = false
    @State private var lastbox = CGSize(width: 390, height: 600)   // size of the crop area, captured from the GeometryReader

    private func window(in box: CGSize) -> CGSize {
        let w = min(box.width - 24, (box.height - 24) * aspect.ratio)
        return CGSize(width: max(w, 10), height: max(w, 10) / aspect.ratio)
    }
    private func scale(_ m: UIImage, _ win: CGSize, _ z: CGFloat) -> CGFloat {
        max(win.width / m.size.width, win.height / m.size.height) * min(max(z, 1), 8)
    }
    private func clamp(_ o: CGSize, _ m: UIImage, _ win: CGSize, _ s: CGFloat) -> CGSize {
        let mx = max(0, (m.size.width * s - win.width) / 2), my = max(0, (m.size.height * s - win.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let win = window(in: geo.size)
                    ZStack {
                        Color.black
                        if let m = media {
                            let s = scale(m, win, zoom * dz)
                            let o = clamp(CGSize(width: offset.width + dd.width, height: offset.height + dd.height), m, win, s)
                            Image(uiImage: m).resizable().frame(width: m.size.width * s, height: m.size.height * s).offset(o)
                            Path { p in
                                p.addRect(CGRect(origin: .zero, size: geo.size))
                                p.addRect(CGRect(x: (geo.size.width - win.width) / 2, y: (geo.size.height - win.height) / 2, width: win.width, height: win.height))
                            }.fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                            Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5).frame(width: win.width, height: win.height)
                        } else {
                            ProgressView().colorScheme(.dark)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { lastbox = geo.size }
                    .onChange(of: geo.size) { lastbox = $0 }
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(DragGesture().updating($dd) { v, st, _ in st = v.translation }.onEnded { v in
                        guard let m = media else { return }
                        let s = scale(m, win, zoom)
                        offset = clamp(CGSize(width: offset.width + v.translation.width, height: offset.height + v.translation.height), m, win, s)
                    })
                    .simultaneousGesture(MagnificationGesture().updating($dz) { v, st, _ in st = v }.onEnded { v in
                        guard let m = media else { return }
                        zoom = min(max(zoom * v, 1), 8)
                        offset = clamp(offset, m, win, scale(m, win, zoom))
                    })
                }
                VStack(spacing: 10) {
                    Picker("shape", selection: $aspect) {
                        ForEach(ArtworkAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: aspect) { _ in zoom = 1; offset = .zero }
                    Text("drag to move, pinch to zoom. cut away any black bars or borders: only what is inside the frame is kept.")
                        .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("crop artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { oncancel() }.disabled(busy) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if busy { ProgressView() } else { Button("use") { finish() }.disabled(media == nil) }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await loadmedia() }
        .interactiveDismissDisabled(busy)
    }

    private func finish() {
        guard let m = media else { return }
        Task {
            busy = true
            await ondone(currentnormalized(m), aspect)
            busy = false
        }
    }

    private func currentnormalized(_ m: UIImage) -> CGRect {
        let win = window(in: lastbox)
        let s = scale(m, win, zoom)
        let o = clamp(offset, m, win, s)
        let cw = win.width / s, ch = win.height / s
        let x = m.size.width / 2 - o.width / s - cw / 2
        let y = m.size.height / 2 - o.height / s - ch / 2
        return CGRect(x: max(0, x / m.size.width), y: max(0, y / m.size.height),
                      width: min(1, cw / m.size.width), height: min(1, ch / m.size.height))
    }

    private func loadmedia() async {
        switch source.kind {
        case .image(let i): media = i.normalizedup()
        case .video(let url):
            let img: UIImage? = await Task.detached { () -> UIImage? in
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                g.appliesPreferredTrackTransform = true
                g.maximumSize = CGSize(width: 1600, height: 1600)
                return (try? g.copyCGImage(at: .zero, actualTime: nil)).map { UIImage(cgImage: $0) }
            }.value
            media = img
        }
    }
}
