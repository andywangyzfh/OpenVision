import Foundation

/// The production binding is shared with joint service tests; SDK and audio effects remain
/// replaceable. Inputs ownership and VM ownership must both survive queued delivery.
@MainActor
final class GlassesVoiceCoordinator {
    typealias ActivationJob = @MainActor @Sendable () async -> Void
    typealias Enqueue = @MainActor (@escaping ActivationJob) -> Void
    private let model: ConversationViewModel
    private let inputs: GlassesInputService

    init(model: ConversationViewModel, inputs: GlassesInputService,
         enqueue: @escaping Enqueue = { job in Task { @MainActor in await job() } }) {
        self.model = model
        self.inputs = inputs
        inputs.canArmSession = { [weak model] in
            guard let model else { return false }
            return model.glasses.canStartIndependentSession && !model.busy && !model.authorizingSpeech
                && !model.conversationActive && model.pendingPhoto == nil
        }
        inputs.onVoiceToggle = { [weak model] permit in
            guard let model else { return }
            let generation = model.voiceActivationGeneration
            enqueue { [weak model] in
                guard let model, permit.isValid else { return }
                await model.handleGlassesVoiceToggle(expectedGeneration: generation,
                                                     ifAllowed: { permit.isValid })
            }
        }
        inputs.onDeactivated = { [weak model] in model?.stop() }
        model.onConfirmedPhotoWillStart = { [weak inputs] in
            guard let inputs, await inputs.disarmAndWait(notify: false) else {
                throw GlassesPhotoService.PhotoFailure.teardown
            }
        }
    }

    func setActive(_ active: Bool, isBackground: Bool = false) {
        inputs.setForeground(active)
        model.setForeground(active, cancelAccountAuthorization: isBackground)
    }
}
