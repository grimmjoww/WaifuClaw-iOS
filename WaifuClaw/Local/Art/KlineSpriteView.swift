import SpriteKit
import SwiftUI

/// Visual feedback follows actual on-device agent state, not mocked telemetry.
enum KlineSpriteMood: Equatable {
    case idle
    case thinking
    case reading
    case completed
    case failed

    var accessibilityDescription: String {
        switch self {
        case .idle: "Kline is idle"
        case .thinking: "Kline is working on a model request"
        case .reading: "Kline is inspecting the selected project"
        case .completed: "Kline's agent run completed"
        case .failed: "Kline's agent run failed"
        }
    }
}

/// A real 2D sprite rig. Its alpha textures are independently rendered in
/// SpriteKit: wing pivots articulate at the shoulders; only the changed eyes
/// blink; the body breathes. No video, static card wobble, or fabricated status.
struct KlineSpriteView: UIViewRepresentable {
    let mood: KlineSpriteMood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> SKView {
        let view = SKView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 60
        let scene = KlineScene(size: CGSize(width: 960, height: 960))
        scene.scaleMode = .aspectFit
        view.presentScene(scene)
        scene.configure(mood: mood, reduceMotion: reduceMotion)
        view.isAccessibilityElement = true
        view.accessibilityLabel = mood.accessibilityDescription
        return view
    }

    func updateUIView(_ view: SKView, context: Context) {
        (view.scene as? KlineScene)?.configure(mood: mood, reduceMotion: reduceMotion)
        view.accessibilityLabel = mood.accessibilityDescription
    }
}

private final class KlineScene: SKScene {
    private let leftWing = SKNode()
    private let rightWing = SKNode()
    private let body = SKSpriteNode(imageNamed: "KlineBody")
    private let blinkEyes = SKSpriteNode(imageNamed: "KlineBlinkEyes")
    private var configuredMood: KlineSpriteMood?
    private var configuredReduceMotion: Bool?

    override init(size: CGSize) {
        super.init(size: size)
        buildRig()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        buildRig()
    }

    private func buildRig() {
        backgroundColor = .clear
        anchorPoint = CGPoint(x: 0, y: 0)

        // Every optimized texture is an aligned transparent 960-square canvas.
        // Child offsets cancel their parent's pivot translation at rest.
        addWing(leftWing, textureName: "KlineWingLeft", pivot: CGPoint(x: 318, y: 685))
        addWing(rightWing, textureName: "KlineWingRight", pivot: CGPoint(x: 457, y: 685))
        leftWing.zPosition = -2
        rightWing.zPosition = -1

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

    private func addWing(_ pivotNode: SKNode, textureName: String, pivot: CGPoint) {
        pivotNode.position = pivot
        let image = SKSpriteNode(imageNamed: textureName)
        image.size = size
        image.position = CGPoint(x: size.width / 2 - pivot.x, y: size.height / 2 - pivot.y)
        pivotNode.addChild(image)
        addChild(pivotNode)
    }

    func configure(mood: KlineSpriteMood, reduceMotion: Bool) {
        guard mood != configuredMood || reduceMotion != configuredReduceMotion else { return }
        configuredMood = mood
        configuredReduceMotion = reduceMotion
        [leftWing, rightWing, body, blinkEyes].forEach { $0.removeAllActions() }
        leftWing.zRotation = 0
        rightWing.zRotation = 0
        body.setScale(1)
        blinkEyes.alpha = 0

        guard !reduceMotion else { return }

        let duration: TimeInterval
        let amplitude: CGFloat
        switch mood {
        case .idle: (duration, amplitude) = (2.4, 0.045)
        case .thinking: (duration, amplitude) = (0.72, 0.115)
        case .reading: (duration, amplitude) = (1.35, 0.075)
        case .completed: (duration, amplitude) = (0.95, 0.095)
        case .failed: (duration, amplitude) = (2.8, 0.022)
        }
        leftWing.run(Self.flap(to: amplitude, duration: duration), withKey: "wing.flap")
        rightWing.run(Self.flap(to: -amplitude, duration: duration), withKey: "wing.flap")
        let inhale = SKAction.scale(to: 1.012, duration: 1.7)
        inhale.timingMode = .easeInEaseOut
        let exhale = SKAction.scale(to: 1, duration: 1.7)
        exhale.timingMode = .easeInEaseOut
        body.run(.repeatForever(.sequence([inhale, exhale])), withKey: "body.breathe")
        blinkEyes.run(.repeatForever(.sequence([
            .wait(forDuration: mood == .thinking ? 2.1 : 3.4),
            .fadeIn(withDuration: 0.055),
            .wait(forDuration: 0.095),
            .fadeOut(withDuration: 0.075),
            .wait(forDuration: 0.65)
        ])), withKey: "face.blink")
    }

    private static func flap(to angle: CGFloat, duration: TimeInterval) -> SKAction {
        let up = SKAction.rotate(toAngle: angle, duration: duration, shortestUnitArc: true)
        up.timingMode = .easeInEaseOut
        let down = SKAction.rotate(toAngle: 0, duration: duration, shortestUnitArc: true)
        down.timingMode = .easeInEaseOut
        return .repeatForever(.sequence([up, down]))
    }
}
