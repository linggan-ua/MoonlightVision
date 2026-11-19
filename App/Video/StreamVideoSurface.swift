//
//  StreamVideoSurface.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

@preconcurrency import RealityKit
import SwiftUI
import simd

/// The stream picture as a RealityKit plane inside the stream window.
///
/// This is a straight port of an earlier client's window video surface: the
/// RealityView is laid out in an aspect-fit rect, the plane is a rounded mesh
/// sized by measuring an invisible 100 pt ruler, and the decoder's drawable
/// queue is bound to a `TextureResource` from the scene update heartbeat.
/// In 2D the plane uses an unlit material; in 3D it switches to `SBSMaterial`,
/// whose camera-index switch samples the left half for the left eye and the
/// right half for the right eye.
///
/// The SBS confirmation card is a RealityKit attachment, not a SwiftUI sibling:
/// scene content renders in front of the window's 2D layer, so ordinary
/// overlays would sit behind the picture.
struct StreamVideoSurface: View {
    let texture: TextureResource
    let mailbox: StreamFrameMailbox
    let videoMode: VideoMode
    let streamWidth: Int
    let streamHeight: Int
    /// The host frame is already packed side-by-side (32:9 automatically, or
    /// any 3:1 frame when "Packed SBS Input" is on).
    let packedSBS: Bool
    /// Corner radius of the plane as a fraction of its width. 0 gives the
    /// picture square corners.
    let cornerRadiusFraction: Float
    /// Cylinder wrap as a fraction of 90°. 0 keeps the picture flat.
    let curvatureFraction: Float
    /// Local cursor overlay shared with the input strategy.
    let localCursor: StreamLocalCursor
    let showLocalCursor: Bool
    /// True when enabling 3D will run the on-device 2D→3D conversion instead of
    /// showing a frame-packed host stream.
    let localConversion: Bool
    let showSBSConfirm: Bool
    let onEnableSBS: () -> Void
    let onCancelSBS: () -> Void

    @State private var runtime = StreamVideoSurfaceRuntime()
    @State private var surfaceMaterial: ShaderGraphMaterial?

    /// Height ÷ width of the plane for the current mode.
    private var screenAspect: Float {
        let aspect = StreamPictureGeometry.planeHeightToWidth(
            width: streamWidth,
            height: streamHeight,
            mode: videoMode,
            assumePacked: packedSBS
        )
        return Float(aspect)
    }

