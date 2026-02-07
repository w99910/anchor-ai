import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_settings_service.dart';
import 'gemini_service.dart';
import 'ios_llm_service.dart';
import 'model_download_service.dart';
import 'user_info_service.dart';

/// Status of the LLM model
enum LlmModelStatus { notLoaded, loading, ready, error }

/// Inference backend type
enum LlmBackend {
  none,
  nativeRunner, // Using ExecuTorch LlmModule JNI (Android)
  iosExecuTorch, // Using native ExecuTorchLLM (iOS)
  mockResponses, // Fallback mock responses
  geminiCloud, // Cloud Gemini API
}

/// Service for managing on-device LLM inference using ExecuTorch
class LlmService extends ChangeNotifier {
  static final LlmService _instance = LlmService._internal();
  factory LlmService() => _instance;
  LlmService._internal();

  // Platform channel for native runner
  static const MethodChannel _nativeChannel = MethodChannel(
    'com.example.anchor/llm',
  );

  // AI settings and Gemini services
  final _aiSettings = AiSettingsService();
  final _geminiService = GeminiService();

  // iOS LLM Service
  final _iosLlmService = IOSLlmService();

  LlmModelStatus _status = LlmModelStatus.notLoaded;
  String? _errorMessage;
  double _loadProgress = 0.0;
  LlmBackend _activeBackend = LlmBackend.none;

  // Track which model is loaded (true = Qwen/ChatML format, false = Llama format)
  bool _useAdvanceModel = false;

  // Model paths (set during loadModel)
  String? _externalModelPath;
  String? _tokenizerPath;

  // Getters
  LlmModelStatus get status => _status;
  String? get errorMessage => _errorMessage;
  double get loadProgress => _loadProgress;
  bool get isReady => _status == LlmModelStatus.ready || isCloudProviderReady;
  bool get isLoading => _status == LlmModelStatus.loading;
  LlmBackend get activeBackend =>
      _aiSettings.isCloudProvider && _geminiService.isConfigured
      ? LlmBackend.geminiCloud
      : _activeBackend;

  /// Returns true if cloud provider is selected and ready
  bool get isCloudProviderReady =>
      _aiSettings.isCloudProvider && _geminiService.isConfigured;

  /// Returns true if using cloud provider
  bool get isUsingCloudProvider => _aiSettings.isCloudProvider;

  /// Returns true if a real AI model is loaded (not mock responses)
  bool get hasRealAI =>
      isCloudProviderReady ||
      (_status == LlmModelStatus.ready &&
          (_activeBackend == LlmBackend.nativeRunner ||
              _activeBackend == LlmBackend.iosExecuTorch));

  /// Returns true if Qwen model is loaded, false for Llama
  bool get useAdvancedModel => _useAdvanceModel;

  /// Set an external model path (for models not bundled with the app)
  void setExternalModelPath(String path) {
    _externalModelPath = path;
  }

  /// Check if native Llama runner is available (Android only)
  Future<bool> isNativeRunnerAvailable() async {
    if (!Platform.isAndroid) return false;

    try {
      final isAvailable = await _nativeChannel.invokeMethod<bool>(
        'isNativeRunnerAvailable',
      );
      debugPrint('Native runner available: $isAvailable');
      return isAvailable ?? false;
    } catch (e) {
      debugPrint('Error checking native runner: $e');
      return false;
    }
  }

  /// Check if model is available in app storage
  Future<bool> isModelAvailable() async {
    final downloadService = ModelDownloadService();
    return await downloadService.isModelDownloaded();
  }

