//
//  Bootstrap.swift
//  Sileo
//
//  Created by Amy While on 15/04/2023.
//  Copyright © 2023 Sileo Team. All rights reserved.
//

import Foundation

enum Bootstrap: String, Codable {
    
    #if SILEO_ROOTLESS
    static let roothide = false
    #else
    static let roothide = URL(fileURLWithPath: jbroot("/.procursus_strapped")).exists
    #endif
    static let rootless = roothide||URL(fileURLWithPath: "/var/jb/.procursus_strapped").exists
    
    #if SILEO_ROOTLESS
    case procursus = "Procursus"
    #else
    case procursus = "Procursus(roothide)"
    #endif
    case xina = "Procursus/Xina"
    case elucubratus = "Bingner/Elucubratus"
    case electra = "Electra/Chimera"
    case unc0ver = "Unc0verstrap"
    
    init(jailbreak: Jailbreak) {
        switch jailbreak {
        case .electra: self = .electra
        case .chimera:
            if URL(fileURLWithPath: "/.procursus_strapped").exists {
                self = .procursus
            } else {
                self = .electra
            }
        case .unc0ver:
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 11 {
                self = .unc0ver
            } else {
                self = .elucubratus
            }
        case .xina15:
            self = .xina
        default:
            self = .procursus
        }
    }
    
}
