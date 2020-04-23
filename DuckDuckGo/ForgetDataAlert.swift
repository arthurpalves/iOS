//
//  ForgetDataAlert.swift
//  DuckDuckGo
//
//  Copyright © 2019 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import UIKit

class ForgetDataAlert {
    
    static func buildAlert(cancelHandler: (() -> Void)? = nil, forgetTabsAndDataHandler: @escaping () -> Void) -> UIAlertController {
        
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.overrideUserInterfaceStyle()

        alert.addAction(title: "Close Tabs and Clear Data", style: .destructive) {
            forgetTabsAndDataHandler()
        }

        let cancelAction = UIAlertAction(title: UserText.actionCancel, style: .cancel) { _ in
            cancelHandler?()
        }

        alert.addAction(cancelAction)
        return alert
    }
    
}