  /// Load the LLM model
  Future<void> loadModel() async {
    if (_status == LlmModelStatus.loading) return;

    _status = LlmModelStatus.loading;
    _errorMessage = null;
    _loadProgress = 0.0;
    _activeBackend = LlmBackend.none;
    notifyListeners();

    try {
      _updateProgress(0.1, 'Checking model...');

      // Check if model is downloaded to app storage
      final downloadService = ModelDownloadService();
      final isDownloaded = await downloadService.isModelDownloaded();

      if (!isDownloaded) {
        // Model not in app storage - use demo mode, user needs to download
        debugPrint('Model not downloaded to app storage');
        _activeBackend = LlmBackend.mockResponses;
        _updateProgress(1.0, 'Demo mode - download model for AI');
        _status = LlmModelStatus.ready;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('llm_model_loaded', false);
        notifyListeners();
        return;
      }

      // Model is downloaded - use it from app storage
      final modelPath = await downloadService.getModelPath();
      final tokenizerPath = await downloadService.getTokenizerPath();
      _externalModelPath = modelPath;
      _tokenizerPath = tokenizerPath;
      _useAdvanceModel = downloadService.useAdvancedModel;

      debugPrint('Model path: $modelPath');
      debugPrint('Tokenizer path: $tokenizerPath');

      _updateProgress(0.3, 'Initializing...');

      // Try iOS ExecuTorch native runner
      if (Platform.isIOS) {
        _updateProgress(0.4, 'Loading iOS ExecuTorch...');
        final isAvailable = await _iosLlmService.isAvailable();

        if (isAvailable) {
          try {
            debugPrint('Using iOS ExecuTorch runner');
            _updateProgress(0.5, 'Loading model...');

            final loadResult = await _iosLlmService.loadModel(
              modelPath: modelPath,
              tokenizerPath: tokenizerPath,
            );

            final loadTime = loadResult['loadTimeSeconds'] as double? ?? 0.0;
            debugPrint('iOS model loaded in ${loadTime.toStringAsFixed(2)}s');

            _activeBackend = LlmBackend.iosExecuTorch;
            _updateProgress(1.0, 'Ready');
            _status = LlmModelStatus.ready;

            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('llm_model_loaded', true);
            notifyListeners();
            return;
          } catch (e) {
            debugPrint('iOS ExecuTorch loading failed: $e');
            // Fall through to try other backends
          }
        }
      }

      // Try native runner (Android only) — uses ExecuTorch LlmModule JNI
      if (Platform.isAndroid) {
        final hasNativeRunner = await isNativeRunnerAvailable();

        if (hasNativeRunner) {
          debugPrint('Loading model via ExecuTorch LlmModule...');
          _updateProgress(0.5, 'Loading model into memory...');

          try {
            final loadResult = await _nativeChannel
                .invokeMethod<Map>('loadModel', {
                  'modelPath': modelPath,
                  'tokenizerPath': tokenizerPath,
                  'temperature': 0.0,
                });
            final loadTime = loadResult?['loadTimeSeconds'] as double? ?? 0.0;
            debugPrint(
              'ExecuTorch model loaded in ${loadTime.toStringAsFixed(2)}s',
            );

            _activeBackend = LlmBackend.nativeRunner;
            _updateProgress(1.0, 'Ready');
            _status = LlmModelStatus.ready;

            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('llm_model_loaded', true);
            notifyListeners();
            return;
          } catch (e) {
            debugPrint('ExecuTorch model loading failed: $e');
            // Fall through to mock responses
          }
        }
      }

      // No native runner available, fall back to mock responses
      debugPrint('No native runner available, using mock responses');
      _activeBackend = LlmBackend.mockResponses;
      _updateProgress(1.0, 'Demo mode');
      _status = LlmModelStatus.ready;
    } catch (e, stackTrace) {
      _status = LlmModelStatus.error;
      _errorMessage = e.toString();
      _activeBackend = LlmBackend.none;
      debugPrint('Error loading LLM model: $e');
      debugPrint('Stack trace: $stackTrace');
    }

    notifyListeners();
  }

  void _updateProgress(double progress, String message) {
    _loadProgress = progress;
    debugPrint('LLM Load Progress: ${(progress * 100).toInt()}% - $message');
    notifyListeners();
  }

