import ForceSimulation
import SwiftUI
import simd

#if !os(tvOS)
    @MainActor
    extension ForceDirectedGraph {
        @inlinable
        static var minimumAlphaAfterDrag: CGFloat { 0.5 }

        // MARK: - Momentum Constants

        @inlinable
        static var minimumMomentumVelocity: Double { 50.0 }  // points/second

        @inlinable
        static var momentumDecay: Double { 0.92 }  // per frame decay factor

        @inlinable
        static var momentumStopThreshold: Double { 5.0 }  // points/second

        @inlinable
        static var momentumFrameRate: Double { 60.0 }  // fps

        @inlinable
        internal func onDragChange(
            _ value: SwiftUI.DragGesture.Value
        ) {
            if !model.isDragStartStateRecorded {
                // Stop any ongoing momentum when starting new drag
                stopMomentumAnimation()

                if let nodeID = model.findNode(at: value.startLocation) {
                    model.draggingNodeID = nodeID
                } else {
                    model.backgroundDragStart = value.location.simd
                }
                assert(model.isDragStartStateRecorded == true)
            }

            guard let nodeID = model.draggingNodeID else {
                if let dragStart = model.backgroundDragStart {
                    let delta = value.location.simd - dragStart
                    model.modelTransform.translate += delta
                    model.backgroundDragStart = value.location.simd

                    // Notify callback of background pan delta
                    model._onBackgroundPanChanged?(delta)

                    // Track velocity for momentum
                    if let lastPos = model.lastDragPosition, let lastTime = model.lastDragTime {
                        let positionDelta = value.location.simd - lastPos
                        let timeDelta = Date().timeIntervalSince(lastTime)
                        if timeDelta > 0 {
                            let instantVelocity = positionDelta / timeDelta
                            // Smoothed velocity (weighted average: 70% previous, 30% new)
                            model.dragVelocity = model.dragVelocity * 0.7 + instantVelocity * 0.3
                        }
                    }
                    model.lastDragPosition = value.location.simd
                    model.lastDragTime = Date()
                }
                return
            }

            if model.simulationContext.storage.kinetics.alpha < Self.minimumAlphaAfterDrag {
                model.simulationContext.storage.kinetics.alpha = Self.minimumAlphaAfterDrag
            }

            let newLocationInSimulation = model.finalTransform.invert(value.location.simd)

            if let nodeIndex = model.simulationContext.nodeIndexLookup[nodeID] {
                model.simulationContext.storage.kinetics.fixation[
                    nodeIndex
                ] = newLocationInSimulation
            }

            guard let action = model._onNodeDragChanged else { return }
            action(nodeID, value.location)

        }

        @inlinable
        internal func onDragEnd(
            _ value: SwiftUI.DragGesture.Value
        ) {

            guard let nodeID = model.draggingNodeID else {
                if let dragStart = model.backgroundDragStart {
                    let delta = value.location.simd - dragStart
                    model.modelTransform.translate += delta
                    model.backgroundDragStart = nil

                    // Start momentum animation if velocity is significant
                    let velocityMagnitude = simd_length(model.dragVelocity)
                    if velocityMagnitude >= Self.minimumMomentumVelocity {
                        startMomentumAnimation()
                    } else {
                        // Clear velocity tracking
                        model.lastDragPosition = nil
                        model.lastDragTime = nil
                        model.dragVelocity = .zero
                    }
                }
                return
            }
            if model.simulationContext.storage.kinetics.alpha < Self.minimumAlphaAfterDrag {
                model.simulationContext.storage.kinetics.alpha = Self.minimumAlphaAfterDrag
            }

            model.draggingNodeID = nil

            guard let nodeIndex = model.simulationContext.nodeIndexLookup[nodeID] else { return }
            if model._onNodeDragEnded == nil {
                model.simulationContext.storage.kinetics.fixation[
                    nodeIndex
                ] = nil
            } else if let action = model._onNodeDragEnded, action(nodeID, value.location) {
                model.simulationContext.storage.kinetics.fixation[
                    nodeIndex
                ] = nil
            }
        }

        @inlinable
        static var minimumDragDistance: CGFloat { 0.0 }  // Immediate touch for momentum stop
    }
    @MainActor
    extension ForceDirectedGraph {
        @inlinable
        internal func onTapGesture(
            _ location: CGPoint
        ) {
            // Stop any ongoing momentum on tap (iOS standard behavior)
            if model.momentumTimer != nil {
                stopMomentumAnimation()
            }

            // Original tap handling
            guard let action = self.model._onNodeTapped else { return }
            let nodeID = self.model.findNode(at: location)
            action(nodeID)
        }

        // MARK: - Momentum Animation

        @inlinable
        internal func startMomentumAnimation() {
            // Cancel any existing momentum
            stopMomentumAnimation()

            let frameInterval = 1.0 / Self.momentumFrameRate

            model.momentumTimer = Timer.scheduledTimer(
                withTimeInterval: frameInterval,
                repeats: true
            ) { [weak model] _ in
                guard let model = model else { return }

                // Update position based on current velocity
                model.modelTransform.translate += model.dragVelocity * frameInterval

                // Apply decay to velocity
                model.dragVelocity *= Self.momentumDecay

                // Stop if velocity drops below threshold
                let velocityMagnitude = simd_length(model.dragVelocity)
                if velocityMagnitude < Self.momentumStopThreshold {
                    Task { @MainActor [weak model] in
                        guard let model = model else { return }
                        model.momentumTimer?.invalidate()
                        model.momentumTimer = nil
                        model.dragVelocity = .zero
                        model.lastDragPosition = nil
                        model.lastDragTime = nil
                    }
                }
            }
        }

        @inlinable
        internal func stopMomentumAnimation() {
            model.momentumTimer?.invalidate()
            model.momentumTimer = nil
            model.lastDragPosition = nil
            model.lastDragTime = nil
        }
    }
