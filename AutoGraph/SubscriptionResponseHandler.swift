import Foundation

public struct SubscriptionResponseHandler {
    public typealias WebSocketCompletionBlock = (Result<Data, Error>) -> Void
    
    private let completion: WebSocketCompletionBlock
    
    public init(completion: @escaping WebSocketCompletionBlock) {
        self.completion = completion
    }
    
    public func didReceive(subscriptionResponse: SubscriptionResponse) {
        if let error = subscriptionResponse.error {
            didReceive(error: error)
        }
        else if let data = subscriptionResponse.payload {
            self.completion(.success(data))
        }
    }
    
    public func didReceive(error: Error) {
        self.completion(.failure(error))
    }
}
