import Foundation
import NIO

/// HTTP CONNECT 隧道：连上 HTTP 代理后发送 CONNECT 打洞，
/// 代理返回 200 后移除自身，把通道留给后续的 SSH 握手。
final class HTTPConnectTunnelHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let targetHost: String
    private let targetPort: Int
    private let readyPromise: EventLoopPromise<Void>
    private var response = ByteBuffer()
    private var finished = false
    private static let headerTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n

    init(targetHost: String, targetPort: Int, readyPromise: EventLoopPromise<Void>) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.readyPromise = readyPromise
    }

    private func sendConnect(_ context: ChannelHandlerContext) {
        var request = ByteBuffer(string: """
        CONNECT \(targetHost):\(targetPort) HTTP/1.1\r
        Host: \(targetHost):\(targetPort)\r
        Proxy-Connection: keep-alive\r
        \r

        """)
        context.writeAndFlush(wrapOutboundOut(request), promise: nil)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            sendConnect(context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendConnect(context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else {
            context.fireChannelRead(data)
            return
        }
        var chunk = unwrapInboundIn(data)
        response.writeBuffer(&chunk)

        let bytes = Array(response.readableBytesView)
        guard let terminatorIndex = Self.findTerminator(in: bytes) else { return }
        finished = true

        let header = String(decoding: bytes[0..<terminatorIndex], as: UTF8.self)
        guard header.contains(" 200 ") || header.hasPrefix("HTTP/1.0 200") || header.hasPrefix("HTTP/1.1 200") else {
            context.close(promise: nil)
            readyPromise.fail(SSHSetupError.proxyTunnelFailed(
                proxy: "\(targetHost):\(targetPort)",
                detail: String(header.prefix(200))
            ))
            return
        }

        // 隧道建立。SSH 客户端会先发言，头部之后的残余字节理论上不存在，但稳妥起见透传。
        let restStart = terminatorIndex + Self.headerTerminator.count
        if restStart < bytes.count {
            var leftover = ByteBuffer(bytes: bytes[restStart...])
            context.fireChannelRead(wrapInboundOut(leftover))
            leftover.clear()
        }

        context.pipeline.removeHandler(self, promise: nil)
        readyPromise.succeed(())
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !finished {
            readyPromise.fail(SSHSetupError.proxyTunnelFailed(
                proxy: "\(targetHost):\(targetPort)",
                detail: error.localizedDescription
            ))
        }
        context.close(promise: nil)
    }

    private static func findTerminator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= headerTerminator.count else { return nil }
        for index in 0...(bytes.count - headerTerminator.count) {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
               bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index
            }
        }
        return nil
    }
}
