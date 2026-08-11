//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// A ``NIOSSHClientUserAuthenticationDelegate`` is an object that can provide a sequence of
/// SSH user authentication methods based on the the acceptable list from the server.
///
/// This protocol defines the interface that will be used by the user authentication state
/// machine to move forward with challenges. Implementers of this protocol are free to take
/// time to actually get responses: for example, for password authentication it is possible
/// that the application would like to provide a user-interactive password prompt. This is
/// enabled by allowing implementers to satisfy a promise, rather than requiring that they
/// synchronously provide a response.
public protocol NIOSSHClientUserAuthenticationDelegate {
    /// Called when ``NIOSSH`` would like to attempt to offer a new authentication method.
    ///
    /// The callback is provided the authentictation methods that the server is willing to accept in
    /// `availableMethods`. The delegate needs to provide an authentication offer by completing
    /// `nextChallengePromise`. If no further authentication offers are available (perhaps because the server
    /// has rejected them all) then this promise should be failed, which will terminate connection establishment.
    ///
    /// - parameters:
    ///     - availableMethods: The authentication methods the server is willing to accept.
    ///     - nextChallengePromise: An `EventLoopPromise` to be fulfilled with the next authentication offer.
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>)

    /// [Berth patch] RFC 4256 keyboard-interactive:服务器发来一轮质询(INFO_REQUEST)。
    /// 以 `challenge.prompts` 同数量、同顺序的应答完成 `responsePromise`;失败该 promise
    /// 会中止连接。仅在 delegate 提交过 `.keyboardInteractive` offer 后才会被调用。
    /// 默认实现直接失败(现有 delegate 不受影响)。
    func keyboardInteractiveChallenge(_ challenge: NIOSSHKeyboardInteractiveChallenge, responsePromise: EventLoopPromise<[String]>)
}

// [Berth patch] 默认实现:没实现质询回调的 delegate 不该提交 keyboardInteractive offer
public extension NIOSSHClientUserAuthenticationDelegate {
    func keyboardInteractiveChallenge(_ challenge: NIOSSHKeyboardInteractiveChallenge, responsePromise: EventLoopPromise<[String]>) {
        responsePromise.fail(NIOSSHError.protocolViolation(
            protocolName: "userauth",
            violation: "delegate offered keyboard-interactive but does not implement keyboardInteractiveChallenge"
        ))
    }
}
