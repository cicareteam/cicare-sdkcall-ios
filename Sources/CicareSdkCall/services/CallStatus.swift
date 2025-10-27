//
//  CallStatus.swift
//  CicareSdkCall
//
//  Created by cicare.team on 28/07/25.
//

import Foundation

public enum CallStatus: String {
    case incoming
    case ringing_ok
    case missed
    case answering
    case accepted
    case connected
    case connecting
    case ringing
    case calling
    case ongoing
    case ended
    case refused
    case busy
    case cancel
    case call_error
    case timeout
}

extension Notification.Name {
    static let callStatusChanged = Notification.Name("callStatusChanged")
    static let callProfileSet = Notification.Name("callProfileSet")
    static let callNetworkChanged = Notification.Name("callNetworkChanged")
}

public protocol CallEventListener: AnyObject {
    func onCallStateChanged(_ status: CallStatus)
}
