import NIOCore

final class ChannelContextExecutor: @unchecked Sendable {
    private let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }

    func execute(_ operation: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        context.eventLoop.execute { [self] in
            guard context.channel.isActive else { return }
            operation(context)
        }
    }
}
