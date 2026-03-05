import SwiftUI

// MARK: - Onboarding

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var contentReady = false
    @State private var sequenceStarted = false
    @State private var portVisible: [Bool] = Array(repeating: false, count: 8)
    @State private var portsGone = false
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var buttonsVisible = false
    private static var hasAnimatedThisLaunch = false

    private let ports: [(label: String, x: CGFloat, y: CGFloat)] = [
        ("localhost:3000",  53,  44),
        ("localhost:5173", 266,  31),
        ("localhost:8080",  35, 135),
        ("localhost:4000", 257, 131),
        ("localhost:3001", 140,  78),
        ("localhost:9000",  71, 222),
        ("localhost:8000", 260, 211),
        ("localhost:5000", 163, 182),
    ]

    private let revealDelays: [Double] = [0.05, 0.25, 0.42, 0.56, 0.67, 0.75, 0.81, 0.86]

    var body: some View {
        ZStack {
            ForEach(ports.indices, id: \.self) { i in
                ScrambleText(target: ports[i].label, trigger: portVisible[i])
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(portsGone ? 0 : 0.22))
                    .blur(radius: portVisible[i] ? (portsGone ? 6 : 0) : 4)
                    .scaleEffect(portVisible[i] ? (portsGone ? 0.94 : 1) : 0.88)
                    .opacity(portVisible[i] ? (portsGone ? 0 : 1) : 0)
                    .position(x: ports[i].x, y: ports[i].y)
            }

            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    Text("localhost,\norganized.")
                        .font(.system(size: 32, weight: .semibold))
                        .tracking(-0.5)
                        .lineSpacing(2)
                        .padding(.bottom, 14)
                        .modifier(RevealModifier(visible: titleVisible))

                    Text("A menu bar app that tracks your\ndev servers across projects.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .modifier(RevealModifier(visible: subtitleVisible))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)

                Spacer()

                HStack(spacing: 10) {
                    Button("Get Started") {
                        hasCompletedOnboarding = true
                    }
                    .buttonStyle(OnboardingButtonStyle())

                    Spacer()

                    Button("Follow on X") {
                        if let url = URL(string: "https://x.com/eduardwieandt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
                .modifier(RevealModifier(visible: buttonsVisible))
            }
        }
        .frame(width: 340, height: 270)
        .clipped()
        .opacity(contentReady ? 1 : 0)
        .task {
            if Self.hasAnimatedThisLaunch {
                contentReady = true
                titleVisible = true
                subtitleVisible = true
                buttonsVisible = true
                return
            }
            try? await Task.sleep(for: .seconds(0.25))
            contentReady = true
            guard !sequenceStarted else { return }
            sequenceStarted = true
            Self.hasAnimatedThisLaunch = true
            await runSequence()
        }
    }

    private func runSequence() async {
        for i in ports.indices {
            let delay = revealDelays[i]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.easeOut(duration: 0.16)) {
                    portVisible[i] = true
                }
            }
        }

        try? await Task.sleep(for: .seconds(1.7))
        withAnimation(.easeInOut(duration: 0.35)) {
            portsGone = true
        }

        withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.25)) {
            titleVisible = true
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.42)) {
            subtitleVisible = true
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.55)) {
            buttonsVisible = true
        }
    }
}

// MARK: - Scramble Text

struct ScrambleText: View {
    let target: String
    let trigger: Bool
    @State private var displayed: String = ""
    @State private var scrambleTask: Task<Void, Never>?

    private static let glyphs: [Character] = Array("0123456789abcdefABCDEF!@#$%&*?<>{}[]|~")

    var body: some View {
        Text(displayed.isEmpty ? target : displayed)
            .onChange(of: trigger) { _, active in
                if active { startScramble() }
            }
            .onDisappear {
                scrambleTask?.cancel()
                scrambleTask = nil
            }
    }

    private func startScramble() {
        scrambleTask?.cancel()
        displayed = scrambled(progress: 0)
        let steps = 14
        scrambleTask = Task {
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(0.04))
                guard !Task.isCancelled else { return }
                if step >= steps {
                    displayed = target
                } else {
                    displayed = scrambled(progress: Double(step) / Double(steps))
                }
            }
        }
    }

    private func scrambled(progress: Double) -> String {
        let resolvedUpTo = Int(Double(target.count) * progress)
        return String(target.enumerated().map { (i, c) in
            if i < resolvedUpTo || c == ":" || c == "/" || c == "." { return c }
            return Self.glyphs.randomElement() ?? c
        })
    }
}

// MARK: - Reveal Modifier

struct RevealModifier: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 6)
            .scaleEffect(visible ? 1 : 0.96, anchor: .bottom)
            .offset(y: visible ? 0 : 8)
    }
}

// MARK: - Button Styles

struct OnboardingButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.7 : 1))
            )
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.4 : 0.6))
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.06 : 0.08))
            )
    }
}
