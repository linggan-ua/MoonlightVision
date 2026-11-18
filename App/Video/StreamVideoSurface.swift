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
            mode: videoMode
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
                    updateRealityView(attachments: attachments, size: fitSize)
                } attachments: {
                    // The invisible ruler gives the window's points-to-meters factor.
                    Attachment(id: "calibrationRuler") {
                        Color.clear.frame(width: 100, height: 100)
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
        let baseWidth: Float = 1.0
        let aspect = screenAspect
        let mesh: MeshResource
        do {
            mesh = try StreamVideoSurfaceMesh.roundedPlane(
                width: baseWidth,
                aspectRatio: aspect,
                resolution: (256, 256),
                cornerRadiusFraction: 0.012
            )
        } catch {
            NSLog("%@", "[Video] Plane mesh failed, using a flat plane: \(error)")
            mesh = .generatePlane(width: baseWidth, height: baseWidth * aspect)
        }

        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(texture: texture)])
        entity.position = .zero
        content.add(entity)
        runtime.screen = entity
        runtime.meshAspect = aspect

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

        runtime.updateScreenMaterial(
            videoMode: videoMode,
            material: surfaceMaterial,
            texture: texture
        )
    }

    private func updateRealityView(attachments: RealityViewAttachments, size: CGSize) {
        runtime.updateScene(
            size: size,
            screenAspect: screenAspect,
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

    @MainActor
    private func setupMaterial() async {
        guard surfaceMaterial == nil else { return }
        do {
            var material = try await ShaderGraphMaterial(
                named: "/Root/SBSMaterial",
                from: "SBSMaterial.usda"
            )
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

/// Flat rounded-corner plane mesh, ported from the core client.
enum StreamVideoSurfaceMesh {
    static func roundedPlane(
        width: Float,
        aspectRatio: Float,
        resolution: (UInt32, UInt32),
        cornerRadiusFraction: Float
    ) throws -> MeshResource {
        let curveMagnitude: Float = 0
        var descriptor = MeshDescriptor(name: "curved_rounded_plane")
        let height = width * aspectRatio
        let cornerRadius = max(0.0, min(1.0, cornerRadiusFraction)) * width

        let resX = max(2, Int(resolution.0))
        let resY = max(2, Int(resolution.1))
        let vertexCount = resX * resY

        let numQuadsX = resX - 1
        let numQuadsY = resY - 1
        let triangleCount = numQuadsX * numQuadsY * 2
        let indexCount = triangleCount * 3

        var positions = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var uvs = [SIMD2<Float>](repeating: .zero, count: vertexCount)
        var indices = [UInt32](repeating: 0, count: indexCount)

        let maxCurveAngle: Float = (5.5 * .pi / 6.0)
        let currentAngle = maxCurveAngle * max(0.0, min(curveMagnitude, 1.0))
        let halfAngle = currentAngle / 2.0
        let radius: Float = (abs(halfAngle) < 0.0001) ? .infinity : (width / (2.0 * sin(halfAngle)))

        let uvInset: Float = 0.0005

        var vIndex = 0
        var iIndex = 0
        for y in 0..<resY {
            let vGeo = Float(y) / Float(resY - 1)
            let yPos = (0.5 - vGeo) * height
            let vTex = (1.0 - vGeo) * (1.0 - 2.0 * uvInset) + uvInset

            for x in 0..<resX {
                let u = Float(x) / Float(resX - 1)

                var xPlane = (u - 0.5) * width
                var yPlane = yPos
                if cornerRadius > 0.0 {
                    let halfW = width * 0.5
                    let halfH = height * 0.5
                    let rx = halfW - cornerRadius
                    let ry = halfH - cornerRadius

                    var px = xPlane
                    var py = yPlane

                    let sx = abs(px) - rx
                    let sy = abs(py) - ry

                    if sx > 0.0 || sy > 0.0 {
                        let dx = max(sx, 0.0)
                        let dy = max(sy, 0.0)
                        let len = simd_length(SIMD2<Float>(dx, dy))
                        if len > cornerRadius {
                            let norm = simd_normalize(SIMD2<Float>(dx, dy))
                            let clamped = norm * cornerRadius
                            let signX: Float = (px >= 0) ? 1.0 : -1.0
                            let signY: Float = (py >= 0) ? 1.0 : -1.0
                            px = signX * (rx + clamped.x)
                            py = signY * (ry + clamped.y)
                        }
                    }

                    xPlane = px
                    yPlane = py
                }

                let xPos: Float
                let zPos: Float
                if radius.isFinite && radius > 0 && currentAngle > 0.0001 {
                    let theta = (u - 0.5) * currentAngle
                    xPos = radius * sin(theta)
                    zPos = radius * (cos(halfAngle) - cos(theta))
                } else {
                    xPos = xPlane
                    zPos = 0.0
                }

                positions[vIndex] = [xPos, yPlane, zPos]
                let uTex = u * (1.0 - 2.0 * uvInset) + uvInset
                uvs[vIndex] = [uTex, vTex]

                if x < numQuadsX && y < numQuadsY {
                    let current = UInt32(vIndex)
                    let nextRow = current + UInt32(resX)

                    let topLeft = current
                    let topRight = topLeft + 1
                    let bottomLeft = nextRow
                    let bottomRight = bottomLeft + 1

                    indices[iIndex + 0] = topLeft
                    indices[iIndex + 1] = bottomLeft
                    indices[iIndex + 2] = bottomRight

                    indices[iIndex + 3] = topLeft
                    indices[iIndex + 4] = bottomRight
                    indices[iIndex + 5] = topRight

                    iIndex += 6
                }

                vIndex += 1
            }
        }

        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }
}

/// Holds the scene handles and the last applied transforms. RealityKit
/// delivers scene updates on the main thread, so the box needs no lock.
@MainActor
final class StreamVideoSurfaceRuntime {
    weak var screen: ModelEntity?
    var ruler: Entity?
    var confirmCard: Entity?
    var meshAspect: Float = 0

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

        let aspectChanged = abs(screenAspect - meshAspect) > 0.0001
        let sizeChanged =
            abs(size.width - lastUpdateSize.width) >= 1.0 ||
            abs(size.height - lastUpdateSize.height) >= 1.0
        guard aspectChanged || sizeChanged || lastUpdateSize == .zero else { return }
        lastUpdateSize = size

        if aspectChanged {
            rebuildMesh(aspect: screenAspect)
        }

        // Dynamic calibration: the ruler is 100 points wide, so its physical
        // width gives meters-per-point.
        if let screen, let ruler = self.ruler {
            let rulerWidth = ruler.visualBounds(relativeTo: nil).extents.x
            if rulerWidth > 0 {
                let metersPerPoint = rulerWidth / 100
                let targetWidth = Float(size.width) * metersPerPoint
                if abs(targetWidth - screen.scale.x) > 0.0001 {
                    screen.scale = [targetWidth, targetWidth, 1]
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
                screen.model?.materials = [UnlitMaterial(texture: texture)]
                appliedMode = .standard2D
                appliedTexture = textureID
            }
        } else {
            screen.model?.materials = [UnlitMaterial(texture: texture)]
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

    private func rebuildMesh(aspect: Float) {
        guard let screen else { return }
        let mesh: MeshResource
        do {
            mesh = try StreamVideoSurfaceMesh.roundedPlane(
                width: 1,
                aspectRatio: aspect,
                resolution: (256, 256),
                cornerRadiusFraction: 0.012
            )
        } catch {
            mesh = .generatePlane(width: 1, height: aspect)
        }
        screen.model?.mesh = mesh
        meshAspect = aspect
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
