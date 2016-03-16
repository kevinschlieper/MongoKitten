//
//  NewDatabase.swift
//  MongoSwift
//
//  Created by Joannis Orlandos on 24/01/16.
//  Copyright © 2016 PlanTeam. All rights reserved.
//

import Foundation
import BSON
import BlueSocket

//////////////////////////////////////////////////////////////////////////////////////////////////////////
// This file contains the low level code. This code is synchronous and is used by the async client API. //
//////////////////////////////////////////////////////////////////////////////////////////////////////////


/// A ResponseHandler is a closure that receives a MongoReply to process it
/// It's internal because ReplyMessages are an internal struct that is used for direct communication with MongoDB only
internal typealias ResponseHandler = ((reply: ReplyMessage) -> Void)

/// A server object is the core of MongoKitten. From this you can get databases which can provide you with collections from where you can do actions
public class Server {
    /// Is the socket connected?
    public var connected: Bool { return socket.connected }
    
    /// The MongoDB-server's hostname
    private let host: String
    
    /// The MongoDB-server's port
    private let port: Int32
    
    /// The last Request we sent.. -1 if no request was sent
    internal var lastRequestID: Int32 = -1
    
    /// The full buffer of received bytes from MongoDB
    internal var fullBuffer = [UInt8]()
    
    
    private var incomingResponses = [(id: Int32, message: ReplyMessage, date: NSDate)]()
    private var responseHandlers = [Int32:ResponseHandler]()
    private var waitingForResponses = [Int32:NSCondition]()
    
    private var socket: BlueSocket
    private let backgroundQueue = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0)
    
    /// Initializes a server with a given host and port. Optionally automatically connects
    /// - parameter host: The host we'll connect with for the MongoDB Server
    /// - parameter port: The port we'll connect on with the MongoDB Server
    /// - parameter autoConnect: Whether we automatically connect
    public init(host: String, port: Int32 = 27017, autoConnect: Bool = false) throws {
        self.host = host
        self.port = port
        self.socket = try .defaultConfigured()
        
        if autoConnect {
            try self.connect()
        }
    }
    
    /// This subscript returns a Database struct given a String
    public subscript (database: String) -> Database {
        let database = database.stringByReplacingOccurrencesOfString(".", withString: "")
        
        return Database(server: self, databaseName: database)
    }
    
    /// Generates a messageID for the next Message
    internal func getNextMessageID() -> Int32 {
        lastRequestID += 1
        return lastRequestID
    }
    
    /// Connects with the MongoDB Server using the given information in the initializer
    public func connect() throws {
        if self.connected {
            throw MongoError.MongoDatabaseAlreadyConnected
        }
        
        try self.socket.connectTo(self.host, port: self.port)
        dispatch_async(backgroundQueue, backgroundLoop)
    }
    
    private func backgroundLoop() {
        guard self.connected else { return }
        
        do {
            try self.receive()
            
            // Handle callbacks, locks etc on the responses
            for response in incomingResponses {
                waitingForResponses[response.id]?.broadcast()
                responseHandlers[response.id]?(reply: response.message)
            }
        } catch {
            // A receive failure is to be expected if the socket has been closed
            if self.connected {
                print("The MongoDB background loop encountered an error: \(error)")
            } else {
                return
            }
        }
        
        dispatch_async(backgroundQueue, backgroundLoop)
    }
    
    /// Throws an error if the database is not connected yet
    private func assertConnected() throws {
        guard connected else {
            throw MongoError.MongoDatabaseNotYetConnected
        }
    }
    
    /// Disconnects from the MongoDB server
    public func disconnect() throws {
        try assertConnected()
        socket.close()
    }
    
    /// Called by the server thread to handle MongoDB Wire messages
    private func receive(bufferSize: Int32 = 1024) throws {
        do {
            var incomingBuffer = [UInt8](count: Int(bufferSize), repeatedValue: 0)
            var incomingCount = 0
            try incomingBuffer.withUnsafeMutableBufferPointer {
                incomingCount = try socket.readData(UnsafeMutablePointer($0.baseAddress), bufSize: $0.count)
            }
            fullBuffer += incomingBuffer[0..<incomingCount]
        } catch let error as BlueSocketError {
            if error.errorCode == Int32(BlueSocket.SOCKET_ERR_RECV_BUFFER_TOO_SMALL) {
                try self.receive(error.bufferSizeNeeded)
            } else {
                throw error
            }
        }
        
        do {
            while fullBuffer.count >= 36 {
                guard let length: Int = Int(try Int32.instantiate(bsonData: fullBuffer[0...3]*)) else {
                    throw DeserializationError.ParseError
                }
                
                guard length <= fullBuffer.count else {
                    // Ignore: Wait for more data
                    return
                }
                
                let responseData = fullBuffer[0..<length]*
                let responseId = try Int32.instantiate(bsonData: fullBuffer[8...11]*)
                let response = try ReplyMessage.init(data: responseData)
                
                incomingResponses.append((responseId, response, NSDate()))
                
                fullBuffer.removeRange(0..<length)
            }
        }
    }
    
    internal func awaitResponse(requestId: Int32, timeout: NSTimeInterval = 10) throws -> ReplyMessage {
        let condition = NSCondition()
        condition.lock()
        waitingForResponses[requestId] = condition
        
        if condition.waitUntilDate(NSDate(timeIntervalSinceNow: timeout)) == false {
            throw MongoError.Timeout
        }
        
        condition.unlock()
        
        for (index, response) in incomingResponses.enumerate() {
            if response.id == requestId {
                return incomingResponses.removeAtIndex(index).message
            }
        }
        
        // If we get here, something is very, very wrong.
        throw MongoError.InternalInconsistency
    }
    
    /**
     Send given message to the server.
     
     This method executes on the thread of the caller and returns when done.
     
     - parameter message: A message to send to  the server
     
     - returns: The request ID of the sent message
     */
    internal func sendMessage(message: Message) throws -> Int32 {
        try assertConnected()
        
        let messageData = try message.generateBsonMessage()
        
        try socket.writeData(messageData, bufSize: messageData.count)
        
        return message.requestID
    }
}