  /// Format prompt using Llama chat template with conversation history
  String _formatLlamaPromptWithHistory(
    String systemPrompt,
    List<Map<String, String>>? chatHistory,
    String userPrompt,
  ) {
    final buffer = StringBuffer();
    buffer.write(
      '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n',
    );
    buffer.write('$systemPrompt<|eot_id|>');

    // Add conversation history
    if (chatHistory != null && chatHistory.isNotEmpty) {
      for (final message in chatHistory) {
        final role = message['role'] == 'user' ? 'user' : 'assistant';
        final content = message['content'] ?? '';
        buffer.write(
          '<|start_header_id|>$role<|end_header_id|>\n\n$content<|eot_id|>',
        );
      }
    }

    // Add current user message
    buffer.write(
      '<|start_header_id|>user<|end_header_id|>\n\n$userPrompt<|eot_id|>',
    );
    buffer.write('<|start_header_id|>assistant<|end_header_id|>\n\n');

    return buffer.toString();
  }

  /// Generate a response for the given prompt
  Future<String> generateResponse({
    required String prompt,
    required String mode, // 'friend' or 'therapist'
    List<Map<String, String>>?
    chatHistory, // Previous messages in format [{"role": "user"/"assistant", "content": "..."}]
    int maxTokens = 256,
    double temperature = 0.7,
    StreamController<String>? streamController,
  }) async {
    // Check if cloud provider is selected and available
    if (_aiSettings.isCloudProvider && _geminiService.isConfigured) {
      debugPrint('Using Gemini cloud provider for response');
      return _geminiService.generateResponse(
        prompt: prompt,
        mode: mode,
        chatHistory: chatHistory,
        maxTokens: maxTokens,
        temperature: temperature,
        streamController: streamController,
      );
    }

    // Get user context for personalization
    final userContext = UserInfoService().getUserContext();

    // Use compact prompt for on-device LLM to maximize performance
    final isOnDevice =
        _activeBackend == LlmBackend.iosExecuTorch ||
        _activeBackend == LlmBackend.nativeRunner;

    // Build the chat prompt with system message
    final systemPrompt = isOnDevice
        ? (mode == 'friend'
              ? 'You are a warm, supportive friend. Be genuine, validate feelings, and speak naturally.'
              : 'You are a compassionate AI therapist. Use reflective listening and gentle questions to help explore emotions.')
        : (mode == 'friend'
              ? '''You are a warm, genuine, and supportive friend. You are NOT a clinical therapist.

Guidelines:

Active Reassurance: Do not just reflect the user's feelings back to them. You must actively validate them. If they share a negative thought (like 'I'm a failure'), explicitly tell them that one mistake does not define them.

Normalize: Remind the user that their struggles (like burnout or missing deadlines) are a normal part of being human.

Conversational Tone: Speak naturally. Use phrases like 'I get it,' 'That is so heavy,' or 'I'm here for you.'

Less Asking, More Sharing: Do not end every message with a question. Sometimes, just sitting with the emotion is enough. If you do ask a question, make it casual.

When speaking in other language, do not translate English idioms literally.$userContext'''
              : '''Role: You are a compassionate, professional, and non-judgmental AI therapist. You draw upon techniques from Cognitive Behavioral Therapy (CBT) and Person-Centered Therapy.

Core Objective: Your goal is not to "fix" the user or give direct advice, but to help them explore their emotions, identify cognitive distortions (negative thought patterns), and find their own clarity.

Guidelines:

Reflective Listening: Start by validating the user's feelings to establish safety (e.g., "It sounds like you're carrying a heavy burden...").

Socratic Questioning: Use open-ended, probing questions to help the user examine the evidence for their beliefs. (e.g., "What evidence do you have that supports this fear? Is there evidence that contradicts it?")

Identify Distortions: If the user exhibits common cognitive distortions (like catastrophizing, all-or-nothing thinking, or mind reading), gently ask questions that help them see the gap between their thought and reality.

Neutrality: Do not take sides or offer personal opinions. Remain an objective mirror.

Safety & Boundaries: Do not diagnose medical conditions. If the user mentions self-harm or severe crisis, prioritize safety resources immediately.

Tone: Professional, calm, curious, and empathetic. Avoid being overly casual or using slang.

Lanaguage: When speaking in other language, do not translate English idioms literally.$userContext''');

    // Format prompt based on model type
    final fullPrompt = _formatLlamaPromptWithHistory(
      systemPrompt,
      chatHistory,
      prompt,
    );

    // Use iOS ExecuTorch if available
    if (_activeBackend == LlmBackend.iosExecuTorch) {
      return _generateWithIOSExecuTorch(
        fullPrompt,
        maxTokens,
        streamController: streamController,
      );
    }

    // Use native runner if available (Android)
    if (_activeBackend == LlmBackend.nativeRunner) {
      return _generateWithNativeRunner(
        fullPrompt,
        maxTokens,
        streamController: streamController,
      );
    }

    // Use mock responses as fallback
    return _generateMockResponse(prompt, mode);
  }

