/*
 * ExecuTorch LLM Flutter Channel Handler
 * Bridges Flutter with ExecuTorch for on-device LLM inference on iOS
 */

import Foundation
import Flutter

// ExecuTorchLLM must be added via Swift Package Manager
// Repository: https://github.com/pytorch/executorch
// Branch: swiftpm-1.1.0
import ExecuTorchLLM

/// Manages ExecuTorch LLM runners for Flutter platform channel communication
class ExecuTorchLLMChannel: NSObject {
    static let shared = ExecuTorchLLMChannel()
    
    private let channelName = "com.example.anchor/llm"
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    // Runners
    private var textRunner: TextRunner?
    private var multimodalRunner: MultimodalRunner?
    
    // State
    private var isGenerating = false
    private var shouldStop = false
    private let runnerQueue = DispatchQueue(label: "com.example.anchor.llm.runner", qos: .userInitiated)
    
    // Current model info
    private var currentModelPath: String?
    private var currentTokenizerPath: String?
    
    private override init() {
        super.init()
    }
    
    /// Register the channel with the Flutter engine
    func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        
        // Method channel for request/response
        methodChannel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        methodChannel?.setMethodCallHandler(handleMethodCall)
        
        // Event channel for streaming tokens
        eventChannel = FlutterEventChannel(name: "\(channelName)/stream", binaryMessenger: messenger)
        eventChannel?.setStreamHandler(self)
        
