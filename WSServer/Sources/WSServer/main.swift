//
//  main.swift
//  Server
//
//  Created by zen on 2/23/19.
//  Copyright © 2019 AppSpector. All rights reserved.
//

import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

class WebSocketHandler : ChannelInboundHandler {
    
    typealias InboundIn   = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    
    private var awaitingClose: Bool = false
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        
        switch frame.opcode {
        case .connectionClose:
            self.receivedClose(ctx: ctx, frame: frame)
        case .ping:
            self.pong(ctx: ctx, frame: frame)
        case .text:
            var data = frame.unmaskedData
            let payload = data.readString(length: data.readableBytes) ?? ""
            handlePayload(ctx: ctx, payload: payload)
        default:
            return
        }
    }
    
    func handlePayload(ctx: ChannelHandlerContext, payload: String) {
        var buffer = ctx.channel.allocator.buffer(capacity: payload.utf8.count)
        buffer.write(string: payload)
        
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        
        _ = ctx.channel.writeAndFlush(frame)
    }
    
    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }
    
    func channelActive(ctx: ChannelHandlerContext) {
        print("Channel ready, client address:", ctx.channel.remoteAddress?.description ?? "-")
    }
    
    func channelInactive(ctx: ChannelHandlerContext) {
        print("Channel closed.", ObjectIdentifier(self))
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        print("ERROR:", error)
        ctx.close(promise: nil)
    }
    
    private func pong(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        let maskingKey = frame.maskKey
        
        if let maskingKey = maskingKey {
            frameData.webSocketUnmask(maskingKey)
        }
        
        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        ctx.write(self.wrapOutboundOut(responseFrame), promise: nil)
    }
    
    private func receivedClose(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            ctx.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? ctx.channel.allocator.buffer(capacity: 0)
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
            _ = ctx.write(self.wrapOutboundOut(closeFrame)).map { () in
                ctx.close(promise: nil)
            }
        }
    }
}

final class Server {
    
    struct Configuration {
        var host           : String?         = nil
        var port           : Int             = 8080
        var backlog        : Int             = 256
        var eventLoopGroup : EventLoopGroup? = nil
    }
    
    let configuration  : Configuration
    let eventLoopGroup : EventLoopGroup
    var serverChannel  : Channel?
    
    init(configuration: Configuration = Configuration()) {
        self.configuration  = configuration
        self.eventLoopGroup = configuration.eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    
    func listenAndWait() {
        listen()
        
        do {
            try serverChannel?.closeFuture.wait()
        }
        catch {
            print("ERROR: Failed to wait on server:", error)
        }
    }
    
    func listen() {
        
        let bootstrap = makeBootstrap()
        
        do {
            let address : SocketAddress
            
            if let host = configuration.host {
                address = try SocketAddress.newAddressResolving(host: host, port: configuration.port)
            } else {
                var addr = sockaddr_in()
                addr.sin_port = in_port_t(configuration.port).bigEndian
                address = SocketAddress(addr, host: "*")
            }
            
            serverChannel = try bootstrap.bind(to: address).wait()
            
            if let addr = serverChannel?.localAddress {
                print("Server running on:", addr)
            }
            else {
                print("ERROR: server reported no local address?")
            }
        }
        catch let error as NIO.IOError {
            print("ERROR: failed to start server, errno:", error.errnoCode, "\n", error.localizedDescription)
        }
        catch {
            print("ERROR: failed to start server:", type(of:error), error)
        }
    }
    
    func shouldUpgrade(head: HTTPRequestHead) -> HTTPHeaders? {
        if (head.uri.starts(with: "/echo")) {
            return HTTPHeaders()
        }
        
        return nil
    }
    
    func upgradePipelineHandler(channel: Channel, head: HTTPRequestHead) -> NIO.EventLoopFuture<Void> {
        if (head.uri.starts(with: "/echo")) {
            return channel.pipeline.add(handler: WebSocketHandler())
        }
        
        return channel.closeFuture
    }
    
    func makeBootstrap() -> ServerBootstrap {
        let reuseAddrOpt = ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR)
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
            .serverChannelOption(reuseAddrOpt, value: 1)
            .childChannelInitializer { channel in
                let connectionUpgrader = WebSocketUpgrader(shouldUpgrade: self.shouldUpgrade, upgradePipelineHandler: self.upgradePipelineHandler)
                
                let config: HTTPUpgradeConfiguration = (
                    upgraders: [ connectionUpgrader ],
                    completionHandler: { _ in }
                )
                
                return channel.pipeline.configureHTTPServerPipeline(first: true, withPipeliningAssistance: true, withServerUpgrade: config, withErrorHandling: true)
                
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(reuseAddrOpt, value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        
        return bootstrap
    }
}


// MARK: - Start and run Server

let server = Server()
server.listenAndWait()
