import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// iOS ExecuTorch LLM Service
/// Uses platform channels to communicate with native ExecuTorchLLM framework
class IOSLlmService {
  static const MethodChannel _channel = MethodChannel('com.example.anchor/llm');
  static const EventChannel _streamChannel = EventChannel(
    'com.example.anchor/llm/stream',
  );

  static final IOSLlmService _instance = IOSLlmService._internal();
  factory IOSLlmService() => _instance;
  IOSLlmService._internal();

  bool _isLoaded = false;
  bool _isGenerating = false;
  String? _currentModelPath;
  String? _currentTokenizerPath;

  StreamSubscription? _streamSubscription;

  // Getters
  bool get isLoaded => _isLoaded;
  bool get isGenerating => _isGenerating;
  String? get currentModelPath => _currentModelPath;

  /// Check if ExecuTorch is available on this platform
  Future<bool> isAvailable() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } catch (e) {
      debugPrint('[IOSLlmService] isAvailable error: $e');
      return false;
    }
  }

  /// Load a model with the given paths
  Future<Map<String, dynamic>> loadModel({
    required String modelPath,
    required String tokenizerPath,
  }) async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'UNSUPPORTED',
        message: 'IOSLlmService only works on iOS',
      );
    }

    debugPrint('[IOSLlmService] Loading model: $modelPath');
    debugPrint('[IOSLlmService] Tokenizer: $tokenizerPath');

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'loadModel',
        {
          'modelPath': modelPath,
          'tokenizerPath': tokenizerPath,
        },
      );

      if (result != null && result['success'] == true) {
        _isLoaded = true;
        _currentModelPath = modelPath;
        _currentTokenizerPath = tokenizerPath;

        return Map<String, dynamic>.from(result);
      } else {
        throw PlatformException(
          code: 'LOAD_FAILED',
          message: 'Failed to load model',
        );
      }
    } on PlatformException catch (e) {
      debugPrint('[IOSLlmService] Load error: ${e.message}');
      _isLoaded = false;
      rethrow;
    }
  }

  /// Check if a model is currently loaded
  Future<bool> checkIsLoaded() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isLoaded');
      _isLoaded = result ?? false;
      return _isLoaded;
    } catch (e) {
      debugPrint('[IOSLlmService] isLoaded error: $e');
      return false;
    }
  }

  /// Unload the current model
  Future<void> unload() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod('unload');
      _isLoaded = false;
      _currentModelPath = null;
      _currentTokenizerPath = null;
    } catch (e) {
      debugPrint('[IOSLlmService] Unload error: $e');
    }
  }

  /// Generate a response (non-streaming)
  Future<Map<String, dynamic>> generate({
    required String prompt,
    int maxTokens = 256,
    int sequenceLength = 512,
  }) async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'UNSUPPORTED',
        message: 'IOSLlmService only works on iOS',
      );
    }

    if (!_isLoaded) {
      throw StateError('Model not loaded');
    }

    if (_isGenerating) {
      throw StateError('Generation already in progress');
    }

    _isGenerating = true;

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'generate',
        {
          'prompt': prompt,
          'maxTokens': maxTokens,
          'sequenceLength': sequenceLength,
        },
      );

      return Map<String, dynamic>.from(result ?? {});
    } finally {
      _isGenerating = false;
    }
  }

  /// Generate a response with streaming tokens
  Future<String> generateStream({
    required String prompt,
    int maxTokens = 256,
    int sequenceLength = 512,
    void Function(String token, int tokenCount)? onToken,
    void Function(int totalTokens, double tokensPerSecond)? onComplete,
  }) async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'UNSUPPORTED',
        message: 'IOSLlmService only works on iOS',
      );
    }

    if (!_isLoaded) {
      throw StateError('Model not loaded');
    }

    if (_isGenerating) {
      throw StateError('Generation already in progress');
    }

    _isGenerating = true;
    final completer = Completer<String>();
    final buffer = StringBuffer();

    try {
      // Listen to the stream
      _streamSubscription = _streamChannel.receiveBroadcastStream().listen(
        (event) {
          if (event is Map) {
            final type = event['type'] as String?;

            if (type == 'token') {
              final text = event['text'] as String? ?? '';
              final tokenCount = event['tokenCount'] as int? ?? 0;
              buffer.write(text);
              onToken?.call(text, tokenCount);
            } else if (type == 'complete') {
              final totalTokens = event['tokenCount'] as int? ?? 0;
              final tps = (event['tokensPerSecond'] as num?)?.toDouble() ?? 0.0;
              onComplete?.call(totalTokens, tps);

              if (!completer.isCompleted) {
                completer.complete(buffer.toString());
              }
            }
          }
        },
        onError: (error) {
          debugPrint('[IOSLlmService] Stream error: $error');
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(buffer.toString());
          }
        },
      );

      // Start generation
      await _channel.invokeMethod(
        'generateStream',
        {
          'prompt': prompt,
          'maxTokens': maxTokens,
          'sequenceLength': sequenceLength,
        },
      );

      return await completer.future;
    } finally {
      _streamSubscription?.cancel();
      _streamSubscription = null;
      _isGenerating = false;
    }
  }

  /// Stop current generation
  Future<void> stop() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[IOSLlmService] Stop error: $e');
    }
  }

  /// Reset the runner state
  Future<void> reset() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod('reset');
    } catch (e) {
      debugPrint('[IOSLlmService] Reset error: $e');
    }
  }

  /// Get model info
  Future<Map<String, dynamic>> getModelInfo() async {
    if (!Platform.isIOS) return {};

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getModelInfo',
      );
      return Map<String, dynamic>.from(result ?? {});
    } catch (e) {
      debugPrint('[IOSLlmService] getModelInfo error: $e');
      return {};
    }
  }

  /// Find model files in app documents directory
  static Future<Map<String, String?>> findModelFiles() async {
    String? modelPath;
    String? tokenizerPath;

    try {
      final docDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docDir.path}/models');

      if (modelsDir.existsSync()) {
        for (final file in modelsDir.listSync()) {
          if (file is File) {
            final name = file.path.split('/').last;
            if (name.endsWith('.pte') && modelPath == null) {
              modelPath = file.path;
              debugPrint('[IOSLlmService] Found model: $modelPath');
            }
            if ((name == 'tokenizer.model' || name.endsWith('.bin')) &&
                tokenizerPath == null) {
              tokenizerPath = file.path;
              debugPrint('[IOSLlmService] Found tokenizer: $tokenizerPath');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[IOSLlmService] findModelFiles error: $e');
    }

    return {'model': modelPath, 'tokenizer': tokenizerPath};
  }
}

// ============================================================================
// Isolate-based generation for heavy computations on Flutter side
// ============================================================================

/// Data class for isolate communication
class _IsolateGenerateRequest {
  final String prompt;
  final int maxTokens;
  final int sequenceLength;
  final RootIsolateToken rootIsolateToken;
  final SendPort sendPort;

  _IsolateGenerateRequest({
    required this.prompt,
    required this.maxTokens,
    required this.sequenceLength,
    required this.rootIsolateToken,
    required this.sendPort,
  });
}

/// Run generation in a background isolate
/// This is useful if you need to do heavy processing on the Flutter side
Future<void> _runGenerationInIsolate(_IsolateGenerateRequest request) async {
  // Initialize binary messenger for background isolate
  BackgroundIsolateBinaryMessenger.ensureInitialized(request.rootIsolateToken);

  const channel = MethodChannel('com.example.anchor/llm');

  try {
    final result = await channel.invokeMethod<Map<dynamic, dynamic>>(
      'generate',
      {
        'prompt': request.prompt,
        'maxTokens': request.maxTokens,
        'sequenceLength': request.sequenceLength,
      },
    );

    request.sendPort.send({
      'success': true,
      'result': Map<String, dynamic>.from(result ?? {}),
    });
  } catch (e) {
    request.sendPort.send({
      'success': false,
      'error': e.toString(),
    });
  }
}

/// Extension for running generation in isolate
extension IOSLlmServiceIsolate on IOSLlmService {
  /// Generate in a background isolate (useful for heavy prompt processing)
  Future<Map<String, dynamic>> generateInIsolate({
    required String prompt,
    int maxTokens = 256,
    int sequenceLength = 128,
  }) async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'UNSUPPORTED',
        message: 'IOSLlmService only works on iOS',
      );
    }

    final rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken == null) {
      throw StateError('Could not get RootIsolateToken');
    }

    final receivePort = ReceivePort();

    await Isolate.spawn(
      _runGenerationInIsolate,
      _IsolateGenerateRequest(
        prompt: prompt,
        maxTokens: maxTokens,
        sequenceLength: sequenceLength,
        rootIsolateToken: rootIsolateToken,
        sendPort: receivePort.sendPort,
      ),
    );

    final response = await receivePort.first as Map<dynamic, dynamic>;
    receivePort.close();

    if (response['success'] == true) {
      return response['result'] as Map<String, dynamic>;
    } else {
      throw Exception(response['error'] ?? 'Unknown error');
    }
  }
}
