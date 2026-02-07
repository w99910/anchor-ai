package com.example.anchor

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.system.ErrnoException
import android.system.Os
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.pytorch.executorch.extension.llm.LlmCallback
import org.pytorch.executorch.extension.llm.LlmModule
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * MainActivity using ExecuTorch LlmModule JNI for on-device LLM inference.
 *
 * This replaces the previous process-based approach (spawning libllama_main.so)
 * with the official ExecuTorch Android library, matching the LlamaDemo reference
 * implementation. Benefits:
 * - True token-by-token streaming via LlmCallback (no stdout parsing)
 * - Model stays loaded in memory between generations (no process respawn)
 * - Proper model lifecycle (load/unload/stop)
 * - Performance stats (tokens/sec) from the runtime
 * - No log noise or output parsing needed
 */
class MainActivity : FlutterFragmentActivity(), LlmCallback {
    companion object {
        private const val CHANNEL = "com.example.anchor/llm"
        private const val STREAM_CHANNEL = "com.example.anchor/llm_stream"
        private const val DEEPLINK_EVENTS_CHANNEL = "com.example.anchor/deeplink_events"
        private const val TAG = "ExecuTorchLLM"

        // Model category constants (from ExecuTorch ModelUtils)
        private const val MODEL_CATEGORY_TEXT = 1

        // Stop tokens — generation should halt when these appear
        // Covers Llama 3, Qwen 3, Gemma 3, LLaVA, Voxtral formats
        private val STOP_TOKENS = setOf(
            "<|eot_id|>",
            "<|end_of_text|>",
            "<|im_end|>",
            "<end_of_turn>",
            "</s>"
        )

        // Tokens to silently skip (not appended to output)
        private val SKIP_TOKENS = setOf(
            "<|start_header_id|>",
            "<|end_header_id|>",
            "<|begin_of_text|>"
        )
    }

    // ExecuTorch LlmModule — loaded once, reused for all generations
    private var llmModule: LlmModule? = null
    private var isModelLoaded = false
    @Volatile private var isGenerating = false

    // Track loaded model paths so we can skip redundant loads
    private var loadedModelPath: String? = null
    private var loadedTokenizerPath: String? = null

    // Streaming state: collects tokens during generation
    private val generatedTokens = StringBuilder()
    private var generationStartTime = 0L
    private var sawHeaderToken = false

    // EventChannel sinks
    private var eventSink: EventChannel.EventSink? = null
    private var deeplinkEventSink: EventChannel.EventSink? = null
    private var linksReceiver: BroadcastReceiver? = null

    // Single-thread executor for model operations (load/generate) — avoids
    // thread contention and matches LlamaDemo's pattern
    private val executor: Executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // MethodChannel.Result for non-streaming runLlama (replied when generation finishes)
    private var pendingResult: MethodChannel.Result? = null

    // =========================================================================
    // Activity lifecycle
    // =========================================================================

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Set library paths so ExecuTorch JNI can find its native .so files
        try {
            Os.setenv("ADSP_LIBRARY_PATH", applicationInfo.nativeLibraryDir, true)
            Os.setenv("LD_LIBRARY_PATH", applicationInfo.nativeLibraryDir, true)
        } catch (e: ErrnoException) {
            Log.e(TAG, "Failed to set library paths: ${e.message}")
        }