#endif

#if os(iOS) || os(macOS)
    @MainActor extension ForceDirectedGraph {

        @inlinable
        static var minimumScaleDelta: CGFloat { 0.001 }

        @inlinable
        static var minimumScale: CGFloat { 1e-2 }

        @inlinable
        static var maximumScale: CGFloat { .infinity }

        @inlinable
        static var magnificationDecay: CGFloat { 0.1 }

        @inlinable
        internal func clamp(
            _ value: CGFloat,
            min: CGFloat,
            max: CGFloat
        ) -> CGFloat {
            Swift.min(Swift.max(value, min), max)
        }

        @inlinable
        internal func onMagnifyChange(
            _ value: MagnifyGesture.Value
        ) {
            var startTransform: ViewportTransform
            if let t = self.model.lastTransformRecord {
                startTransform = t
            } else {
                self.model.lastTransformRecord = self.model.modelTransform
                startTransform = self.model.modelTransform
            }

            let alpha = (startTransform.translate(by: self.model.obsoleteState.cgSize.simd / 2))
                .invert(value.startLocation.simd)

            var newScale = clamp(
                value.magnification * startTransform.scale,
                min: Self.minimumScale,
                max: Self.maximumScale)

            // Calculate velocity
            let now = Date()
            let timeDelta = now.timeIntervalSince(model.lastMagnifyTime)
            if timeDelta > 0 {
                let scaleDelta = newScale - model.lastMagnifyScale
                model.magnifyVelocity = scaleDelta / timeDelta
            }
            model.lastMagnifyScale = newScale
            model.lastMagnifyTime = now

            // Apply velocity-aware magnetic pull
            if let snapPoints = model.zoomSnapPoints {
                newScale = applyVelocityAwareMagneticPull(
                    to: newScale,
                    velocity: abs(model.magnifyVelocity),
                    snapPoints: snapPoints,
                    radius: model.zoomSnapMagnetRadius,
                    baseStrength: model.zoomSnapMagnetStrength
                )
            }

            let newTranslate = (startTransform.scale - newScale) * alpha + startTransform.translate

            let newModelTransform = ViewportTransform(
                translate: newTranslate,
                scale: newScale
            )
            self.model.modelTransform = newModelTransform

            guard let action = self.model._onGraphMagnified else { return }
            action()
        }

        @inlinable
        internal func onMagnifyEnd(
            _ value: MagnifyGesture.Value
        ) {
            var startTransform: ViewportTransform
            if let t = self.model.lastTransformRecord {
                startTransform = t
            } else {
                self.model.lastTransformRecord = self.model.modelTransform
                startTransform = self.model.modelTransform
            }

            let alpha = (startTransform.translate(by: self.model.obsoleteState.cgSize.simd / 2))
                .invert(value.startLocation.simd)

            var newScale = clamp(
                value.magnification * startTransform.scale,
                min: Self.minimumScale,
                max: Self.maximumScale)

            // Snap to nearest point on gesture end (hard snap)
            if let snapPoints = model.zoomSnapPoints {
                newScale = snapToNearest(scale: newScale, snapPoints: snapPoints)
            }

            // Reset velocity tracking
            model.magnifyVelocity = 0.0

            let newTranslate = (startTransform.scale - newScale) * alpha + startTransform.translate
            let newModelTransform = ViewportTransform(
                translate: newTranslate,
                scale: newScale
            )
            self.model.lastTransformRecord = nil
            self.model.modelTransform = newModelTransform
            guard let action = self.model._onGraphMagnified else { return }
            action()
        }

        @inlinable
        internal func applyVelocityAwareMagneticPull(
            to scale: Double,
            velocity: Double,
            snapPoints: [Double],
            radius: Double,
            baseStrength: Double
        ) -> Double {
            // Find nearest snap point
            guard let nearestSnap = snapPoints.min(by: { abs($0 - scale) < abs($1 - scale) }) else {
                return scale
            }

            let distance = abs(scale - nearestSnap)

            // Outside magnetic radius: no pull
            guard distance < radius else { return scale }

            // Calculate velocity damping (fast pinch = less pull)
            // velocity range: 0-10 (typical), normalize to 0-1
            let normalizedVelocity = min(velocity / 5.0, 1.0)
            let velocityDamping = 1.0 - (normalizedVelocity * 0.6) // Max 60% reduction

            // Distance-based strength (closer = stronger)
            let normalizedDistance = distance / radius
            let distanceMultiplier = normalizedDistance < 0.3
                ? 2.0  // Very close: double strength
                : 1.0  // Normal range

            // Combined pull strength
            let effectiveStrength = baseStrength * velocityDamping * distanceMultiplier

            // Apply pull
            return scale + (nearestSnap - scale) * effectiveStrength
        }

        @inlinable
        internal func snapToNearest(scale: Double, snapPoints: [Double]) -> Double {
            snapPoints.min(by: { abs($0 - scale) < abs($1 - scale) }) ?? scale
        }
    }
