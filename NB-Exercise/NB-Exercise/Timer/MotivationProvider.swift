//
//  MotivationProvider.swift
//  NBExercise
//
//  The encouragement shown under the countdown while a session runs.
//
//  Two kinds of line share one slot:
//
//    1. Generic encouragement, drawn from a 50-line list and rotated every
//       few seconds.
//    2. Milestones — "halfway", "2 minutes to go" — which fire once each as
//       the session crosses them and take the slot for long enough to be
//       read.
//
//  It also supplies the sign-off shown when the clock reaches zero.
//
//  A plain value type rather than an @Observable of its own: the timer store
//  already ticks five times a second and publishes the resulting line, so
//  this only needs to answer "what should it say now?".
//

import Foundation

struct MotivationProvider {

    /// The line to show right now, or `nil` when there's nothing to say.
    private(set) var message: String?

    /// How long a generic line stays up before being swapped for another.
    private static let rotationInterval: TimeInterval = 25

    /// How long a milestone holds the slot. Long enough to read, short
    /// enough that two milestones close together both get their turn.
    private static let milestoneHold: TimeInterval = 8

    /// Inside the final stretch the last thing said stays said. Rotating to
    /// a generic line after "Last 10 seconds" reads as the app losing track.
    private static let pinFinalSeconds: TimeInterval = 15

    /// How close a milestone has to be for a generic line to yield to it.
    private static let imminentWindow: TimeInterval = 6

    /// Remaining lines in the current shuffle. Drawing from a deck rather
    /// than calling `randomElement()` means all 50 are seen before any
    /// repeats.
    private var deck: [String] = []

    /// The same idea for sign-offs, but deliberately *not* cleared by
    /// `reset()`: it has to outlive a session, or every workout would have a
    /// one-in-twenty chance of ending on the line the last one ended on.
    private var congratulationDeck: [String] = []

    private var queuedMilestones: [Milestone] = []
    private var firedMilestones: Set<Milestone> = []

    private var holdUntil: Date = .distantPast
    private var nextRotation: Date = .distantPast

    // MARK: - Lifecycle

    /// Clears everything, so the next session starts from a full deck with
    /// every milestone available again. Called when a session ends or is
    /// abandoned — not when it's merely paused.
    mutating func reset() {
        message = nil
        deck = []
        queuedMilestones = []
        firedMilestones = []
        holdUntil = .distantPast
        nextRotation = .distantPast
    }

    /// A sign-off for a session that made it to zero.
    mutating func congratulate() -> String {
        if congratulationDeck.isEmpty {
            congratulationDeck = Self.congratulations.shuffled()
        }
        // Left non-optional: the list is a non-empty literal, so the deck is
        // never empty by the time we pop it.
        return congratulationDeck.removeLast()
    }

    /// Puts a line up immediately, rather than leaving the slot empty until
    /// the first rotation comes round. Milestones already passed stay passed,
    /// so resuming a paused session doesn't re-announce the halfway mark.
    mutating func resume(now: Date = Date()) {
        holdUntil = .distantPast
        drawEncouragement(now: now)
    }

    /// Advances the line for the current point in the session.
    mutating func update(remaining: TimeInterval, total: TimeInterval, now: Date = Date()) {
        collectMilestones(remaining: remaining, total: total)

        guard now >= holdUntil else { return }

        // A queued milestone waits for the previous line's hold to expire,
        // so two crossings in quick succession are both shown instead of one
        // silently replacing the other.
        if !queuedMilestones.isEmpty {
            message = queuedMilestones.removeFirst().text
            holdUntil = now.addingTimeInterval(Self.milestoneHold)
            nextRotation = holdUntil.addingTimeInterval(Self.rotationInterval)
            return
        }

        guard now >= nextRotation,
              remaining > Self.pinFinalSeconds,
              !isMilestoneImminent(remaining: remaining, total: total)
        else { return }
        drawEncouragement(now: now)
    }

    // MARK: - Generic encouragement

    private mutating func drawEncouragement(now: Date) {
        if deck.isEmpty {
            deck = Self.encouragements.shuffled()
        }
        // A fresh shuffle can deal the line that's already on screen; move it
        // aside so a rotation always looks like something changed.
        if deck.last == message, deck.count > 1 {
            deck.swapAt(deck.count - 1, 0)
        }
        message = deck.popLast()
        nextRotation = now.addingTimeInterval(Self.rotationInterval)
    }

    // MARK: - Milestones

    private mutating func collectMilestones(remaining: TimeInterval, total: TimeInterval) {
        for milestone in Milestone.allCases where !firedMilestones.contains(milestone) {
            guard let threshold = milestone.threshold(for: total),
                  remaining <= threshold
            else { continue }
            firedMilestones.insert(milestone)
            queuedMilestones.append(milestone)
        }
    }

    /// Whether a milestone is about to land. A generic line drawn two
    /// seconds before "only 2 minutes now" flashes up and vanishes, which
    /// reads as a glitch — better to hold the current line and let the
    /// milestone take the slot cleanly.
    private func isMilestoneImminent(remaining: TimeInterval, total: TimeInterval) -> Bool {
        Milestone.allCases.contains { milestone in
            guard !firedMilestones.contains(milestone),
                  let threshold = milestone.threshold(for: total)
            else { return false }
            return remaining - threshold < Self.imminentWindow
        }
    }
}

