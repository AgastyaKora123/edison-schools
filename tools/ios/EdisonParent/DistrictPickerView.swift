//
//  DistrictPickerView.swift
//  EdisonParent
//
//  Choose a district. The app then reads that district's own published
//  calendar and answers from it.
//
//  Reading a calendar takes a few seconds and a hundred-school district takes
//  longer, so the wait says what it is doing rather than spinning. A parent
//  who can see "Reading the calendar (18 of 73)" waits; a parent looking at a
//  bare spinner decides the app is broken.
//

import SwiftUI

struct DistrictPickerView: View {

    @EnvironmentObject var store: KnowledgeStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var failure: String?

    private var results: [DistrictRef] {
        DistrictDirectory.search(query)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isBuildingDistrict {
                    building
                } else {
                    list
                }
            }
            .navigationTitle("Your district")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(store.isBuildingDistrict)
                }
            }
        }
    }

    // MARK: - Waiting

    private var building: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(store.buildStep ?? "Working")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Reading the district's published calendar. This happens once.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The list

    private var list: some View {
        List {
            if DistrictDirectory.all.isEmpty {
                Section {
                    Text("The list of districts is missing from this build of the app.")
                        .foregroundStyle(.secondary)
                }
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if !store.chosenDistrictName.isEmpty {
                Section("Currently") {
                    Text(store.chosenDistrictName)
                    Button("Go back to the district the app came with", role: .destructive) {
                        store.clearDistrict()
                        dismiss()
                    }
                }
            }

            if query.isEmpty {
                Section {
                    Text("Type the name of your district. There are \(DistrictDirectory.all.count) of them.")
                        .foregroundStyle(.secondary)
                }
            } else if results.isEmpty {
                Section {
                    Text("Nothing matching \"\(query)\".")
                        .foregroundStyle(.secondary)
                    Text("Only districts whose website runs on the same system as Edison's are listed. If yours is not here, the app cannot read its calendar.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Section {
                    ForEach(results) { d in
                        Button {
                            choose(d)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.display)
                                    .foregroundStyle(.primary)
                                if d.schoolCount > 0 {
                                    Text("\(d.schoolCount) schools")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "District name")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    private func choose(_ d: DistrictRef) {
        failure = nil
        Task {
            if let problem = await store.useDistrict(d) {
                failure = problem
            } else {
                dismiss()
            }
        }
    }
}
