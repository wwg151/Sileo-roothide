//
//  File.swift
//  Sileo
//
//  Created by Amy While on 15/04/2023.
//  Copyright © 2023 Sileo Team. All rights reserved.
//

import Foundation
import MachO

enum Jailbreak: String, Codable {
    
    static let current = Jailbreak()
    static let bootstrap = Bootstrap(jailbreak: current)
    
    // Coolstar
    case electra = "Electra"
    case chimera = "Chimera"
    case odyssey = "Odyssey"
    case taurine = "Taurine"
    
    // unc0ver
    case unc0ver = "unc0ver"
    
    // checkra1n
    case checkra1n = "checkra1n"
    
    // Odysseyra1n
    case odysseyra1n = "Odysseyra1n"
    
    // Palera1n
    case palera1n_rootless = "palera1n Rootless"
    case palera1n_rootful = "palera1n Rootful"
    
    // Xina
    case xina15 = "XinaA15"
    
    // Fugu15
    case fugu15 = "Fugu15"
    
    // Bakera1n
    case bakera1n_rootless = "bakera1n Rootless"
    case bakera1n_rootful = "bakera1n Rootful"
    
    case mac = "macOS"
    case other = "Other"
    case simulator = "Simulator"
    
    #if SILEO_ROOTLESS
    case dopamine = "Dopamine"
    #else
    case dopamine = "Dopamine-roothide"
    #endif
    
    case BOOTSTRAP = "Bootstrap"
    
    case palehide = "Palera1n-roothide"
    
    case relaxin = "Relaxin"
    
    fileprivate static func arch() -> String {
        guard let archRaw = NXGetLocalArchInfo().pointee.name else {
            return "arm64"
        }
        return String(cString: archRaw)
    }
    
    static private let supported: Set<Jailbreak> = [.chimera, .odyssey, .taurine, .odysseyra1n, .palera1n_rootful, .palera1n_rootless, .fugu15, .dopamine, .dopamine, BOOTSTRAP, .relaxin]
    public var supportsUserspaceReboot: Bool {
        Self.supported.contains(self)
    }
    
    private init() {
        #if targetEnvironment(simulator)
        self = .simulator
        return
        #endif
        
        #if targetEnvironment(macCatalyst)
        self = .mac
        return
        #endif
        
        //check palehide first
        let palehide = URL(fileURLWithPath: jbroot("/.installed_palera1n"))
        if palehide.exists {
            self = Bootstrap.roothide ? .palehide : .palera1n_rootless
            return
        }
        
        let dopamine = URL(fileURLWithPath: jbroot("/.installed_dopamine"))
        if dopamine.exists {
            self = .dopamine
            return
        }
        
        let bootstrap = URL(fileURLWithPath: jbroot("/.thebootstrapped"))
        if bootstrap.exists {
            self = .BOOTSTRAP
            return
        }
        
        let relaxin = URL(fileURLWithPath: jbroot("/.installed_relaxin"))
        if relaxin.exists {
            self = .relaxin
            return
        }
        
        self = .other
        
    }

    
}