        // Handle initial deep link if app was launched via deep link
        handleDeepLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW) {
            val dataString = intent.dataString
            if (dataString != null) {
                Log.d(TAG, "Received deep link: $dataString")
                mainHandler.post {
                    deeplinkEventSink?.success(dataString)
                }
            }
        }
    }

    // =========================================================================
    // Flutter engine configuration — channels
    // =========================================================================

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Deep link EventChannel (for WalletConnect/Reown) ---
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DEEPLINK_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    deeplinkEventSink = events
                    linksReceiver = createDeepLinkReceiver(events)
                    Log.d(TAG, "Deep link listener attached")
                }
                override fun onCancel(arguments: Any?) {
                    deeplinkEventSink = null
                    linksReceiver = null
                    Log.d(TAG, "Deep link listener cancelled")
                }
            })

        // --- LLM streaming EventChannel ---
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    Log.d(TAG, "LLM stream listener attached")
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    Log.d(TAG, "LLM stream listener cancelled")
                }
            })

        // --- LLM MethodChannel ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // ── Load model into memory (new — persistent across generations) ──
                    "loadModel" -> {
                        val modelPath = call.argument<String>("modelPath")
                        val tokenizerPath = call.argument<String>("tokenizerPath")
                        val temperature = call.argument<Double>("temperature")?.toFloat() ?: 0.0f

                        if (modelPath == null || tokenizerPath == null) {
                            result.error("INVALID_ARGS", "Missing modelPath or tokenizerPath", null)
                            return@setMethodCallHandler
                        }
                        loadModel(modelPath, tokenizerPath, temperature, result)
                    }

                    // ── Unload model from memory ──
                    "unloadModel" -> {
                        unloadModel()
                        result.success(true)
                    }

                    // ── Non-streaming generation (backward compatible) ──
                    // Loads model on-the-fly if not already loaded, generates, returns full text.
                    "runLlama" -> {
                        val modelPath = call.argument<String>("modelPath")
                        val tokenizerPath = call.argument<String>("tokenizerPath")
                        val prompt = call.argument<String>("prompt")
                        val maxSeqLen = call.argument<Int>("maxSeqLen") ?: 256

                        if (modelPath == null || tokenizerPath == null || prompt == null) {
                            result.error("INVALID_ARGS", "Missing required arguments", null)
                            return@setMethodCallHandler
                        }
                        runLlama(modelPath, tokenizerPath, prompt, maxSeqLen, result)
                    }

                    // ── Streaming generation via EventChannel ──
                    "runLlamaStream" -> {
                        val modelPath = call.argument<String>("modelPath")
                        val tokenizerPath = call.argument<String>("tokenizerPath")
                        val prompt = call.argument<String>("prompt")
                        val maxSeqLen = call.argument<Int>("maxSeqLen") ?: 256

                        if (modelPath == null || tokenizerPath == null || prompt == null) {
                            result.error("INVALID_ARGS", "Missing required arguments", null)
                            return@setMethodCallHandler
                        }
                        // Return immediately; tokens delivered via EventChannel
                        result.success(true)
                        runLlamaStream(modelPath, tokenizerPath, prompt, maxSeqLen)
                    }

                    // ── Query state ──
                    "isModelLoaded" -> {
                        result.success(isModelLoaded)
                    }

                    "isNativeRunnerAvailable" -> {
                        // With ExecuTorch library, always available
                        result.success(true)
                    }

                    "getNativeLibPath" -> {
                        result.success(applicationInfo.nativeLibraryDir)
                    }

                    // ── Stop current generation ──
                    "stopLlama" -> {
                        stopGeneration()
                        result.success(true)
                    }

                    // ── Reset model context (clear KV cache for new conversation) ──
                    "resetContext" -> {
                        llmModule?.resetContext()
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // =========================================================================
    // Model loading — using ExecuTorch LlmModule (matches LlamaDemo)
    // =========================================================================

    /**
     * Load the model into memory. If the same model is already loaded, this is a no-op.
     * Runs on the executor thread to avoid blocking the UI.
     */
    private fun loadModel(
        modelPath: String,
        tokenizerPath: String,
        temperature: Float,
        result: MethodChannel.Result
    ) {
        // Skip if already loaded with same paths
        if (isModelLoaded && loadedModelPath == modelPath && loadedTokenizerPath == tokenizerPath) {
            Log.d(TAG, "Model already loaded, skipping")
            mainHandler.post { result.success(mapOf("alreadyLoaded" to true)) }
            return
        }

        executor.execute {
            try {
                // Validate files
                if (!File(modelPath).exists()) {
                    mainHandler.post { result.error("MODEL_NOT_FOUND", "Model file not found: $modelPath", null) }
                    return@execute
                }
                if (!File(tokenizerPath).exists()) {
                    mainHandler.post { result.error("TOKENIZER_NOT_FOUND", "Tokenizer file not found: $tokenizerPath", null) }
                    return@execute
                }

                sendStreamEvent("status", "loading")
                Log.d(TAG, "Loading model: $modelPath")
                Log.d(TAG, "Tokenizer: $tokenizerPath")
                Log.d(TAG, "Temperature: $temperature")

                val loadStartTime = System.currentTimeMillis()

                // Unload previous model if any
                llmModule?.stop()
                llmModule = null
                isModelLoaded = false

                // Create LlmModule — same pattern as LlamaDemo ChatViewModel
                llmModule = LlmModule(
                    MODEL_CATEGORY_TEXT,
                    modelPath,
                    tokenizerPath,
                    temperature
                )

                // Actually load the model into memory (JNI call)
                llmModule!!.load()

                val loadDuration = System.currentTimeMillis() - loadStartTime
                val loadTimeSec = loadDuration.toFloat() / 1000f

                isModelLoaded = true
                loadedModelPath = modelPath
                loadedTokenizerPath = tokenizerPath

                Log.d(TAG, "Model loaded successfully in ${loadTimeSec}s")
                sendStreamEvent("status", "ready")

                mainHandler.post {
                    result.success(mapOf(
                        "success" to true,
                        "loadTimeSeconds" to loadTimeSec.toDouble()
                    ))
                }

            } catch (e: Exception) {
                Log.e(TAG, "Failed to load model: ${e.message}", e)
                isModelLoaded = false
                llmModule = null
                sendStreamEvent("status", "error")

                mainHandler.post {
                    result.error("LOAD_ERROR", "Failed to load model: ${e.message}", e.stackTraceToString())
                }
            }
        }
    }

    /**
     * Unload model and free memory.
     */
    private fun unloadModel() {
        Log.d(TAG, "Unloading model")
        if (isGenerating) {
            llmModule?.stop()
            isGenerating = false
        }
        llmModule = null
        isModelLoaded = false
        loadedModelPath = null
        loadedTokenizerPath = null
    }

    // =========================================================================
    // Generation — non-streaming (backward compatible with "runLlama")
    // =========================================================================

    /**
     * Non-streaming generation. Auto-loads the model if needed, generates the
     * full response, then returns it via MethodChannel.Result.
     */
    private fun runLlama(
        modelPath: String,
        tokenizerPath: String,
        prompt: String,
        maxSeqLen: Int,
        result: MethodChannel.Result
    ) {
        if (isGenerating) {
            result.error("BUSY", "Generation already in progress", null)
            return
        }

        executor.execute {
            try {
                // Auto-load model if not loaded or different model requested
                ensureModelLoaded(modelPath, tokenizerPath)

                if (!isModelLoaded || llmModule == null) {
                    mainHandler.post {
                        result.error("MODEL_NOT_LOADED", "Failed to load model", null)
                    }
                    return@execute
                }

                Log.d(TAG, "Running non-streaming inference, maxSeqLen=$maxSeqLen")
                isGenerating = true
                generatedTokens.clear()
                sawHeaderToken = false
                generationStartTime = System.currentTimeMillis()
                pendingResult = result

                // Set thread priority for faster inference (matches LlamaDemo)
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_MORE_FAVORABLE)

                // Generate! Tokens arrive via onResult() callback
                llmModule!!.generate(prompt, maxSeqLen, this@MainActivity, false)

                // Generation complete — return collected tokens
                val generateDuration = System.currentTimeMillis() - generationStartTime
                val responseText = generatedTokens.toString()

                Log.d(TAG, "Non-streaming generation complete in ${generateDuration}ms, ${responseText.length} chars")

                isGenerating = false
                pendingResult = null

                mainHandler.post {
                    result.success(responseText)
                }

            } catch (e: Exception) {
                Log.e(TAG, "Generation error: ${e.message}", e)
                isGenerating = false
                pendingResult = null
                mainHandler.post {
                    result.error("GENERATION_ERROR", e.message, e.stackTraceToString())
                }
            }
        }
    }

    // =========================================================================
    // Generation — streaming (via EventChannel)
    // =========================================================================

    /**
     * Streaming generation. Tokens are sent individually via the EventChannel
     * as they're produced by the model — true real-time streaming.
     */
    private fun runLlamaStream(
        modelPath: String,
        tokenizerPath: String,
        prompt: String,
        maxSeqLen: Int
    ) {
        if (isGenerating) {
            sendStreamError("Generation already in progress")
            return
        }

        executor.execute {
            try {
                // Auto-load model if needed
                ensureModelLoaded(modelPath, tokenizerPath)

                if (!isModelLoaded || llmModule == null) {
                    sendStreamError("Failed to load model")
                    return@execute
                }

                Log.d(TAG, "Running streaming inference, maxSeqLen=$maxSeqLen")
                isGenerating = true
                generatedTokens.clear()
                sawHeaderToken = false
                generationStartTime = System.currentTimeMillis()
                pendingResult = null  // streaming mode uses EventChannel

                sendStreamEvent("status", "generating")

                // Set thread priority for faster inference
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_MORE_FAVORABLE)

                // Generate — each token arrives via onResult(), stats via onStats()
                llmModule!!.generate(prompt, maxSeqLen, this@MainActivity, false)

                // Generation complete
                val generateDuration = System.currentTimeMillis() - generationStartTime
                val responseText = generatedTokens.toString()

                Log.d(TAG, "Streaming generation complete in ${generateDuration}ms")
                isGenerating = false

                sendStreamEvent("done", responseText)

            } catch (e: Exception) {
                Log.e(TAG, "Streaming generation error: ${e.message}", e)
                isGenerating = false
                sendStreamError(e.message ?: "Unknown error")
            }
        }
    }

    /**
     * Ensures the requested model is loaded. If a different model is loaded,
     * unloads first and loads the new one.
     */
    private fun ensureModelLoaded(modelPath: String, tokenizerPath: String) {
        if (isModelLoaded && loadedModelPath == modelPath && loadedTokenizerPath == tokenizerPath) {
            return  // Already loaded
        }

        // Validate files exist
        if (!File(modelPath).exists()) {
            throw IllegalArgumentException("Model file not found: $modelPath")
        }
        if (!File(tokenizerPath).exists()) {
            throw IllegalArgumentException("Tokenizer file not found: $tokenizerPath")
        }

        Log.d(TAG, "Auto-loading model: ${modelPath.substringAfterLast('/')}")
        sendStreamEvent("status", "loading")

        // Unload previous
        llmModule?.stop()
        llmModule = null
        isModelLoaded = false

        val loadStart = System.currentTimeMillis()

        llmModule = LlmModule(
            MODEL_CATEGORY_TEXT,
            modelPath,
            tokenizerPath,
            0.0f  // default temperature for auto-load
        )
        llmModule!!.load()

        val loadDuration = System.currentTimeMillis() - loadStart
        isModelLoaded = true
        loadedModelPath = modelPath
        loadedTokenizerPath = tokenizerPath

        Log.d(TAG, "Model auto-loaded in ${loadDuration.toFloat() / 1000f}s")
    }

    /**
     * Stop the current generation.
     */
    private fun stopGeneration() {
        if (isGenerating) {
            Log.d(TAG, "Stopping generation")
            llmModule?.stop()
            isGenerating = false
        }
    }

    // =========================================================================
    // LlmCallback implementation — token-by-token streaming from ExecuTorch
    // =========================================================================

    /**
     * Called by ExecuTorch for each generated token. This is the core streaming
     * mechanism — no stdout parsing, no log filtering, just clean tokens.
     *
     * Filters out stop/special tokens (matching LlamaDemo's onResult behavior).
     */
    override fun onResult(result: String) {
        // Stop tokens — do not append or forward these to Flutter
        // (matches LlamaDemo: PromptFormat.getStopToken checks)
        if (result in STOP_TOKENS) {
            llmModule?.stop()
            return
        }

        // Skip header tokens that leak through (e.g. "<|start_header_id|>", "assistant", "<|end_header_id|>")
        if (result in SKIP_TOKENS || sawHeaderToken) {
            if (result == "<|start_header_id|>") {
                sawHeaderToken = true
                return
            }
            if (result == "<|end_header_id|>") {
                sawHeaderToken = false
                return
            }
            if (sawHeaderToken) return
        }

        // Skip leading whitespace before any real content
        if (generatedTokens.isEmpty() && (result == "\n" || result == "\n\n")) {
            return
        }

        generatedTokens.append(result)

        // Send token to Flutter via EventChannel (streaming mode)
        if (pendingResult == null && eventSink != null) {
            mainHandler.post {
                eventSink?.success(mapOf("type" to "token", "data" to result))
            }
        }
    }

    /**
     * Called by ExecuTorch with generation statistics (tokens/sec, timing, etc.)
     * Stats arrive as a JSON string from the runtime.
     */
    override fun onStats(stats: String) {
        Log.d(TAG, "Generation stats: $stats")

        // Parse tokens per second from stats JSON
        try {
            val json = JSONObject(stats)
            val numGeneratedTokens = json.optInt("generated_tokens", 0)
            val inferenceEndMs = json.optInt("inference_end_ms", 0)
            val promptEvalEndMs = json.optInt("prompt_eval_end_ms", 0)

            val tps = if (inferenceEndMs > promptEvalEndMs) {
                numGeneratedTokens.toFloat() / (inferenceEndMs - promptEvalEndMs) * 1000f
            } else 0f

            Log.d(TAG, "Performance: ${String.format("%.1f", tps)} tokens/sec ($numGeneratedTokens tokens)")

            // Send stats to Flutter
            mainHandler.post {
                eventSink?.success(mapOf(
                    "type" to "stats",
                    "data" to stats,
                    "tokensPerSecond" to tps.toDouble(),
                    "totalTokens" to numGeneratedTokens
                ))
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse stats: ${e.message}")
            mainHandler.post {
                eventSink?.success(mapOf("type" to "stats", "data" to stats))
            }
        }
    }

    // =========================================================================
    // EventChannel helpers
    // =========================================================================

    private fun sendStreamEvent(type: String, data: String) {
        mainHandler.post {
            eventSink?.success(mapOf("type" to type, "data" to data))
        }
    }

    private fun sendStreamError(error: String) {
        mainHandler.post {
            eventSink?.error("LLAMA_ERROR", error, null)
        }
    }

    // =========================================================================
    // Deep link support
    // =========================================================================

    private fun createDeepLinkReceiver(events: EventChannel.EventSink?): BroadcastReceiver {
        return object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val dataString = intent.dataString
                if (dataString != null) {
                    events?.success(dataString)
                } else {
                    events?.error("UNAVAILABLE", "Link unavailable", null)
                }
            }
        }
    }

    // =========================================================================
    // Cleanup
    // =========================================================================

    override fun onDestroy() {
        if (isGenerating) {
            llmModule?.stop()
        }
        llmModule = null
        isModelLoaded = false
        super.onDestroy()
    }
}
