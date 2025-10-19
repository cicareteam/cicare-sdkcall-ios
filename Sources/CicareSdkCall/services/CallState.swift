//
//  CallState.swift
//  CicareSdkCall
//
//  Created by cicare.team on 28/07/25.
//

import Foundation
import CallKit

final class CallState {
    static let shared = CallState()
    //var currentCallUUID: UUID?
    var callProvider: CXProvider?
}
