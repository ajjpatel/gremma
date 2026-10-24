package com.gremma.android

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Conversation
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.io.File

data class SavedMemory(val name: String, val room: String, val location: String, val aliases: List<String> = emptyList())
data class GremmaState(
    val status: String = "Ready for your first question.", val modelName: String? = null,
    val messages: List<String> = emptyList(), val memories: List<SavedMemory> = emptyList(),
    val busy: Boolean = false, val error: String? = null
)

class GremmaViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(GremmaState())
    val state: StateFlow<GremmaState> = _state.asStateFlow()
    private var engine: Engine? = null
    private var conversation: Conversation? = null
    private val modelDir = File(application.filesDir, "Models").apply { mkdirs() }
    private val memoryStore = AndroidMemoryStore(application)

    init { _state.value = _state.value.copy(memories = memoryStore.all()) }

    fun importModel(uri: Uri) = viewModelScope.launch {
        setBusy("Importing local model…")
        try {
            val name = withContext(Dispatchers.IO) {
                val displayName = getApplication<Application>().contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val col = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (c.moveToFirst() && col >= 0) c.getString(col) else "model.litertlm"
                } ?: "model.litertlm"
                require(displayName.endsWith(".litertlm", ignoreCase = true)) { "Choose a .litertlm model file." }
                val target = File(modelDir, displayName)
                getApplication<Application>().contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Could not open the selected file." }
                    input.copyTo(target.outputStream())
                }
                displayName
            }
            loadModel(File(modelDir, name))
        } catch (e: Exception) { fail(e.message ?: "Model import failed.") }
    }

    private suspend fun loadModel(file: File) = withContext(Dispatchers.IO) {
        conversation?.close(); engine?.close()
        val next = Engine(EngineConfig(modelPath = file.absolutePath, backend = Backend.CPU(), cacheDir = getApplication<Application>().cacheDir.absolutePath))
        next.initialize()
        val chat = next.createConversation()
        engine = next; conversation = chat
        _state.value = _state.value.copy(modelName = file.name, busy = false, status = "Local Gemma is ready.", error = null)
    }

    fun send(text: String) = viewModelScope.launch {
        val question = text.trim(); if (question.isEmpty()) return@launch
        val found = memoryStore.search(question)
        if (found != null) {
            _state.value = _state.value.copy(messages = _state.value.messages + "You: $question" + "Gremma: $found")
            return@launch
        }
        val chat = conversation ?: run { fail("Import a .litertlm chat model first."); return@launch }
        setBusy("Thinking on this device…")
        try {
            val answer = withContext(Dispatchers.IO) { chat.sendMessage(question).text }
            _state.value = _state.value.copy(messages = _state.value.messages + "You: $question" + "Gremma: $answer", busy = false, status = "Ready.", error = null)
        } catch (e: Exception) { fail(e.message ?: "Local model request failed.") }
    }

    fun readImage(uri: Uri) = viewModelScope.launch {
        setBusy("Reading photo on this device…")
        try {
            val image = InputImage.fromFilePath(getApplication(), uri)
            val result = withContext(Dispatchers.IO) { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).process(image).await().text }
            val spoken = result.ifBlank { "I couldn't find readable text in that photo." }
            _state.value = _state.value.copy(messages = _state.value.messages + "Gremma: $spoken", busy = false, status = "Photo reading complete.", error = null)
        } catch (e: Exception) { fail(e.message ?: "Could not read that photo.") }
    }

    private fun setBusy(status: String) { _state.value = _state.value.copy(busy = true, status = status, error = null) }
    private fun fail(message: String) { _state.value = _state.value.copy(busy = false, error = message, status = "Ready.") }
    override fun onCleared() { conversation?.close(); engine?.close(); super.onCleared() }
}
