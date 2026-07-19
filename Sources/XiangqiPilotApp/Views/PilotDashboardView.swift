import SwiftUI

private enum DashboardModal: String, Identifiable {
    case correction
    case review
    case recovery

    var id: String { rawValue }
}

struct PilotDashboardView: View {
    @StateObject private var model: PilotPresentationModel
    @State private var activeModal: DashboardModal?

    init(model: PilotPresentationModel = .mock) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            TopCommandBar(model: model)

            HStack(spacing: 0) {
                CockpitSidebar(
                    model: model,
                    openCorrection: { open(.correction) },
                    openReview: { open(.review) },
                    openRecovery: { open(.recovery) }
                )

                VStack(spacing: 10) {
                    BoardWorkspace(
                        model: model,
                        openCorrection: { open(.correction) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    EventTimelineView(events: model.events)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                InspectorPanel(
                    model: model,
                    openRecovery: { open(.recovery) }
                )
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        .background(CockpitPalette.canvas)
        .preferredColorScheme(.dark)
        .sheet(item: $activeModal, onDismiss: resetWorkspace) { modal in
            switch modal {
            case .correction:
                PositionCorrectionSheet(model: model)
            case .review:
                ReviewSheet(model: model)
            case .recovery:
                RecoverySheet(model: model)
            }
        }
    }

    private func open(_ modal: DashboardModal) {
        switch modal {
        case .correction: model.activeWorkspace = .correction
        case .review: model.activeWorkspace = .review
        case .recovery: model.activeWorkspace = .recovery
        }
        activeModal = modal
    }

    private func resetWorkspace() {
        model.activeWorkspace = .cockpit
    }
}

#if DEBUG
struct PilotDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        PilotDashboardView()
            .frame(width: 1380, height: 860)
    }
}
#endif
