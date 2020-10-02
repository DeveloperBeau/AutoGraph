import Foundation
import Starscream
import Alamofire

public typealias WebSocketConnected = (Result<Bool, Error>) -> Void

public protocol WebSocketClientDelegate: class {
    func didReceive(event: WebSocketEvent)
    func didReceive(error: Error)
}

private let kAttemptReconnectCount = 3

open class WebSocketClient {
    public enum State {
        case connected
        case disconnected
    }
    
    public let webSocket: WebSocket
    public weak var delegate: WebSocketClientDelegate?
    public private(set) var state: State = .disconnected
    
    private let subscriptionSerializer = SubscriptionSerializer()
    private var subscribers = [String: SubscriptionResponseHandler]()
    private var subscriptions : [String: String] = [:]
    private var attemptReconnectCount = kAttemptReconnectCount
    private var connectionCompletionBlock: WebSocketConnected?
    
    public init(url: URL) throws {
        let request = try WebSocketClient.connectionRequest(url: url)
        self.webSocket = WebSocket(request: request)
        self.webSocket.delegate = self
    }
    
    deinit {
        self.webSocket.forceDisconnect()
        self.webSocket.delegate = nil
    }
    
    public func authenticate(token: String?, headers: [String: String]?) {
        var headers = headers ?? [:]
        if let token = token {
            headers["Authorization"] = "Bearer \(token)"
        }
        
        headers.forEach { (key, value) in
            self.webSocket.request.setValue(value, forHTTPHeaderField: key)
        }
    }
    
    public func disconnect() {
        guard self.state != .disconnected else {
            return
        }
        
        // TODO: Possible return something to the user if this fails?
        if let payload = try? GraphQLWSProtocol.connectionTerminate.serializedSubscriptionPayload() {
            self.write(payload)
        }
        
        self.webSocket.disconnect()
    }
    
    public func subscribe<R: Request>(request: SubscriptionRequest<R>, responseHandler: SubscriptionResponseHandler) {
        self.connectionCompletionBlock = { (result) in
            switch result {
            case let .success(isConnected):
                if isConnected {
                    self.sendSubscription(request: request, responseHandler: responseHandler)
                }
                else {
                    guard self.attemptReconnectCount > 0 else {
                        responseHandler.didFinish(error: WebSocketError.webSocketNotConnected(request.id))
                        return
                    }
                    
                    self.attemptReconnectCount -= 1
                    self.subscribe(request: request, responseHandler: responseHandler)
                }
            case let .failure(error):
                responseHandler.didFinish(error: error)
            }
        }
        
        guard self.state != .connected else {
            self.connectionCompletionBlock?(.success(true))
            return
        }
        
        self.webSocket.connect()
    }
    
    public func unsubscribe<R: Request>(request: SubscriptionRequest<R>) throws {
        let message = try GraphQLWSProtocol.stop.serializedSubscriptionPayload()
        self.write(message)
        self.subscribers.removeValue(forKey: request.id)
        self.subscriptions.removeValue(forKey: request.id)
    }
    
    func write(_ message: String) {
        self.webSocket.write(string: message, completion: nil)
    }
    
    func sendSubscription<R: Request>(request: SubscriptionRequest<R>, responseHandler: SubscriptionResponseHandler) {
        do {
            let subscriptionMessage = try request.serializedSubscriptionPayload()
            
            guard self.state == .connected else {
                responseHandler.didFinish(error: WebSocketError.webSocketNotConnected(subscriptionMessage))
                return
            }
            
            self.subscribers[request.id] = responseHandler
            self.subscriptions[request.id] = subscriptionMessage
            self.write(subscriptionMessage)
        }
        catch let error {
            responseHandler.didFinish(error: error)
        }
    }
}

// MARK: - Class Method

extension WebSocketClient {
    class func connectionRequest(url: URL) throws -> URLRequest {
        var defaultHeders = [String: String]()
        defaultHeders["Sec-WebSocket-Protocol"] = "graphql-ws"
        defaultHeders["Origin"] = url.absoluteString
        
        return try URLRequest(url: url, method: .get, headers: HTTPHeaders(defaultHeders))
    }
}

// MARK: - WebSocketDelegate
extension WebSocketClient: WebSocketDelegate {
    public func didReceive(event: WebSocketEvent, client: WebSocket) {
        self.delegate?.didReceive(event: event)
        
        do {
            switch event {
            case .disconnected:
                // TODO: this is wrong, we may want to reconnect. and then call connectionCompletionBlock if available.
                self.reset()
            case .binary(let data):
                let subscription = try self.subscriptionSerializer.serialize(data: data)
                self.didReceive(subscription: subscription)
            case let .text(text):
                let subscription = try self.subscriptionSerializer.serialize(text: text)
                self.didReceive(subscription: subscription)
            case .connected:
                try self.connectionInitiated()
                // TOOD: what is this trying to do?
                if self.state == .connected {
                    self.subscriptions.forEach { (_, value) in
                        self.write(value)
                    }
                }
                
                self.state = .connected
                self.sendConnectionCompletionBlock(isSuccessful: true)
            case let .reconnectSuggested(shouldReconnect):
                if shouldReconnect {
                    self.reconnectWebSocket()
                }
            case let .error(error):
                self.sendConnectionCompletionBlock(isSuccessful: false, error: error)
            case .cancelled,
                 .ping,
                 .pong,
                 .viabilityChanged:
                break
            }
        }
        catch let error {
            self.delegate?.didReceive(error: error)
        }
    }
}

// MARK: - Connection Helper Methods

extension WebSocketClient {
    func connectionInitiated() throws {
        let message = try GraphQLWSProtocol.connectionInit.serializedSubscriptionPayload()
        self.write(message)
    }
    
    func reconnectWebSocket() {
        guard self.attemptReconnectCount > 0 else {
            self.disconnect()
            return
        }
        
        self.attemptReconnectCount -= 1
        self.disconnect()
        self.webSocket.connect()
    }
    
    func sendConnectionCompletionBlock(isSuccessful: Bool, error: Error? = nil) {
        guard let completion = self.connectionCompletionBlock else {
            return
        }
        
        if let error = error {
            completion(.failure(error))
        }
        else {
            completion(.success(isSuccessful))
        }
        
        self.connectionCompletionBlock = nil
    }
    
    func reset() {
        self.subscriptions.removeAll()
        self.subscribers.removeAll()
        self.attemptReconnectCount = kAttemptReconnectCount
        self.sendConnectionCompletionBlock(isSuccessful: false)
    }
    
    func didReceive(subscription: SubscriptionResponsePayload) {
        let id = subscription.id
        self.subscribers[id]?.didFinish(subscription: subscription)
    }
}