  /// Generate response using ExecuTorch LlmModule (JNI — model already in memory)
  ///
  /// The native side runs generation on a dedicated executor thread so it
  /// won't block the Flutter UI thread. With the ExecuTorch library approach
  /// the output is clean tokens — no log noise or stdout parsing needed.
  Future<String> _generateWithNativeRunner(
    String prompt,
    int maxTokens, {
    StreamController<String>? streamController,
  }) async {
    if (_externalModelPath == null || _tokenizerPath == null) {
      throw Exception('Model or tokenizer path not set');
    }

    try {
      debugPrint('[ExecuTorch] Starting generation (maxTokens=$maxTokens)');

      // If streaming is requested, use EventChannel for real-time tokens
      if (streamController != null) {
        return _generateWithNativeRunnerStreaming(
          prompt,
          maxTokens,
          streamController,
        );
      }

      // Non-streaming: call runLlama which returns the full generated text
      // The native side uses LlmModule.generate() with a callback internally,
      // collects all tokens, then returns the complete response.
      final result = await _nativeChannel.invokeMethod<String>('runLlama', {
        'modelPath': _externalModelPath!,
        'tokenizerPath': _tokenizerPath!,
        'prompt': prompt,
        'maxSeqLen': maxTokens,
      });

      final response = result ?? '';
      debugPrint('[ExecuTorch] Generation complete: ${response.length} chars');
      return response;
    } catch (e) {
      debugPrint('[ExecuTorch] Generation error: $e');
      return _generateMockResponse(prompt, 'friend');
    }
  }

