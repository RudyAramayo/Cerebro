//
//  ROBAI.swift
//  Cerebro
//
//  Created by Rob Makina on 7/2/25.
//  Copyright © 2025 Rob Makina. All rights reserved.
//

import Foundation
//import FoundationModels

@available(macOS 10.15, *)
@objcMembers public class ROBAI: NSObject {
    
    func handleInput(_ text: String, completion: @escaping (String)->Void) {
        Task {
            do {
                try await processAIQuery(text: text, completion: { response in
                    completion(response)
                })
            } catch {
                print("Error getting AI response: \(error)")
            }
        }
    }
    
    func processAIQuery(text: String, completion: @escaping (String)->Void ) async throws {

        // 1. This is a simple test with the curl command, a python example will allow us to use the live api and keep a conversation going with session ID restore
        //curl "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
        //-H 'Content-Type: application/json'
        //-H 'X-goog-api-key: AIzaSyAAungtfsii7SK-zJBf04389rIqxfICaTA'
        //-X POST
        //-d '{"contents": [{"parts": [{"text": "Explain how AI works in a few words"}]}]}'

        
        // 1. Define the URL
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent") else {
            print("Error: Invalid URL")
            throw NSError(domain: "Error: Invalid URL", code: 0, userInfo: nil)
        }

        // 2. Create a URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST" // Set the HTTP method
        
        // 3. Add headers (if any)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("AIzaSyAAungtfsii7SK-zJBf04389rIqxfICaTA", forHTTPHeaderField: "X-goog-api-key")
        
        request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["parts": [["text": text]]]]] as [String: Any], options: [])
        // 4. Create a URLSession data task
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            // 5. Handle the response
            if let error = error {
                print("Error: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response")
                return
            }

            print("Status Code: \(httpResponse.statusCode)")

            if let data = data {
                // Process the received data (e.g., parse JSON)
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("Response Data: \(jsonString)")
                }
                //                    guard let jsonData = jsonString.data(using: .utf8) else {
                //                        fatalError("Could not convert JSON string to Data.")
                //                    }
                do {
                    let decoder = JSONDecoder()
                    let geminiResponse = try decoder.decode(GeminiResponse.self, from: data) // 'data' is the Data object from the API response
                    if let generatedText = geminiResponse.candidates.first?.content.parts.first?.text {
                        print("Generated Text: \(generatedText)")
                        completion(generatedText)
                    }
                } catch {
                    print("Error decoding Gemini response: \(error)")
                }
            }
            //}
        }
        
        /*
         Response Data: {
           "candidates": [
             {
               "content": {
                 "parts": [
                   {
                     "text": "As a large language model, I don't experience emotions or feelings in the same way humans do. So, I don't \"feel\" in the way you might be asking. \n\nHowever, I am functioning optimally and ready to assist you with your requests. How can I help you today?\n"
                   }
                 ],
                 "role": "model"
               },
               "finishReason": "STOP",
               "avgLogprobs": -0.19546113695417131
             }
           ],
           "usageMetadata": {
             "promptTokenCount": 3,
             "candidatesTokenCount": 63,
             "totalTokenCount": 66,
             "promptTokensDetails": [
               {
                 "modality": "TEXT",
                 "tokenCount": 3
               }
             ],
             "candidatesTokensDetails": [
               {
                 "modality": "TEXT",
                 "tokenCount": 63
               }
             ]
           },
           "modelVersion": "gemini-2.0-flash",
           "responseId": "rwWUaIP_KsWDn9kPnP-c0Qk"
         }
         */
        
        

        // 6. Start the task
        task.resume()
        
        //return "Foundation mdoels is not available"
        
        //-----------------------------
        //Apple FoundationModels framework usage below, framework is missing beta 5 macOS 26.0
//        guard SystemLanguageModel.default.isAvailable else { return nil }
//        let session = LanguageModelSession(model: SystemLanguageModel.default)
//        //let answer = try await session.respond(to: "briefly in 2 sentences tell me, \(text)")
//        //let answer = try await session.respond(to: "Your name is ROB and you are a droid, briefly in 2 sentences tell me, \(text)", generating: String.self, includeSchemaInPrompt: true, options: .init(temperature: 1.0))
//        let answer = try await session.respond(to: "\(text)", generating: String.self, includeSchemaInPrompt: false/*, options: .init(temperature: 0.5)*/)
//        return answer.content.trimmingCharacters(in: .punctuationCharacters)
    }
}

struct GeminiResponse: Decodable {
    let candidates: [Candidate]
}

struct Candidate: Decodable {
    let content: Content
}

struct Content: Decodable {
    let parts: [Part]
}

struct Part: Decodable {
    let text: String
}


//
//struct GeminiResponse: Codable {
//    let candidates: [Candidate]
//    let usageMetadata: UsageMetadata
//    let modelVersion: String
//    let responseId: String
//}
//
//struct Candidate: Codable {
//    let content: Content
//    let finishReason: String
//    let avgLogprobs: Double
//}
//
//struct Content: Codable {
//    let parts: [Part]
//    let role: String
//}
//
//struct Part: Codable {
//    let text: String
//}
//
//struct UsageMetadata: Codable {
//    let promptTokenCount: Int
//    let candidatesTokenCount: Int
//    let totalTokenCount: Int
//    let promptTokensDetails: [TokenDetail]
//    let candidateTokensDetails: [TokenDetail]
//}
//
//struct TokenDetail: Codable {
//    let modality: String
//    let tokenCount: Int
//}
