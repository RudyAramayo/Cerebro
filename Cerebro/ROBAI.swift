//
//  ROBAI.swift
//  Cerebro
//
//  Created by Rob Makina on 7/2/25.
//  Copyright © 2025 Rob Makina. All rights reserved.
//

import Foundation
import FoundationModels

@available(macOS 10.15, *)
@objcMembers public class ROBAI: NSObject {
    
    func handleInput(_ text: String, completion: @escaping (String)->Void) {
        Task {
            do {
                if let response = try await processAIQuery(text: text) {
                    completion(response)
                }
                //let errorResponse = "im sorry but my beta model is broken"
                //completion(errorResponse)
            } catch {
                print("Error getting AI response: \(error)")
            }
        }
    }
    
    func processAIQuery(text: String) async throws -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        //let answer = try await session.respond(to: "briefly in 2 sentences tell me, \(text)")
        //let answer = try await session.respond(to: "Your name is ROB and you are a droid, briefly in 2 sentences tell me, \(text)", generating: String.self, includeSchemaInPrompt: true, options: .init(temperature: 1.0))
        let answer = try await session.respond(to: "\(text)", generating: String.self, includeSchemaInPrompt: false/*, options: .init(temperature: 0.5)*/)
        return answer.content.trimmingCharacters(in: .punctuationCharacters)
    }
}