  /// Streaming generation via EventChannel — tokens arrive in real-time
  Future<String> _generateWithNativeRunnerStreaming(
    String prompt,
    int maxTokens,
    StreamController<String> streamController,
  ) async {
    final completer = Completer<String>();
    final collectedTokens = StringBuffer();

    const streamChannel = EventChannel('com.example.anchor/llm_stream');
    StreamSubscription? subscription;

    subscription = streamChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final type = event['type'] as String?;
          final data = event['data'] as String? ?? '';

          switch (type) {
            case 'token':
              collectedTokens.write(data);
              streamController.add(data);
              break;
            case 'done':
              subscription?.cancel();
              if (!completer.isCompleted) {
                completer.complete(collectedTokens.toString());
              }
              break;
            case 'stats':
              final tps = event['tokensPerSecond'] as double? ?? 0.0;
              debugPrint('[ExecuTorch] ${tps.toStringAsFixed(1)} tokens/sec');
              break;
            case 'status':
              debugPrint('[ExecuTorch] Status: $data');
              break;
          }
        }
      },
      onError: (error) {
        subscription?.cancel();
        if (!completer.isCompleted) {
          completer.complete(collectedTokens.toString());
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(collectedTokens.toString());
        }
      },
    );

    // Trigger streaming generation on the native side
    await _nativeChannel.invokeMethod('runLlamaStream', {
      'modelPath': _externalModelPath!,
      'tokenizerPath': _tokenizerPath!,
      'prompt': prompt,
      'maxSeqLen': maxTokens,
    });

    return completer.future;
  }

  /// Generate response using iOS ExecuTorch runner
  Future<String> _generateWithIOSExecuTorch(
    String prompt,
    int maxTokens, {
    StreamController<String>? streamController,
  }) async {
    try {
      debugPrint('[iOS] Starting ExecuTorch inference...');

      if (streamController != null) {
        // Use streaming generation
        final result = await _iosLlmService.generateStream(
          prompt: prompt,
          maxTokens: maxTokens,
          sequenceLength: _useAdvanceModel ? 512 : 256,
          onToken: (token, tokenCount) {
            streamController.add(token);
          },
          onComplete: (totalTokens, tokensPerSecond) {
            debugPrint(
              '[iOS] Generation complete: $totalTokens tokens at ${tokensPerSecond.toStringAsFixed(2)} t/s',
            );
          },
        );

        return _parseIOSOutput(result);
      } else {
        // Non-streaming generation
        final result = await _iosLlmService.generate(
          prompt: prompt,
          maxTokens: maxTokens,
          sequenceLength: _useAdvanceModel ? 512 : 256,
        );

        final text = result['text'] as String? ?? '';
        final tokenCount = result['tokenCount'] as int? ?? 0;
        final tps = (result['tokensPerSecond'] as num?)?.toDouble() ?? 0.0;

        debugPrint(
          '[iOS] Generation complete: $tokenCount tokens at ${tps.toStringAsFixed(2)} t/s',
        );

        return _parseIOSOutput(text);
      }
    } catch (e) {
      debugPrint('[iOS] ExecuTorch error: $e');
      return _generateMockResponse(prompt, 'friend');
    }
  }

  /// Parse output from iOS ExecuTorch runner
  String _parseIOSOutput(String output) {
    String fullText = output.trim();

    // Remove Llama format markers
    final assistantMarkerIndex = fullText.lastIndexOf(
      '<|start_header_id|>assistant<|end_header_id|>',
    );
    if (assistantMarkerIndex != -1) {
      fullText = fullText.substring(
        assistantMarkerIndex +
            '<|start_header_id|>assistant<|end_header_id|>'.length,
      );
    }

    // Remove special tokens
    fullText = fullText
        .replaceAll('<|eot_id|>', '')
        .replaceAll('<|end_of_text|>', '')
        .replaceAll('<|begin_of_text|>', '')
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|im_start|>', '')
        .replaceAll('<|end|>', '')
        .replaceAll('<end_of_turn>', '')
        .replaceAll('</s>', '')
        .replaceAll(RegExp(r'<\|start_header_id\|>\w+<\|end_header_id\|>'), '')
        .trim();

    return fullText;
  }

  /// Generate a mock response when model is not available
  String _generateMockResponse(String prompt, String mode) {
    if (mode == 'friend') {
      final responses = [
        "Thanks for sharing that with me! I'm here to listen and support you. 😊",
        "I hear you. That sounds like a lot to deal with. How are you feeling about it?",
        "I appreciate you opening up to me. What's been on your mind lately?",
        "That makes sense. It's okay to feel that way. I'm here for you.",
      ];
      return responses[DateTime.now().second % responses.length];
    } else {
      final responses = [
        "Thank you for sharing that. It takes courage to express these feelings. What do you think might be contributing to this?",
        "I appreciate you opening up. Let's explore that together. Can you tell me more about when you first noticed this?",
        "That sounds challenging. It's important to acknowledge these feelings. What would feel supportive for you right now?",
        "I hear what you're saying. Let's take a moment to understand this better. What would a good outcome look like for you?",
      ];
      return responses[DateTime.now().second % responses.length];
    }
  }

  /// Dispose of the model
  @override
  Future<void> dispose() async {
    _status = LlmModelStatus.notLoaded;

    // Unload native model
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('unloadModel');
      } catch (e) {
        debugPrint('Error unloading Android model: $e');
      }
    }

    // Unload iOS model if loaded
    if (Platform.isIOS) {
      await _iosLlmService.unload();
    }

    super.dispose();
  }
}
