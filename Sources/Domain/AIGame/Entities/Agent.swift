import Foundation

public enum Agent {
    public static let gravity: Float = -3.6
    public static let jumpImpulse: Float = 1.8
    public static let groundEpsilon: Float = 0.02
    public static let agentHalfHeight: Float = 0.10

    /// Advance an agent one tick. Returns the new state. `jumpHeld` is the
    /// caller-owned latch used to enforce single-impulse jumps (caller passes
    /// the same Bool for the same agent across frames).
    public static func step(state: AgentState, world: World, nn: NeuralNetwork,
                            dt: Float, jumpHeld: inout Bool,
                            audio: AudioDrive = .silence,
                            jumpImpulseMultiplier: Float = 1.0) -> AgentState {
        var s = state
        guard s.alive else { return s }

        // 1) Build NN inputs from the next obstacle (if any).
        let next = nextObstacle(after: s.posX, in: world)
        let inputs = nnInputs(state: s, next: next, world: world)
        let out = nn.forward(inputs)
        let jumpOut = out[0]
        // out[1] is duck — we keep the NN dimensionality but the simple physics
        // model below only needs to track grounded jump impulses; duck is
        // applied at collision time as a hitbox shrink.

        // 2) Jump impulse with edge-detect.
        let groundY = world.groundY(atWorldX: s.posX)
        let onGround = (s.posY - groundY) <= groundEpsilon
        let pressed = jumpOut > 0.55
        if pressed, onGround, !jumpHeld {
            s.velY = jumpImpulse * jumpImpulseMultiplier
        }
        jumpHeld = pressed

        // 3) Gravity + integrate.
        s.velY += gravity * dt
        s.posY += s.velY * dt
        s.posX += worldScrollSpeed(audio) * dt
        if s.posY < groundY {
            s.posY = groundY
            s.velY = 0
        }

        // 4) Collision against any overlapping obstacle.
        let agentTop    = s.posY + (out[1] > 0.5 ? agentHalfHeight * 0.5 : agentHalfHeight)
        let agentBottom = s.posY - agentHalfHeight * 0.4
        for o in world.obstacles where o.xStart <= s.posX && s.posX <= o.xEnd {
            switch o.kind {
            case .spike:
                if agentBottom < groundY + o.height { s.alive = false }
            case .ceiling:
                if agentTop > 1.0 - o.height { s.alive = false }
            case .pit:
                if s.posY - groundY < 0.05 { s.alive = false }
            }
            if !s.alive { break }
        }

        // 5) Fitness.
        if s.alive {
            s.fitness += worldScrollSpeed(audio) * dt + 0.05 * dt * audio.flux
        }
        return s
    }

    public static func worldScrollSpeed(_ audio: AudioDrive) -> Float {
        4.0 * (1.0 + 0.5 * audio.bass)
    }

    private static func nextObstacle(after x: Float, in world: World) -> Obstacle? {
        world.obstacles.filter { $0.xEnd > x }.min { $0.xStart < $1.xStart }
    }

    private static func nnInputs(state: AgentState, next: Obstacle?, world: World) -> [Float] {
        let groundY = world.groundY(atWorldX: state.posX)
        let dist = next.map { max(0, $0.xStart - state.posX) } ?? 1.5
        let h: Float = next.map { o in
            switch o.kind { case .pit: return -o.height; default: return o.height }
        } ?? 0
        return [
            (min(dist / 1.5, 1)) * 2 - 1,
            (min(abs(h) / 0.5, 1) * (h >= 0 ? 1 : -1)) * 2 - 1,
            max(-1, min(1, state.velY / 3.0)),
            (min(max(0, state.posY - groundY) / 0.6, 1)) * 2 - 1,
        ]
    }
}
