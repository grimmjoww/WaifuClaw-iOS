import SpriteKit
import SwiftUI

/// Generic, real SpriteKit companion rig. Callers supply a mood derived from an
/// actual native agent run; this view neither invents nor displays agent state.
struct CompanionSpriteView: UIViewRepresentable {
    let mood: KlineSpriteMood
    private let companionOverride: CompanionID?

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @AppStorage(CompanionID.selectionStorageKey)
    private var storedCompanionID = CompanionID.defaultSelection.rawValue

    /// Passing `nil` follows the user's persisted visual choice.
    init(mood: KlineSpriteMood, companion: CompanionID? = nil) {
        self.mood = mood
        companionOverride = companion
    }

    private var selectedCompanion: CompanionID {
        companionOverride ?? CompanionID.selected(from: storedCompanionID)
    }

    func makeUIView(context: Context) -> CompanionSpriteHostView {
        let host = CompanionSpriteHostView()
        let view = host.spriteView
        let companion = selectedCompanion
        let scene = CompanionSpriteScene(companion: companion.definition)
        view.presentScene(scene)
        configure(view, scene: scene, companion: companion)
        return host
    }

    func updateUIView(_ host: CompanionSpriteHostView, context: Context) {
        let view = host.spriteView
        let companion = selectedCompanion
        let scene: CompanionSpriteScene
        if let currentScene = view.scene as? CompanionSpriteScene,
           currentScene.companionID == companion {
            scene = currentScene
        } else {
            scene = CompanionSpriteScene(companion: companion.definition)
            view.presentScene(scene)
        }
        configure(view, scene: scene, companion: companion)
    }

    private func configure(
        _ view: SKView,
        scene: CompanionSpriteScene,
        companion: CompanionID
    ) {
        let definition = companion.definition
        scene.configure(mood: mood, reduceMotion: reduceMotion)
        view.accessibilityLabel = mood.accessibilityDescription(for: definition.name)
        view.accessibilityValue = mood.visualStateTitle
    }
}

/// SpriteKit paints the unused margins of an `.aspectFit` square SKScene black
/// inside a portrait SKView, even when both the scene and view are transparent.
/// Fit a real *square SKView* inside a clear portrait UIKit container instead;
/// the companion keeps its proportions and the remaining host margins stay clear.
final class CompanionSpriteHostView: UIView {
    let spriteView = SKView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        spriteView.backgroundColor = .clear
        spriteView.isOpaque = false
        spriteView.allowsTransparency = true
        spriteView.ignoresSiblingOrder = true
        spriteView.preferredFramesPerSecond = 60
        spriteView.isAccessibilityElement = true
        spriteView.accessibilityTraits = .image
        addSubview(spriteView)
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        spriteView.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }
}

/// A separate SwiftUI label for callers that need visible state text next to the
/// art. State is never rasterized into, or drawn by, the SpriteKit texture rig.
struct CompanionMoodLabel: View {
    let mood: KlineSpriteMood
    let companion: CompanionID

    var body: some View {
        Text(mood.visualStateTitle)
            .accessibilityLabel(mood.accessibilityDescription(for: companion.definition.name))
    }
}

extension KlineSpriteMood {
    /// Short presentation text for a separate SwiftUI label, never sprite art.
    var visualStateTitle: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Working"
        case .reading: "Reading"
        case .completed: "Completed"
        case .failed: "Needs attention"
        }
    }

    /// Names the selected visual companion while preserving the actual mood.
    func accessibilityDescription(for companionName: String) -> String {
        switch self {
        case .idle: "\(companionName) is idle"
        case .thinking: "\(companionName) is working on a model request"
        case .reading: "\(companionName) is inspecting the selected project"
        case .completed: "\(companionName)'s agent run completed"
        case .failed: "\(companionName)'s agent run failed"
        }
    }
}

final class CompanionSpriteScene: SKScene {
    private let companion: CompanionDefinition
    private let leftAppendage = SKNode()
    private let rightAppendage = SKNode()
    private let body: SKSpriteNode
    private let blinkEyes: SKSpriteNode
    private var configuredMood: KlineSpriteMood?
    private var configuredReduceMotion: Bool?

    var companionID: CompanionID { companion.id }

    init(companion: CompanionDefinition) {
        self.companion = companion
        body = SKSpriteNode(imageNamed: companion.textures.body)
        blinkEyes = SKSpriteNode(imageNamed: companion.textures.blinkEyes)
        super.init(size: CGSize(width: 960, height: 960))
        buildRig()
    }

    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    private func buildRig() {
        backgroundColor = .clear
        anchorPoint = .zero
        scaleMode = .aspectFit

        leftAppendage.name = "appendage.left"
        rightAppendage.name = "appendage.right"
        body.name = "body"
        blinkEyes.name = "face.blink"

        addAppendage(
            leftAppendage,
            textureName: companion.textures.leftAppendage,
            pivot: companion.articulation.leftPivot
        )
        addAppendage(
            rightAppendage,
            textureName: companion.textures.rightAppendage,
            pivot: companion.articulation.rightPivot
        )
        leftAppendage.zPosition = -2
        rightAppendage.zPosition = -1

        body.size = size
        body.position = CGPoint(x: size.width / 2, y: size.height / 2)
        body.zPosition = 0
        addChild(body)

        blinkEyes.size = size
        blinkEyes.position = body.position
        blinkEyes.alpha = 0
        blinkEyes.zPosition = 1
        addChild(blinkEyes)
    }

