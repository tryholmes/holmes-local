import SwiftUI
import AppKit

struct NoirAnimations {
    static let defaultDuration: Double = 0.3
    static let slowDuration: Double = 0.5
    static let fastDuration: Double = 0.2

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var smooth: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: defaultDuration)
    }

    static var spring: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.3, dampingFraction: 0.8)
    }

    static var gentleSpring: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.4, dampingFraction: 0.7)
    }

    static var breathing: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 3).repeatForever(autoreverses: true)
    }

    static var pulse: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    }

    static var fadeIn: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: fastDuration)
    }

    static var fadeOut: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeIn(duration: fastDuration)
    }
}
