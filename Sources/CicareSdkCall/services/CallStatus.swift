//
//  CallStatus.swift
//  CicareSdkCall
//
//  Created by cicare.team on 28/07/25.
//

import Foundation

enum CallStatus: String {
    case incoming
    case answering
    case connected
    case connecting
    case ringing
    case calling
    case ongoing
    case ended
    case refused
    case busy
    case cancel
}

extension Notification.Name {
    static let callStatusChanged = Notification.Name("callStatusChanged")
    static let callProfileSet = Notification.Name("callProfileSet")
    static let callNetworkChanged = Notification.Name("callNetworkChanged")
}
