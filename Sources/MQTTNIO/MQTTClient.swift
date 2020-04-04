import NIO
import NIOConcurrencyHelpers
import Logging

public class MQTTClient {
    
    // MARK: - Vars
    
    private var _configuration: MQTTConfiguration
    var configuration: MQTTConfiguration {
        get {
            return lock.withLock { _configuration }
        }
        set {
            lock.withLockVoid {
                _configuration = newValue
                requestHandler.eventLoop = newValue.eventLoopGroup.next()
            }
        }
    }
    
    let logger: Logger
    
    private let lock = Lock()
    private var connection: MQTTConnection?
    
    private let requestHandler: MQTTRequestHandler
    private let subscriptionsHandler: MQTTSubscriptionsHandler
    
    // MARK: - Init
    
    public init(
        configuration: MQTTConfiguration,
        logger: Logger = .init(label: "nl.roebert.MQTTNio"))
    {
        _configuration = configuration
        self.logger = logger
        
        requestHandler = MQTTRequestHandler(logger: logger, eventLoop: _configuration.eventLoopGroup.next())
        subscriptionsHandler = MQTTSubscriptionsHandler(logger: logger)
    }
    
    // MARK: - Connect
    
    public func connect() -> EventLoopFuture<Void> {
        return lock.withLock {
            guard connection == nil else {
                return _configuration.eventLoopGroup.next().makeSucceededFuture(())
            }
            
            let connection = MQTTConnection(
                configuration: _configuration,
                requestHandler: requestHandler,
                subscriptionsHandler: subscriptionsHandler,
                logger: logger
            )
            self.connection = connection
            
            return connection.channel.map { _ in () }
        }
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        return lock.withLock {
            guard let connection = connection else {
                return _configuration.eventLoopGroup.next().makeSucceededFuture(())
            }
            
            self.connection = nil
            return connection.close()
        }
    }
    
    // MARK: - Publish
    
    @discardableResult
    public func publish(_ message: MQTTMessage) -> EventLoopFuture<Void> {
        let retryInterval = configuration.publishRetryInterval
        let request = MQTTPublishRequest(message: message, retryInterval: retryInterval)
        return requestHandler.perform(request)
    }
    
    @discardableResult
    public func publish(
        topic: String,
        payload: ByteBuffer? = nil,
        qos: MQTTQoS = .atMostOnce,
        retain: Bool = false
    ) -> EventLoopFuture<Void> {
        let message = MQTTMessage(
            topic: topic,
            payload: payload,
            qos: qos,
            retain: retain
        )
        return publish(message)
    }
    
    @discardableResult
    public func publish(
        topic: String,
        payload: String,
        qos: MQTTQoS = .atMostOnce,
        retain: Bool = false
    ) -> EventLoopFuture<Void> {
        let message = MQTTMessage(
            topic: topic,
            payload: payload,
            qos: qos,
            retain: retain
        )
        return publish(message)
    }
    
    // MARK: - Subscriptions
    
    @discardableResult
    public func subscribe(to subscriptions: [MQTTSubscription]) -> EventLoopFuture<[MQTTSubscriptionResult]> {
        let timeoutInterval = configuration.subscriptionTimeoutInterval
        let request = MQTTSubscribeRequest(subscriptions: subscriptions, timeoutInterval: timeoutInterval)
        return requestHandler.perform(request).map { request.results }
    }
    
    @discardableResult
    public func subscribe(to topic: String, qos: MQTTQoS = .atMostOnce) -> EventLoopFuture<MQTTSubscriptionResult> {
        return subscribe(to: [.init(topic: topic, qos: qos)]).map { $0[0] }
    }
    
    @discardableResult
    public func subscribe(to topics: [String]) -> EventLoopFuture<MQTTSubscriptionResult> {
        return subscribe(to: topics.map { .init(topic: $0) }).map { $0[0] }
    }
    
    @discardableResult
    func unsubscribe(from topics: [String]) -> EventLoopFuture<Void> {
        let timeoutInterval = configuration.subscriptionTimeoutInterval
        let request = MQTTUnsubscribeRequest(topics: topics, timeoutInterval: timeoutInterval)
        return requestHandler.perform(request)
    }
    
    @discardableResult
    public func unsubscribe(from topic: String) -> EventLoopFuture<Void> {
        return unsubscribe(from: [topic])
    }
    
    // MARK: - Listeners
    
    @discardableResult
    public func addMessageListener(_ listener: @escaping MQTTMessageListener) -> MQTTMessageListenContext {
        let context = MQTTMessageListenContext()
        let entry = MQTTSubscriptionsHandler.ListenerEntry(
            context: context,
            listener: listener
        )
        
        context.stopper = { [weak self] in
            self?.subscriptionsHandler.removeListener(entry)
        }
        
        subscriptionsHandler.addListener(entry)
        return context
    }
}
