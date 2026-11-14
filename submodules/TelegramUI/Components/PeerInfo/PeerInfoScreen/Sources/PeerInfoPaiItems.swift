import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import TelegramCore
import SwiftSignalKit
import PaiUI

/// A row's icon the way Telegram's settings draw theirs: a white SF Symbol on a coloured rounded square.
private func paiRowIcon(_ symbol: String, _ color: UIColor) -> UIImage? {
    let size = CGSize(width: 30.0, height: 30.0)
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        color.setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7.0).fill()
        guard let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold))?.withTintColor(.white, renderingMode: .alwaysOriginal) else {
            return
        }
        glyph.draw(in: CGRect(x: (size.width - glyph.size.width) / 2.0, y: (size.height - glyph.size.height) / 2.0, width: glyph.size.width, height: glyph.size.height))
    }
}

/// One of pai's agents' profile (its peer is only an identity: portrait, name, role): what it is and does, its Keep
/// page, the agents under it, and lists of its tasks and routines; pai's own also lists what the sessions are given,
/// the calls and the settings. The header's Call is a voice call with the agent (`requestCall`).
func paiAgentInfoItems(peerId: EnginePeer.Id, context: AccountContext, presentationData: PresentationData, interaction: PeerInfoInteraction) -> [(AnyHashable, [PeerInfoScreenItem])] {
    guard let slug = PaiAgentList.slug(peerId: peerId), let agent = PaiChat.agent(slug) else {
        return []
    }
    let push: (PaiProfile.List) -> Void = { list in
        if let controller = PaiProfile.controller(context: context, list: list) {
            interaction.getController()?.push(controller)
        }
    }
    let requestLayout: (Bool) -> Void = { animated in
        interaction.requestLayout(animated)
    }

    var about: [PeerInfoScreenItem] = []
    let role = agent.role.flatMap { $0.isEmpty ? nil : $0 } ?? (agent.isPai ? "assistant" : "agent")
    about.append(PeerInfoScreenLabeledValueItem(id: 0, label: "role", text: role, action: nil, requestLayout: requestLayout))
    about.append(PeerInfoScreenLabeledValueItem(id: 1, label: "status", text: PaiAgentList.state(agent) ?? "idle", action: nil, requestLayout: requestLayout))
    if !agent.job.isEmpty {
        about.append(PeerInfoScreenLabeledValueItem(id: 2, label: "job", text: agent.job, textBehavior: .multiLine(maxLines: 6, enabledEntities: []), action: nil, requestLayout: requestLayout))
    }
    if let url = PaiProfile.keepURL(agent) {
        let title = agent.taskTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Open in Keep"
        about.append(PeerInfoScreenLabeledValueItem(id: 3, label: "Keep page", text: title, textColor: .accent, action: { _, _ in
            guard let controller = interaction.getController() else {
                return
            }
            context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: controller.navigationController as? NavigationController, dismissInput: {})
        }, requestLayout: requestLayout))
    }

    var result: [(AnyHashable, [PeerInfoScreenItem])] = [("pai.about", about)]

    let children = PaiChat.children(of: slug)
    if !children.isEmpty {
        var team: [PeerInfoScreenItem] = [PeerInfoScreenHeaderItem(id: "header", text: agent.isPai ? "AGENTS" : "AGENTS UNDER \(agent.name.uppercased())")]
        for child in children {
            team.append(PeerInfoScreenDisclosureItem(id: "agent:\(child.slug)", label: .text(PaiAgentList.state(child) ?? child.role ?? ""), text: child.name, icon: PaiAgentList.portrait(agent: child, size: 30.0), action: {
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: PaiAgentList.peerId(slug: child.slug)))
                |> deliverOnMainQueue).startStandalone(next: { peer in
                    guard let peer, let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else {
                        return
                    }
                    interaction.getController()?.push(controller)
                })
            }))
        }
        result.append(("pai.team", team))
    }

    let owner: String? = agent.isPai ? nil : slug
    let openTasks = agent.openTasks ?? 0
    let tasksLabel: PeerInfoScreenDisclosureItem.Label = openTasks > 0 ? .text("\(openTasks)") : .none
    var work: [PeerInfoScreenItem] = [
        PeerInfoScreenDisclosureItem(id: "tasks", label: tasksLabel, text: "Tasks", icon: paiRowIcon("checklist", .systemBlue), action: {
            push(.tasks(owner: owner))
        }),
        PeerInfoScreenDisclosureItem(id: "routines", text: "Routines", icon: paiRowIcon("clock.arrow.circlepath", .systemOrange), action: {
            push(.routines(agent: owner))
        }),
    ]
    if agent.isPai {
        work.append(PeerInfoScreenDisclosureItem(id: "calls", text: "Calls", icon: paiRowIcon("phone.fill", .systemGreen), action: {
            push(.calls)
        }))
    }
    result.append(("pai.work", work))

    if agent.isPai {
        let colors: [String: UIColor] = ["tool": .systemBlue, "skill": .systemPurple, "instruction": .systemOrange, "memory": .systemPink]
        var given: [PeerInfoScreenItem] = [PeerInfoScreenHeaderItem(id: "header", text: "WHAT THE SESSIONS ARE GIVEN")]
        for kind in PaiProfile.contextKinds {
            given.append(PeerInfoScreenDisclosureItem(id: "context:\(kind.kind)", text: kind.title, icon: paiRowIcon(kind.symbol, colors[kind.kind] ?? .systemGray), action: {
                push(.context(kind: kind.kind, title: kind.title))
            }))
        }
        result.append(("pai.given", given))
        result.append(("pai.settings", [PeerInfoScreenDisclosureItem(id: "settings", text: "Settings", icon: paiRowIcon("gearshape.fill", .systemGray), action: {
            push(.settings)
        })]))
    }
    return result
}
