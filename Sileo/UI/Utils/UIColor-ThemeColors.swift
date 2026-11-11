//
//  UIColor-ThemeColors.swift
//  Sileo
//
//  Created by CoolStar on 9/8/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation

extension UIColor {
    static var isTransitionLockedForiOS13Bug: Bool = false // compensate for a bug in stock iOS
    
    static var isDarkModeEnabled: Bool {
        if SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == .dark {
            return true
        } else if SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == .system {
            if #available(iOS 13, *) {
                if UITraitCollection.current.userInterfaceStyle == .dark {
                    return true
                }
            }
        }
        return false
    }
    
    static var sileoBackgroundColor: UIColor {
        if #available(iOS 13, *) {
            return SileoThemeManager.shared.currentTheme.backgroundColor ?? .systemBackground
        }
        return SileoThemeManager.shared.currentTheme.backgroundColor ?? .white
    }
    
    static var sileoContentBackgroundColor: UIColor {
        SileoThemeManager.shared.currentTheme.secondaryBackgroundColor ?? UIColor(white: 245/255, alpha: 1)
    }
        
    static var sileoLabel: UIColor {
        if #available(iOS 13, *) {
            return SileoThemeManager.shared.currentTheme.labelColor ?? .label
        }
        return SileoThemeManager.shared.currentTheme.labelColor ?? .black
    }
    
    static var sileoHighlightColor: UIColor {
        SileoThemeManager.shared.currentTheme.highlightColor ?? UIColor(white: 0.9, alpha: 1)
    }
    
    /// Separators are hidden by default: the lists are told apart by spacing and
    /// their own headers. The switch in Settings brings the hairlines back.
    static var hidesSeparators: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "HideSeparators") != nil else { return true }
        return defaults.bool(forKey: "HideSeparators")
    }

    static var sileoSeparatorColor: UIColor {
        if hidesSeparators {
            return .clear
        }
        return SileoThemeManager.shared.currentTheme.seperatorColor
            ?? UIColor(red: 234.0/255.0, green: 234.0/255.0, blue: 236.0/255.0, alpha: 1)
    }
    
    static var sileoHeaderColor: UIColor {
        SileoThemeManager.shared.currentTheme.headerColor ?? UIColor(red: 0.898, green: 0.98, blue: 1, alpha: 0.5)
    }
        
    static var sileoBannerColor: UIColor {
        SileoThemeManager.shared.currentTheme.bannerColor ?? UIColor(red: 0.941, green: 0.996, blue: 1, alpha: 1)
    }
    
    static var tintColor: UIColor {
        SileoThemeManager.shared.tintColor
    }
}