        debugPrint("[ExecuTorchLLM] Channel registered")
    }
    
    /// Register directly with binary messenger (for AppDelegate usage)
    func register(with messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        methodChannel?.setMethodCallHandler(handleMethodCall)
        
        eventChannel = FlutterEventChannel(name: "\(channelName)/stream", binaryMessenger: messenger)
        eventChannel?.setStreamHandler(self)
        
        debugPrint("[ExecuTorchLLM] Channel registered with messenger")
    }
    
    // MARK: - Method Call Handler
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(true)
            
        case "loadModel":
            guard let args = call.arguments as? [String: Any],
                  let modelPath = args["modelPath"] as? String,
                  let tokenizerPath = args["tokenizerPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing modelPath or tokenizerPath", details: nil))
                return
            }
            loadModel(modelPath: modelPath, tokenizerPath: tokenizerPath, result: result)
            
        case "generate":
            guard let args = call.arguments as? [String: Any],
                  let prompt = args["prompt"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing prompt", details: nil))
                return
            }
            let maxTokens = args["maxTokens"] as? Int ?? 256
            let sequenceLength = args["sequenceLength"] as? Int ?? 128
            generate(prompt: prompt, maxTokens: maxTokens, sequenceLength: sequenceLength, result: result)
            
        case "generateStream":
            guard let args = call.arguments as? [String: Any],
                  let prompt = args["prompt"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing prompt", details: nil))
                return
            }
            let maxTokens = args["maxTokens"] as? Int ?? 256
            let sequenceLength = args["sequenceLength"] as? Int ?? 128
            generateStream(prompt: prompt, maxTokens: maxTokens, sequenceLength: sequenceLength, result: result)
            
        case "stop":
            stop(result: result)
            
        case "reset":
            reset(result: result)
            
        case "isLoaded":
            result(textRunner?.isLoaded() ?? false)
            
        case "unload":
            unload(result: result)
            
        case "getModelInfo":
            getModelInfo(result: result)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Model Management
    
    private func loadModel(modelPath: String, tokenizerPath: String, result: @escaping FlutterResult) {
        runnerQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if files exist
            guard FileManager.default.fileExists(atPath: modelPath) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FILE_NOT_FOUND", message: "Model file not found: \(modelPath)", details: nil))
                }
                return
            }
            
            guard FileManager.default.fileExists(atPath: tokenizerPath) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FILE_NOT_FOUND", message: "Tokenizer file not found: \(tokenizerPath)", details: nil))
                }
                return
            }
            
            // Determine model type from filename
            let modelType = self.detectModelType(from: modelPath)
            
            debugPrint("[ExecuTorchLLM] Loading model: \(modelPath)")
            debugPrint("[ExecuTorchLLM] Tokenizer: \(tokenizerPath)")
            debugPrint("[ExecuTorchLLM] Detected type: \(modelType)")
            
            // Clean up existing runners
            self.textRunner = nil
            self.multimodalRunner = nil
            
            let startTime = Date()
            
            do {
                // Create appropriate runner based on model type
                switch modelType {
                case .llama:
                    self.textRunner = TextRunner(
                        modelPath: modelPath,
                        tokenizerPath: tokenizerPath,
                        specialTokens: self.llamaSpecialTokens()
                    )
                case .qwen3, .phi4, .smollm3:
                    self.textRunner = TextRunner(
                        modelPath: modelPath,
                        tokenizerPath: tokenizerPath
                    )
                case .llava, .gemma3, .voxtral:
                    self.multimodalRunner = MultimodalRunner(
                        modelPath: modelPath,
                        tokenizerPath: tokenizerPath
                    )
                }
                
                // Load the model
                if let runner = self.textRunner {
                    try runner.load()
                } else if let runner = self.multimodalRunner {
                    try runner.load()
                }
                
                self.currentModelPath = modelPath
                self.currentTokenizerPath = tokenizerPath
                
                let loadTime = Date().timeIntervalSince(startTime)
                debugPrint("[ExecuTorchLLM] Model loaded in \(String(format: "%.2f", loadTime))s")
                
                DispatchQueue.main.async {
                    result([
                        "success": true,
                        "loadTimeSeconds": loadTime,
                        "modelType": String(describing: modelType)
                    ])
                }
            } catch {
                debugPrint("[ExecuTorchLLM] Load error: \(error)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "LOAD_ERROR", message: "Failed to load model: \(error.localizedDescription)", details: nil))
                }
            }
        }
    }
    
    private func unload(result: @escaping FlutterResult) {
        runnerQueue.async { [weak self] in
            self?.textRunner = nil
            self?.multimodalRunner = nil
            self?.currentModelPath = nil
            self?.currentTokenizerPath = nil
            
            DispatchQueue.main.async {
                result(true)
            }
        }
    }
    
    private func getModelInfo(result: @escaping FlutterResult) {
        result([
            "isLoaded": textRunner?.isLoaded() ?? multimodalRunner?.isLoaded() ?? false,
            "modelPath": currentModelPath ?? "",
            "tokenizerPath": currentTokenizerPath ?? "",
            "isGenerating": isGenerating
        ])
    }
    
    // MARK: - Generation
    
    private func generate(prompt: String, maxTokens: Int, sequenceLength: Int, result: @escaping FlutterResult) {
        guard !isGenerating else {
            result(FlutterError(code: "BUSY", message: "Generation already in progress", details: nil))
            return
        }
        
        guard let runner = textRunner, runner.isLoaded() else {
            result(FlutterError(code: "NOT_LOADED", message: "Model not loaded", details: nil))
            return
        }
        
        isGenerating = true
        shouldStop = false
        
        runnerQueue.async { [weak self] in
            guard let self = self else { return }
            
            var tokens: [String] = []
            var totalTokens = 0
            let startTime = Date()
            
            defer {
                runner.reset()
                self.isGenerating = false
            }
            
            do {
                try runner.generate(prompt, Config {
                    $0.sequenceLength = sequenceLength
                    $0.maximumNewTokens = maxTokens
                }) { token in
                    if self.shouldStop {
                        runner.stop()
                        return
                    }
                    
                    // Filter end tokens
                    if self.isEndToken(token) {
                        self.shouldStop = true
                        runner.stop()
                        return
                    }
                    
                    // Skip echoed prompt
                    if token != prompt {
                        tokens.append(token)
                        totalTokens += 1
                    }
                }
                
                let elapsed = Date().timeIntervalSince(startTime)
                let tokensPerSecond = elapsed > 0 ? Double(totalTokens) / elapsed : 0
                
                let responseText = tokens.joined()
                
                DispatchQueue.main.async {
                    result([
                        "text": responseText,
                        "tokenCount": totalTokens,
                        "tokensPerSecond": tokensPerSecond,
                        "elapsedSeconds": elapsed
                    ])
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "GENERATE_ERROR", message: "Generation failed: \(error.localizedDescription)", details: nil))
                }
            }
        }
    }
    
    private func generateStream(prompt: String, maxTokens: Int, sequenceLength: Int, result: @escaping FlutterResult) {
        guard !isGenerating else {
            result(FlutterError(code: "BUSY", message: "Generation already in progress", details: nil))
            return
        }
        
        guard let runner = textRunner, runner.isLoaded() else {
            result(FlutterError(code: "NOT_LOADED", message: "Model not loaded", details: nil))
            return
        }
        
        isGenerating = true
        shouldStop = false
        
        // Acknowledge the stream started
        result(["started": true])
        
        runnerQueue.async { [weak self] in
            guard let self = self else { return }
            
            var totalTokens = 0
            let startTime = Date()
            var tokenBuffer: [String] = []
            
            defer {
                runner.reset()
                self.isGenerating = false
                
                // Send completion event
                DispatchQueue.main.async {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let tokensPerSecond = elapsed > 0 ? Double(totalTokens) / elapsed : 0
                    self.eventSink?([
                        "type": "complete",
                        "tokenCount": totalTokens,
                        "tokensPerSecond": tokensPerSecond,
                        "elapsedSeconds": elapsed
                    ])
                }
            }
            
            do {
                try runner.generate(prompt, Config {
                    $0.sequenceLength = sequenceLength
                    $0.maximumNewTokens = maxTokens
                }) { token in
                    if self.shouldStop {
                        runner.stop()
                        return
                    }
                    
                    // Filter end tokens
                    if self.isEndToken(token) {
                        self.shouldStop = true
                        runner.stop()
                        return
                    }
                    
                    // Skip echoed prompt
                    if token != prompt {
                        tokenBuffer.append(token)
                        totalTokens += 1
                        
                        // Batch tokens for smoother streaming (every 2-3 tokens)
                        if tokenBuffer.count >= 2 {
                            let batchedText = tokenBuffer.joined()
                            tokenBuffer.removeAll()
                            
                            DispatchQueue.main.async {
                                self.eventSink?([
                                    "type": "token",
                                    "text": batchedText,
                                    "tokenCount": totalTokens
                                ])
                            }
                        }
                    }
                }
                
                // Flush remaining tokens
                if !tokenBuffer.isEmpty {
                    let remainingText = tokenBuffer.joined()
                    DispatchQueue.main.async {
                        self.eventSink?([
                            "type": "token",
                            "text": remainingText,
                            "tokenCount": totalTokens
                        ])
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.eventSink?(FlutterError(code: "GENERATE_ERROR", message: "Generation failed: \(error.localizedDescription)", details: nil))
                }
            }
        }
    }
    
    private func stop(result: @escaping FlutterResult) {
        shouldStop = true
        textRunner?.stop()
        multimodalRunner?.stop()
        result(true)
    }
    
    private func reset(result: @escaping FlutterResult) {
        runnerQueue.async { [weak self] in
            self?.textRunner?.reset()
            self?.multimodalRunner?.reset()
            self?.shouldStop = false
            
            DispatchQueue.main.async {
                result(true)
            }
        }
    }
    
    // MARK: - Helpers
    
    private enum ModelType {
        case llama
        case qwen3
        case phi4
        case smollm3
        case gemma3
        case llava
        case voxtral
    }
    
    private func detectModelType(from path: String) -> ModelType {
        let filename = (path as NSString).lastPathComponent.lowercased()
        
        if filename.hasPrefix("gemma3") || filename.contains("gemma-3") {
            return .gemma3
        } else if filename.hasPrefix("llama") || filename.contains("llama") {
            return .llama
        } else if filename.hasPrefix("llava") || filename.contains("llava") {
            return .llava
        } else if filename.hasPrefix("qwen3") || filename.contains("qwen") {
            return .qwen3
        } else if filename.hasPrefix("phi4") || filename.contains("phi-4") || filename.contains("phi4") {
            return .phi4
        } else if filename.contains("smollm3") || filename.contains("smollm-3") {
            return .smollm3
        } else if filename.hasPrefix("voxtral") || filename.contains("voxtral") {
            return .voxtral
        }
        
        // Default to llama
        return .llama
    }
    
    private func isEndToken(_ token: String) -> Bool {
        let endTokens = [
            "<|eot_id|>",
            "<|end_of_text|>",
            "<|im_end|>",
            "<|end|>",
            "<end_of_turn>",
            "</s>",
            "<|endoftext|>"
        ]
        return endTokens.contains(token)
    }
    
    private func llamaSpecialTokens() -> [String] {
        var tokens = [
            "<|begin_of_text|>",
            "<|end_of_text|>",
            "<|reserved_special_token_0|>",
            "<|reserved_special_token_1|>",
            "<|finetune_right_pad_id|>",
            "<|step_id|>",
            "<|start_header_id|>",
            "<|end_header_id|>",
            "<|eom_id|>",
            "<|eot_id|>",
            "<|python_tag|>"
        ]
        
        for i in 2..<256 {
            tokens.append("<|reserved_special_token_\(i)|>")
        }
        
        return tokens
    }
}

// MARK: - FlutterStreamHandler

extension ExecuTorchLLMChannel: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        shouldStop = true
        return nil
    }
}
