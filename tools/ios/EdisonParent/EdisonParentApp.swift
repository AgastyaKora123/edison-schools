//
//  EdisonParentApp.swift
//  Edison Parent
//

import SwiftUI

@main
struct EdisonParentApp: App {

    @StateObject private var store = KnowledgeStore()
    @StateObject private var practice = PracticeStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Registration has to happen before launch finishes, so it cannot wait
        // for .task. The closure defers reaching the store until the task
        // actually fires.
        ClosingNotifier.registerBackgroundTask { [weak storeBox = Self.sharedBox] in
            storeBox?.store
        }
    }

    /// BGTaskScheduler hands work back long after the view tree is gone, so
    /// the task needs a reference that outlives it.
    final class Box { weak var store: KnowledgeStore? }
    static let sharedBox = Box()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(practice)
                .task {
                    Self.sharedBox.store = store
                    store.load()
                    practice.load()
                    // Only reaches the network if a refresh URL is set.
                    await store.refresh()
                    // Always cheap, and the point of the whole alert layer.
                    let new = await store.checkAlerts()
                    await ClosingNotifier.notify(new, schoolName: store.defaultSchoolName)
                    ClosingNotifier.scheduleNextCheck()
                    // Planned days off are known months in advance, so hand
                    // them to iOS as dated alarms now. They then fire even if
                    // the app is never opened again, with no network and no
                    // background refresh.
                    await store.rescheduleDayBeforeReminders()
                    // Who works at the saved school, so "who teaches science"
                    // has an answer. Last, because nothing else waits on it
                    // and a staff question asked before it lands says so.
                    await store.refreshStaff()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is the cheapest moment to re-check.
            guard phase == .active else { return }
            Task {
                let new = await store.checkAlerts()
                await ClosingNotifier.notify(new, schoolName: store.defaultSchoolName)
                // Reminders that have already fired leave gaps at the end of
                // the queue; this tops it back up.
                await store.rescheduleDayBeforeReminders()
            }
        }
    }
}
