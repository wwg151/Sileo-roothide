//
//  NativePackageViewController.swift
//  Sileo
//
//  Created by Andromeda on 31/08/2021.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import UIKit

protocol PackageActions: UIViewController {
    @available (iOS 13.0, *)
    func actions() -> [UIAction]
    func cardActions() -> [SileoActionMenuItem]
}

class NativePackageViewController {
    public class func viewController(for package: Package) -> PackageActions {
        let packageVC = PackageViewController(nibName: "PackageViewController", bundle: nil)
        packageVC.package = package
        return packageVC
    }
}
