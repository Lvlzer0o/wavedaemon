//
//  ContentView.swift
//  WaveDaemon
//
//  Created by Trenton Cadena on 3/4/26.
//

import SwiftUI

struct ContentView: View {

    static let greetingText = "Hello, world!"

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("globeIcon")

            Text(Self.greetingText)
                .accessibilityIdentifier("greetingText")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

#if DEBUG
import XCTest

final class ContentViewTests: XCTestCase {

    func testGreetingTextValue() {
        XCTAssertEqual(ContentView.greetingText, "Hello, world!")
    }

}
#endif
