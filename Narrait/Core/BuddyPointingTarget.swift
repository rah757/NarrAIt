//
//  BuddyPointingTarget.swift
//  Narrait
//
//  Shared model published by ActivationCoordinator and consumed by BuddyCursorView.
//  When the AI returns a [POINT:] coordinate, the Coordinator sets this value;
//  BuddyCursorView observes it and animates the buddy to that screen location.
//

import CoreGraphics
import Foundation

/// Describes a screen element the buddy should fly to and point at.
struct BuddyPointingTarget {
    /// AppKit global coordinate (origin bottom-left) of the target element.
    let screenLocation: CGPoint
    /// Optional short label shown in the buddy's speech bubble on arrival.
    let label: String?
}
