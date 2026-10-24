package com.gremma.android

import android.content.Context
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.EmbeddingEngine
import com.google.ai.edge.litertlm.EmbeddingEngineConfig
import com.google.ai.edge.litertlm.EmbeddingOptions
import com.google.ai.edge.litertlm.InputData
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/** EmbeddingGemma, kept resident next to the chat model (never swapped with it). */
class Embedder(private val context: Context) {
    private var engine: EmbeddingEngine? = null
    private val lock = Mutex()
    val isReady: Boolean get() = engine != null

    suspend fun load(file: File) = withContext(Dispatchers.IO) {
        lock.withLock {
            engine?.close()
            val next = EmbeddingEngine(EmbeddingEngineConfig(
                modelPath = file.absolutePath,
                backend = Backend.CPU(),
                cacheDir = context.cacheDir.absolutePath,
            ))
            next.initialize()
            engine = next
            Log.i("GremmaEmbed", "loaded ${file.name}")
        }
    }

    /** Prefixes validated on the Mac (recall@5 17/17 on the find test log). */
    suspend fun embed(text: String, isQuery: Boolean): FloatArray? = withContext(Dispatchers.IO) {
        lock.withLock {
            val e = engine ?: return@withLock null
            val prefixed = if (isQuery) "task: search query | text: $text" else "task: search result | text: $text"
            runCatching { e.computeEmbedding(listOf(InputData.Text(prefixed)), EmbeddingOptions(normalize = true)).embedding }
                .onFailure { Log.w("GremmaEmbed", "embed failed", it) }
                .getOrNull()
        }
    }

    fun close() { engine?.close(); engine = null }
}

fun dot(a: FloatArray, b: FloatArray): Float {
    var s = 0f
    for (i in 0 until minOf(a.size, b.size)) s += a[i] * b[i]
    return s
}
