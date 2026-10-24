package com.gremma.android

import android.content.Context
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ResponseFormat
import com.google.ai.edge.litertlm.SamplerConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

private const val TAG = "GremmaGemma"

/** One resident Gemma engine; every request gets a fresh conversation so prompts never leak into each other. */
class GemmaService(private val context: Context) {
    private var engine: Engine? = null
    private val lock = Mutex()
    var modelName: String? = null; private set
    var lastMs: Long = 0; private set

    val isReady: Boolean get() = engine != null

    suspend fun load(file: File) = withContext(Dispatchers.IO) {
        lock.withLock {
            engine?.close(); engine = null
            val started = System.currentTimeMillis()
            val next = Engine(EngineConfig(
                modelPath = file.absolutePath,
                backend = Backend.GPU(),
                visionBackend = Backend.GPU(),
                maxNumTokens = 4096,
                cacheDir = context.cacheDir.absolutePath,
            ))
            next.initialize()
            engine = next
            modelName = file.name
            Log.i(TAG, "loaded ${file.name} in ${System.currentTimeMillis() - started} ms")
        }
    }

    /** Greedy generation. [image] is PNG/JPEG bytes placed before the text, as Gallery does. */
    suspend fun generate(system: String, prompt: String, image: ByteArray? = null, maxTokens: Int = 400): String =
        run(system, prompt, image, maxTokens, null)

    /** Constrained JSON generation; falls back to the first {...} block if the runtime returns extra text. */
    suspend fun generateJson(system: String, prompt: String, schema: String, image: ByteArray? = null, maxTokens: Int = 500): String {
        val raw = run(system, prompt, image, maxTokens, schema)
        val start = raw.indexOf('{'); val end = raw.lastIndexOf('}')
        return if (start >= 0 && end > start) raw.substring(start, end + 1) else raw
    }

    private suspend fun run(system: String, prompt: String, image: ByteArray?, maxTokens: Int, schema: String?): String =
        withContext(Dispatchers.IO) {
            lock.withLock {
                val e = engine ?: error("The Gemma model is not loaded yet.")
                val started = System.currentTimeMillis()
                val config = ConversationConfig(
                    systemInstruction = Contents.of(system),
                    samplerConfig = SamplerConfig(1, 1.0, 0.0, 0),
                    maxOutputToken = maxTokens,
                    enableResponseFormat = schema != null,
                )
                e.createConversation(config).use { conv ->
                    val parts = buildList {
                        if (image != null) add(Content.ImageBytes(image))
                        add(Content.Text(prompt))
                    }
                    val reply = if (schema != null) {
                        conv.sendMessage(Contents.of(parts), responseFormat = ResponseFormat.json(schema))
                    } else {
                        conv.sendMessage(Contents.of(parts))
                    }
                    lastMs = System.currentTimeMillis() - started
                    Log.i(TAG, "generate ${lastMs} ms image=${image != null} json=${schema != null}")
                    reply.toString().trim()
                }
            }
        }

    fun close() { engine?.close(); engine = null }
}
