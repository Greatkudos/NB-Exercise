//
//  SettingsView.swift
//  NBExercise
//
//  The session preferences, moved off the Exercise screen. They're set once
//  and then left alone, so they were costing the countdown vertical space
//  they didn't earn.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var store: ExerciseTimerStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Footers rather than accessibility hints: with the room a
                // settings screen affords, everyone gets the explanation
                // instead of only VoiceOver users.
                Section {
                    Toggle(isOn: $store.showsMotivation) {
                        Label("Motivational Messages", systemImage: "quote.bubble")
                    }
                } footer: {
                    Text("Shows encouragement under the countdown while a session runs, and a sign-off when it finishes.")
                }

                Section {
                    Toggle(isOn: $store.keepsScreenAwake) {
                        Label("Keep Screen Awake", systemImage: "sun.max")
                    }
                } footer: {
                    Text("Stops the screen dimming and locking while a session runs. The timer keeps time either way — turn this off to save battery.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView(store: ExerciseTimerStore())
}
