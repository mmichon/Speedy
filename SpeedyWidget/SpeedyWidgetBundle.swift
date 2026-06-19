//
//  SpeedyWidgetBundle.swift
//  SpeedyWidget
//
//  Created by Michael Michon on 8/19/25.
//

import WidgetKit
import SwiftUI

@main
struct SpeedyWidgetBundle: WidgetBundle {
    init() {
        print("Widget Debug - SpeedyWidgetBundle initialized")
    }

    var body: some Widget {
        // Exactly ONE ActivityConfiguration is registered for SpeedyWidgetAttributes.
        // On iOS 18.4+ / iOS 26 the system automatically forwards this Live Activity
        // to the CarPlay dashboard; keeping a single configuration is what makes that
        // forwarding (and lock screen / Dynamic Island rendering) reliable.
        SpeedyWidgetLiveActivity()

        // Control Widgets are only available in iOS 18.0+
        #if os(iOS) && compiler(>=5.9)
        if #available(iOS 18.0, *) {
            SpeedyWidgetControl()
        }
        #endif
    }
}