    var body: some View {
        let _ = runtime.configure(
            screenAspect: screenAspect,
            videoMode: videoMode,
            showConfirmCard: showSBSConfirm,
            texture: texture
        )

        GeometryReader { proxy in
            let fitSize = Self.calculateVideoSize(containerSize: proxy.size, width: streamWidth, height: streamHeight)

            ZStack {
                RealityView { content, attachments in
                    setupRealityView(content: content, attachments: attachments)
                    _ = content.subscribe(to: SceneEvents.Update.self) { _ in
                        if let frame = mailbox.collect() {
                            MainActor.assumeIsolated {
                                runtime.bind(frame)
                            }
                        }
                        MainActor.assumeIsolated {
                            runtime.updateConfirmCard()
                        }
                    }
                } update: { _, attachments in
                    updateRealityView(
                        attachments: attachments,
                        size: fitSize,
                        cursorPosition: localCursor.position,
                        cursorVisible: localCursor.visible && showLocalCursor
                    )
                } attachments: {
                    // The invisible ruler gives the window's points-to-meters factor.
                    Attachment(id: "calibrationRuler") {
                        Color.clear.frame(width: 100, height: 100)
                    }
                    Attachment(id: "localCursor") {
                        LocalCursorView()
                    }
                    Attachment(id: "sbsConfirm") {
                        if showSBSConfirm {
                            SBSConfirmCard(
                                localConversion: localConversion,
                                onEnable: onEnableSBS,
                                onCancel: onCancelSBS
                            )
                        } else {
                            Color.clear.frame(width: 1, height: 1)
                        }
                    }
                }
                .frame(width: fitSize.width, height: fitSize.height)
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .task { await setupMaterial() }
        .onChange(of: videoMode) { _, _ in
            runtime.updateScreenMaterial(
                videoMode: videoMode,
                material: surfaceMaterial,
                texture: texture
            )
        }
    }

    // MARK: - RealityView

    private func setupRealityView(
        content: RealityViewContent,
        attachments: RealityViewAttachments
    ) {
        let aspect = screenAspect
        let geometry = StreamVideoPlaneMesh.Geometry(
            aspect: aspect,
            cornerRadiusFraction: cornerRadiusFraction,
            curvatureFraction: curvatureFraction,
            // Provisional until the first update measures the window.
            physicalWidth: 1.4
        )
        let mesh: MeshResource
        if let resource = try? StreamVideoPlaneMesh.makeMesh(geometry) {
            runtime.planeGeometry = geometry
            mesh = resource
        } else {
            NSLog("%@", "[Video] Curved plane mesh failed, using a flat plane")
            mesh = .generatePlane(width: 1, height: aspect)
        }

        let entity = ModelEntity(mesh: mesh, materials: [StreamVideoMaterialFactory.unlit(texture: texture)])
        entity.position = .zero
        content.add(entity)
        runtime.screen = entity

        if let ruler = attachments.entity(for: "calibrationRuler") {
            ruler.components.set(OpacityComponent(opacity: 0))
            content.add(ruler)
            runtime.ruler = ruler
        }

        if let card = attachments.entity(for: "sbsConfirm") {
            entity.addChild(card)
            card.position = [0, 0, 0.15]
            runtime.confirmCard = card
        }

        if let cursor = attachments.entity(for: "localCursor") {
            entity.addChild(cursor)
            cursor.isEnabled = false
            runtime.localCursor = cursor
        }

        runtime.updateScreenMaterial(
            videoMode: videoMode,
            material: surfaceMaterial,
            texture: texture
        )
    }

    private func updateRealityView(
        attachments: RealityViewAttachments,
        size: CGSize,
        cursorPosition: CGPoint,
        cursorVisible: Bool
    ) {
        runtime.updateScene(
            size: size,
            screenAspect: screenAspect,
            cornerRadius: cornerRadiusFraction,
            curvature: curvatureFraction,
            cursorPosition: cursorPosition,
            cursorVisible: cursorVisible,
            showConfirmCard: showSBSConfirm,
            attachments: attachments
        )
    }

    /// Aspect-fit rect for the full host frame, exactly like the reference
    /// window: its width anchors the plane's scale.
    private static func calculateVideoSize(
        containerSize: CGSize,
        width: Int,
        height: Int
    ) -> CGSize {
        guard width > 0, height > 0 else { return .zero }
        let streamAspect = CGFloat(width) / CGFloat(height)
        let containerAspect = containerSize.width / containerSize.height

        if containerAspect > streamAspect {
            let height = containerSize.height
            return CGSize(width: height * streamAspect, height: height)
        } else {
            let width = containerSize.width
            return CGSize(width: width, height: width / streamAspect)
        }
    }

    // MARK: - Texture and material

    /// RealityKit still tone-maps ShaderGraph unlit surfaces by default, which
    /// lifts brightness, contrast and saturation compared with the system video
    /// layer. Video pixels are already display-referred, so opt out like the
    /// core client and pass them through unchanged.
    private static func disablingToneMapping(
        on material: ShaderGraphMaterial
    ) async -> ShaderGraphMaterial {
        var descriptor = material.program.descriptor
        descriptor.lightingModel = .unlit(isTonemappingEnabled: false)
        do {
            let program = try await ShaderGraphMaterial.Program(descriptor: descriptor)
            return ShaderGraphMaterial(program: program)
        } catch {
            NSLog("[Video] Failed to disable SBS tone mapping: %@", "\(error)")
            return material
        }
    }

    @MainActor
    private func setupMaterial() async {
        guard surfaceMaterial == nil else { return }
        do {
            var material = try await ShaderGraphMaterial(
                named: "/Root/SBSMaterial",
                from: "SBSMaterial.usda"
            )
            material = await Self.disablingToneMapping(on: material)
            try material.setParameter(name: "texture", value: .textureResource(texture))
            surfaceMaterial = material
            runtime.updateScreenMaterial(
                videoMode: videoMode,
                material: material,
                texture: texture
            )
        } catch {
            NSLog("[Video] Failed to load SBS material: %@", "\(error)")
        }
    }

}

/// Geometry of the window picture plane. Rounded corners are cut in the flat
/// parameterised grid before the vertex is bent onto the cylinder arc, and the
/// chord is normalised so the picture keeps filling the fit rect at every
/// curvature. The math follows the core client's curved-mesh cook.
enum StreamVideoPlaneMesh {
    struct Geometry: Equatable {
        var aspect: Float
        var cornerRadiusFraction: Float
        var curvatureFraction: Float
        /// Physical width of the plane in metres. Curvature is a fixed radius,
        /// so this decides the actual arc angle.
        var physicalWidth: Float
    }

    static let columns = 256
    static let rows = 256
    /// The safe arc limit until we can replicate Steam Link's exact depth
    /// frame; RealityKit's window scene clips a deeper recess.
    static let maximumArcAngle: Float = .pi / 4
    /// Radius range in metres for the curvature control (0 % is flat).
    static let maximumCurvatureRadius: Float = 8
    static let minimumCurvatureRadius: Float = 1.5

    /// Fixed radius for a 0…1 curvature fraction.
    static func curvatureRadius(for fraction: Float) -> Float {
        let clamped = min(max(fraction, 0), 1)
        return maximumCurvatureRadius
            + (minimumCurvatureRadius - maximumCurvatureRadius) * clamped
    }

    /// Local position of one picture point on the curved plane, used by
    /// overlays such as the local cursor.
    static func surfacePoint(u: Float, v: Float, geometry: Geometry) -> SIMD3<Float> {
        let width: Float = 1
        let height = max(geometry.aspect, 0.001)
        let x = (u - 0.5) * width
        let y = (0.5 - v) * height
        let curvature = min(max(geometry.curvatureFraction, 0), 1)
        guard curvature > 0.0005, geometry.physicalWidth > 0.01 else {
            return SIMD3(x, y, 0)
        }
        let physicalRadius = curvatureRadius(for: curvature)
        let arcAngle = min(maximumArcAngle, geometry.physicalWidth / physicalRadius)
        guard arcAngle > 0.001 else { return SIMD3(x, y, 0) }
        let halfAngle = arcAngle / 2
        let radius = 1 / arcAngle
        let theta = x * arcAngle
        let chordScale = 0.5 / (radius * sin(halfAngle))
        return SIMD3(
            radius * sin(theta) * chordScale,
            y,
            radius * (cos(halfAngle) - cos(theta)) * chordScale
        )
    }

    static func makeMesh(_ geometry: Geometry) throws -> MeshResource {
        let width: Float = 1
        let height = max(geometry.aspect, 0.001)
        let cornerRadius = min(max(geometry.cornerRadiusFraction, 0), 1) * width
        let curvature = min(max(geometry.curvatureFraction, 0), 1)
        let arcAngle: Float = {
            guard curvature > 0.0001, geometry.physicalWidth > 0.01 else { return 0 }
            let physicalRadius = curvatureRadius(for: curvature)
            return min(maximumArcAngle, geometry.physicalWidth / physicalRadius)
        }()
        let curved = arcAngle > 0.001
        let radius = curved ? width / arcAngle : .infinity
        let halfAngle = arcAngle / 2
        let chordScale: Float = curved
            ? (width / 2) / (radius * sin(halfAngle))
            : 1

        var columnX = [Float](repeating: 0, count: columns + 1)
        var columnZ = columnX
        var columnNormalX = columnX
        var columnNormalZ = columnX
        if curved {
            for column in 0...columns {
                let x = (Float(column) / Float(columns) - 0.5) * width
                let theta = x / radius
                columnX[column] = radius * sin(theta) * chordScale
                columnZ[column] = radius * (cos(halfAngle) - cos(theta)) * chordScale
                columnNormalX[column] = -sin(theta)
                columnNormalZ[column] = cos(theta)
            }
        }

        let uvInset: Float = 0.0005
        let halfWidth = width * 0.5
        let halfHeight = height * 0.5
        let cornerX = halfWidth - cornerRadius
        let cornerY = halfHeight - cornerRadius
        // A straight-edge vertex is exactly one radius from the corner centre;
        // without this tolerance Float rounding can treat it as outside and
        // collapse the outer row onto the corner (a smeared border).
        let cornerTolerance = width * 1e-5

        let vertexCount = (columns + 1) * (rows + 1)
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var uvs = [SIMD2<Float>]()
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        uvs.reserveCapacity(vertexCount)

        for row in 0...rows {
            let v = Float(row) / Float(rows)
            let y = (0.5 - v) * height
            let vTex = (1 - v) * (1 - 2 * uvInset) + uvInset
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                var x = (u - 0.5) * width
                var py = y
                var movedX = false

                if cornerRadius > 0 {
                    let sx = abs(x) - cornerX
                    let sy = abs(py) - cornerY
                    if sx > 0 || sy > 0 {
                        let dx = max(sx, 0)
                        let dy = max(sy, 0)
                        let length = simd_length(SIMD2<Float>(dx, dy))
                        if length > cornerRadius + cornerTolerance {
                            let signX: Float = (x >= 0) ? 1 : -1
                            let signY: Float = (py >= 0) ? 1 : -1
                            let clampedX = signX * (cornerX + dx / length * cornerRadius)
                            movedX = clampedX != x
                            x = clampedX
                            py = signY * (cornerY + dy / length * cornerRadius)
                        }
                    }
                }

                let uTex = u * (1 - 2 * uvInset) + uvInset
                if curved {
                    if movedX {
                        let theta = x / radius
                        positions.append(SIMD3(
                            radius * sin(theta) * chordScale,
                            py,
                            radius * (cos(halfAngle) - cos(theta)) * chordScale
                        ))
                        normals.append(SIMD3(-sin(theta), 0, cos(theta)))
                    } else {
                        positions.append(SIMD3(columnX[column], py, columnZ[column]))
                        normals.append(SIMD3(columnNormalX[column], 0, columnNormalZ[column]))
                    }
                } else {
                    positions.append(SIMD3(x, py, 0))
                    normals.append(SIMD3(0, 0, 1))
                }
                uvs.append(SIMD2(uTex, vTex))
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity(columns * rows * 6)
        let stride = UInt32(columns + 1)
        for row in 0..<rows {
            for column in 0..<columns {
                let topLeft = UInt32(row) * stride + UInt32(column)
                let topRight = topLeft + 1
                let bottomLeft = topLeft + stride
                let bottomRight = bottomLeft + 1
                indices.append(contentsOf: [
                    topLeft, bottomLeft, bottomRight,
                    topLeft, bottomRight, topRight
                ])
            }
        }

        var descriptor = MeshDescriptor(name: "curved_video_plane")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}

/// The window picture is video, not scene content: RealityKit's post-process
/// tone map would raise brightness, contrast and saturation relative to the
/// system video layer. The plane's unlit material opts out so the decoder's
/// colors reach the compositor unchanged.
@MainActor
enum StreamVideoMaterialFactory {
    static func unlit(texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color.texture = UnlitMaterial.Texture(texture)
        return material
    }
}

/// Holds the scene handles and the last applied transforms. RealityKit
/// delivers scene updates on the main thread, so the box needs no lock.
@MainActor
final class StreamVideoSurfaceRuntime {
    weak var screen: ModelEntity?
    var ruler: Entity?
    var confirmCard: Entity?
    var planeGeometry: StreamVideoPlaneMesh.Geometry?
    var localCursor: Entity?
    private var lastCursorPosition = CGPoint(x: -1, y: -1)
    private var lastCursorVisible = false
    private var lastCursorScale: Float = 0

    private var lastUpdateSize: CGSize = .zero
    private var appliedMode: VideoMode?
    private var appliedTexture: ObjectIdentifier?
    private var desiredAspect: Float = 0
    private var desiredMode: VideoMode = .standard2D
    private var desiredShowConfirmCard = false
    private var currentTexture: TextureResource?
    private var lastCardScale: Float = 0

    /// Refreshes the values the per-frame closure reads. The subscription is
    /// created once, so it must not capture presentation state.
    func configure(
        screenAspect: Float,
        videoMode: VideoMode,
        showConfirmCard: Bool,
        texture: TextureResource
    ) {
        desiredAspect = screenAspect
        desiredMode = videoMode
        desiredShowConfirmCard = showConfirmCard
        currentTexture = texture
    }

    /// Binds a freshly delivered drawable queue to the current texture. The
    /// texture changes when a live 3D toggle resizes the SBS output.
    func bind(_ queue: TextureResource.DrawableQueue) {
        currentTexture?.replace(withDrawables: queue)
    }

    func updateScene(
        size: CGSize,
        screenAspect: Float,
        cornerRadius: Float,
        curvature: Float,
        cursorPosition: CGPoint,
        cursorVisible: Bool,
        showConfirmCard: Bool,
        attachments: RealityViewAttachments
    ) {
        desiredAspect = screenAspect
        desiredShowConfirmCard = showConfirmCard

        // Attachments can become available after the make closure ran; adopt
        // the card lazily so the dialog can never stay orphaned.
        if confirmCard == nil, let card = attachments.entity(for: "sbsConfirm") {
            screen?.addChild(card)
            card.position = [0, 0, 0.15]
            confirmCard = card
        }

        guard size.width > 10, size.height > 10 else { return }

        // Dynamic calibration: the ruler is 100 points wide, so its physical
        // width gives meters-per-point. The plane's physical width feeds the
        // fixed-radius curvature, so resizing the window changes the arc.
        var physicalWidth = screen?.scale.x ?? 0
        var metersPerPoint: Float = 0
        if let screen, let ruler = self.ruler {
            let rulerWidth = ruler.visualBounds(relativeTo: nil).extents.x
            if rulerWidth > 0 {
                metersPerPoint = rulerWidth / 100
                let targetWidth = Float(size.width) * metersPerPoint
                physicalWidth = targetWidth
                if abs(targetWidth - screen.scale.x) > 0.0001 {
                    screen.scale = [targetWidth, targetWidth, 1]
                }
            }
        }
        if physicalWidth <= 0 { physicalWidth = 1.4 }

        // Rewrite the vertex buffer only when the shape actually changed.
        let geometry = StreamVideoPlaneMesh.Geometry(
            aspect: screenAspect,
            cornerRadiusFraction: cornerRadius,
            curvatureFraction: curvature,
            physicalWidth: physicalWidth
        )
        let geometryChanged = geometry != planeGeometry
        if geometryChanged {
            planeGeometry = geometry
            if let screen,
               let mesh = try? StreamVideoPlaneMesh.makeMesh(geometry) {
                // Re-set the whole component: swapping only `model?.mesh` on a
                // live entity can leave it without a renderable mesh.
                let materials = screen.model?.materials ?? []
                screen.components.set(ModelComponent(mesh: mesh, materials: materials))
            }
        }
        let sizeChanged =
            abs(size.width - lastUpdateSize.width) >= 1.0 ||
            abs(size.height - lastUpdateSize.height) >= 1.0
        let cursorChanged =
            cursorVisible != lastCursorVisible ||
            abs(cursorPosition.x - lastCursorPosition.x) > 0.0005 ||
            abs(cursorPosition.y - lastCursorPosition.y) > 0.0005
        guard geometryChanged || sizeChanged || cursorChanged || lastUpdateSize == .zero else { return }
        lastUpdateSize = size
        lastCursorVisible = cursorVisible
        lastCursorPosition = cursorPosition

        if let cursor = localCursor {
            cursor.isEnabled = cursorVisible
            if cursorVisible, let geometry = planeGeometry {
                let point = StreamVideoPlaneMesh.surfacePoint(
                    u: Float(cursorPosition.x),
                    v: Float(cursorPosition.y),
                    geometry: geometry
                )
                cursor.position = [point.x, point.y, point.z + 0.02]
                if metersPerPoint > 0 {
                    let bounds = cursor.visualBounds(relativeTo: nil)
                    if bounds.extents.x > 0 {
                        let unscaled = bounds.extents.x / max(cursor.scale.x, 0.0001)
                        let scale = 22 * metersPerPoint / unscaled
                        if abs(scale - lastCursorScale) > 0.0005 {
                            cursor.scale = [scale, scale, scale]
                            lastCursorScale = scale
                        }
                    }
                }
            }
        }

        updateConfirmCard()
    }

    func updateScreenMaterial(
        videoMode: VideoMode,
        material: ShaderGraphMaterial?,
        texture: TextureResource
    ) {
        desiredMode = videoMode
        let textureID = ObjectIdentifier(texture)
        guard let screen,
              appliedMode != videoMode || appliedTexture != textureID else { return }

        if videoMode == .sideBySide3D, var material {
            do {
                try material.setParameter(name: "texture", value: .textureResource(texture))
                screen.model?.materials = [material]
                appliedMode = .sideBySide3D
                appliedTexture = textureID
            } catch {
                NSLog("[Video] Failed to set SBS texture parameter: %@", "\(error)")
                screen.model?.materials = [StreamVideoMaterialFactory.unlit(texture: texture)]
                appliedMode = .standard2D
                appliedTexture = textureID
            }
        } else {
            screen.model?.materials = [StreamVideoMaterialFactory.unlit(texture: texture)]
            appliedMode = .standard2D
            appliedTexture = textureID
        }
    }

    func updateConfirmCard() {
        guard let confirmCard else { return }
        confirmCard.isEnabled = desiredShowConfirmCard
        guard desiredShowConfirmCard else { return }

        if let screen, confirmCard.parent !== screen {
            screen.addChild(confirmCard)
            confirmCard.position = [0, 0, 0.15]
        }

        let bounds = confirmCard.visualBounds(relativeTo: nil)
        guard bounds.extents.x > 0 else { return }
        let unscaledWidth = Float(bounds.extents.x) / max(confirmCard.scale.x, 0.0001)
        guard unscaledWidth > 0 else { return }
        let target: Float = 0.24
        let scale = target / unscaledWidth
        guard abs(scale - lastCardScale) > 0.0001 else { return }
        confirmCard.scale = [scale, scale, scale]
        lastCardScale = scale
    }

}

/// Asks before switching the window into side-by-side 3D, matching the
/// core client's confirmation card.
struct SBSConfirmCard: View {
    let localConversion: Bool
    let onEnable: () -> Void
    let onCancel: () -> Void

    private var title: LocalizedStringKey {
        localConversion ? "Enable Real-time 3D" : "Enable SBS 3D"
    }

    private var detail: LocalizedStringKey {
        localConversion
            ? "Convert this 2D stream to 3D on this device using the Neural Engine."
            : "Use software such as ReShade + Depth3D on your host PC to utilize SBS mode."
    }

    private var actionTitle: LocalizedStringKey {
        localConversion ? "Enable 3D" : "Enable SBS 3D"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "view.3d")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Button(action: onEnable) {
                    Text(actionTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 400)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The local cursor drawn as a RealityKit attachment so it renders in front of
/// the video plane (the window's 2D layer sits behind scene content).
private struct LocalCursorView: View {
    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 1.5)
            .frame(width: 28, height: 28)
    }
}