// MARK: - Milestone

/// A point in the session worth calling out. Declared in roughly the order
/// they'd be crossed, which is the order they queue in on the rare tick that
/// crosses two at once.
private enum Milestone: CaseIterable {
    case quarter
    case tenMinutes
    case halfway
    case threeQuarters
    case fiveMinutes
    case threeMinutes
    case twoMinutes
    case oneMinute
    case thirtySeconds
    case tenSeconds

    /// The time-remaining mark this fires at, or `nil` when it isn't worth
    /// announcing for a session of this length.
    ///
    /// The minimum totals matter: without them a 10-minute session would
    /// open by announcing "10 minutes to go", and a 3-minute one would fire
    /// half the list in its first seconds.
    func threshold(for total: TimeInterval) -> TimeInterval? {
        switch self {
        case .quarter:       total >= 12 * 60 ? total * 0.75 : nil
        case .halfway:       total >= 4 * 60 ? total * 0.5 : nil
        case .threeQuarters: total >= 12 * 60 ? total * 0.25 : nil
        case .tenMinutes:    total >= 12 * 60 ? 10 * 60 : nil
        case .fiveMinutes:   total >= 7 * 60 ? 5 * 60 : nil
        case .threeMinutes:  total >= 5 * 60 ? 3 * 60 : nil
        case .twoMinutes:    total >= 4 * 60 ? 2 * 60 : nil
        case .oneMinute:     total >= 3 * 60 ? 60 : nil
        case .thirtySeconds: total >= 2 * 60 ? 30 : nil
        case .tenSeconds:    total >= 60 ? 10 : nil
        }
    }

    var text: String {
        switch self {
        case .quarter:       "A quarter of the way in. Settle into it."
        case .tenMinutes:    "10 minutes to go."
        case .halfway:       "You're at the halfway mark."
        case .threeQuarters: "Three quarters done — the rest is downhill."
        case .fiveMinutes:   "5 minutes to go. Hold the pace."
        case .threeMinutes:  "3 minutes left. Stay with it."
        case .twoMinutes:    "Come on, only 2 minutes now."
        case .oneMinute:     "1 minute to go. Finish strong."
        case .thirtySeconds: "30 seconds. Don't ease off."
        case .tenSeconds:    "Last 10 seconds — empty the tank."
        }
    }
}

// MARK: - The list

private extension MotivationProvider {

    /// Deliberately short lines: this sits under a countdown the user is
    /// glancing at mid-effort, not reading.
    static let encouragements = [
        "Keep going.",
        "You can do it.",
        "One minute at a time.",
        "Your future self is watching.",
        "Strong work.",
        "Breathe. Settle in.",
        "This is the part that counts.",
        "Nobody regrets finishing.",
        "Steady wins it.",
        "You've done harder things.",
        "Find your rhythm.",
        "Every second is banked.",
        "Show up, stay up.",
        "That's the spirit.",
        "Hold the pace.",
        "Progress, not perfection.",
        "You're stronger than the clock.",
        "Don't think — just move.",
        "Good. Keep that going.",
        "This is how it gets easier.",
        "Small efforts, stacked.",
        "Own this session.",
        "Let the timer do the worrying.",
        "You started. That was the hard bit.",
        "Keep the form, keep the pace.",
        "Momentum is on your side.",
        "Feel that? That's it working.",
        "Chin up, shoulders back.",
        "Nothing to prove. Just keep moving.",
        "You're doing the work.",
        "Push a little, not a lot.",
        "Consistency beats intensity.",
        "Stay with it.",
        "Another one in the bank.",
        "Your heart is saying thank you.",
        "Tired is temporary.",
        "Quitting takes longer than finishing.",
        "Eyes forward.",
        "You've got more in you.",
        "This counts. All of it.",
        "Keep it smooth.",
        "One rep, one step, one breath.",
        "Earn the shower.",
        "You against yesterday.",
        "Doing beats planning.",
        "Almost is still ahead of never.",
        "Loosen the jaw, drop the shoulders.",
        "Set a pace you can hold.",
        "Still going. That's the whole trick.",
        "Finish what you started."
    ]

    /// Shown once, next to "complete", when the clock reaches zero. Longer
    /// than the in-session lines — the user has stopped moving and can
    /// actually read this one.
    static let congratulations = [
        "Session complete. Well done.",
        "That's done, and nicely held.",
        "You finished. That's the whole thing.",
        "Done — and you showed up for it.",
        "Strong finish.",
        "That one's in the bank.",
        "Well run. Go enjoy the rest of the day.",
        "Complete. Your future self says thanks.",
        "You said you would, and you did.",
        "That's how it's done.",
        "Finished, with nothing left owing.",
        "Another one done. They add up.",
        "Nice work — all the way to zero.",
        "You saw it through.",
        "Done and dusted.",
        "Earned. Go get that shower.",
        "That's a win. Take it.",
        "Beautifully finished.",
        "You outlasted the clock.",
        "Banked. Same again soon?"
    ]
}