    private func addAppendage(_ pivotNode: SKNode, textureName: String, pivot: CGPoint) {
        pivotNode.position = pivot
        let texture = SKSpriteNode(imageNamed: textureName)
        texture.size = size
        // Counter-translate the aligned canvas so the source point becomes the pivot.
        texture.position = CGPoint(x: size.width / 2 - pivot.x, y: size.height / 2 - pivot.y)
        pivotNode.addChild(texture)
        addChild(pivotNode)
    }

    func configure(mood: KlineSpriteMood, reduceMotion: Bool) {
        guard mood != configuredMood || reduceMotion != configuredReduceMotion else { return }
        configuredMood = mood
        configuredReduceMotion = reduceMotion

        [leftAppendage, rightAppendage, body, blinkEyes].forEach { $0.removeAllActions() }
        leftAppendage.zRotation = 0
        rightAppendage.zRotation = 0
        body.setScale(1)
        blinkEyes.alpha = 0

        // Reduce Motion leaves the fully rendered companion visible but still.
        guard !reduceMotion else { return }

        let profile = AnimationProfile.forMood(mood, appendageKind: companion.appendageKind)
        leftAppendage.run(
            Self.sway(to: profile.appendageAmplitude, duration: profile.appendageDuration),
            withKey: "appendage.left.sway"
        )
        // Deliberately offset speed and amplitude so child appendages never move as one card.
        rightAppendage.run(
            Self.sway(
                to: -profile.appendageAmplitude * 0.88,
                duration: profile.appendageDuration * 0.91
            ),
            withKey: "appendage.right.sway"
        )
        body.run(
            Self.breathe(scale: profile.breathScale, duration: profile.breathDuration),
            withKey: "body.breathe"
        )
        blinkEyes.run(
            Self.blink(repeatAfter: profile.blinkInterval),
            withKey: "face.blink"
        )
    }

    private static func sway(to angle: CGFloat, duration: TimeInterval) -> SKAction {
        let outward = SKAction.rotate(toAngle: angle, duration: duration, shortestUnitArc: true)
        outward.timingMode = .easeInEaseOut
        let center = SKAction.rotate(toAngle: 0, duration: duration, shortestUnitArc: true)
        center.timingMode = .easeInEaseOut
        return .repeatForever(.sequence([outward, center]))
    }

    private static func breathe(scale: CGFloat, duration: TimeInterval) -> SKAction {
        let inhale = SKAction.scale(to: scale, duration: duration)
        inhale.timingMode = .easeInEaseOut
        let exhale = SKAction.scale(to: 1, duration: duration)
        exhale.timingMode = .easeInEaseOut
        return .repeatForever(.sequence([inhale, exhale]))
    }

    private static func blink(repeatAfter interval: TimeInterval) -> SKAction {
        .repeatForever(.sequence([
            .wait(forDuration: interval),
            .fadeIn(withDuration: 0.055),
            .wait(forDuration: 0.095),
            .fadeOut(withDuration: 0.075),
            .wait(forDuration: 0.65)
        ]))
    }
}

private struct AnimationProfile {
    let appendageDuration: TimeInterval
    let appendageAmplitude: CGFloat
    let breathDuration: TimeInterval
    let breathScale: CGFloat
    let blinkInterval: TimeInterval

    static func forMood(
        _ mood: KlineSpriteMood,
        appendageKind: CompanionAppendageKind
    ) -> AnimationProfile {
        let appendageMultiplier: CGFloat = appendageKind == .tails ? 0.78 : 1
        switch mood {
        case .idle:
            return AnimationProfile(appendageDuration: 2.4, appendageAmplitude: 0.045 * appendageMultiplier, breathDuration: 1.7, breathScale: 1.012, blinkInterval: 3.4)
        case .thinking:
            return AnimationProfile(appendageDuration: 0.72, appendageAmplitude: 0.115 * appendageMultiplier, breathDuration: 1.05, breathScale: 1.018, blinkInterval: 2.1)
        case .reading:
            return AnimationProfile(appendageDuration: 1.35, appendageAmplitude: 0.075 * appendageMultiplier, breathDuration: 1.4, breathScale: 1.014, blinkInterval: 2.9)
        case .completed:
            return AnimationProfile(appendageDuration: 0.95, appendageAmplitude: 0.095 * appendageMultiplier, breathDuration: 1.15, breathScale: 1.016, blinkInterval: 3.1)
        case .failed:
            return AnimationProfile(appendageDuration: 2.8, appendageAmplitude: 0.022 * appendageMultiplier, breathDuration: 2.0, breathScale: 1.008, blinkInterval: 3.8)
        }
    }
}
