//
//  Format.swift
//  NBExercise
//
//  Shared display formatting. Kept in one place so a duration reads the same
//  in the timer, the stats tiles, and the now-playing bar.
//

import Foundation

enum Format {

    /// A duration as "1h 24m", "45m", or "32s". Deliberately compact — these
    /// land in stat tiles and list rows where space is tight.
    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        guard total > 0 else { return "—" }

        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// A countdown as MM:SS, or H:MM:SS once past an hour. Used by the timer,
    /// where every second has to be legible.
    static func clock(_ interval: TimeInterval) -> String {
        // Round up so a timer started at 25:00 shows "25:00", not "24:59".
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Kilocalories, e.g. "348 kcal". Measurement formatting handles the
    /// locale's unit conventions.
    static func energy(_ kilocalories: Double) -> String {
        guard kilocalories > 0 else { return "—" }
        let measurement = Measurement(value: kilocalories, unit: UnitEnergy.kilocalories)
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .workout,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )
        )
    }

    /// Distance in the user's preferred units — `.road` usage gives miles in
    /// the US and kilometres elsewhere, matching what Fitness shows.
    static func distance(_ meters: Double) -> String {
        guard meters > 0 else { return "—" }
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .road,
                numberFormatStyle: .number.precision(
                    .fractionLength(meters >= 1000 ? 1 : 0)
                )
            )
        )
    }

    /// Heart rate as "152 bpm".
    static func heartRate(_ bpm: Double) -> String {
        guard bpm > 0 else { return "—" }
        return "\(Int(bpm.rounded())) bpm"
    }
}