#endif

@MainActor
extension ForceDirectedGraph {
    @inlinable
    public func onTicked(
        perform action: @escaping (UInt) -> Void
    ) -> Self {
        self.model._onTicked = action
        return self
    }

    @inlinable
    public func onNodeTapped(
        perform action: @escaping (NodeID?) -> Void
    ) -> Self {
        self.model._onNodeTapped = action
        return self
    }

    @inlinable
    public func onNodeDragChanged(
        perform action: @escaping (NodeID, CGPoint) -> Void
    ) -> Self {
        self.model._onNodeDragChanged = action
        return self
    }

    @inlinable
    public func onNodeDragEnded(
        shouldBeFixed action: @escaping (NodeID, CGPoint) -> Bool
    ) -> Self {
        self.model._onNodeDragEnded = action
        return self
    }

    @inlinable
    public func onGraphMagnified(
        perform action: @escaping () -> Void
    ) -> Self {
        return self
    }

    @inlinable
    public func onBackgroundPanChanged(
        perform action: @escaping (SIMD2<Double>) -> Void
    ) -> Self {
        self.model._onBackgroundPanChanged = action
        return self
    }

    @inlinable
    public func zoomSnapping(
        points: [Double],
        magnetRadius: Double = 0.15,
        magnetStrength: Double = 0.4
    ) -> Self {
        self.model.zoomSnapPoints = points
        self.model.zoomSnapMagnetRadius = magnetRadius
        self.model.zoomSnapMagnetStrength = magnetStrength
        return self
    }

}
