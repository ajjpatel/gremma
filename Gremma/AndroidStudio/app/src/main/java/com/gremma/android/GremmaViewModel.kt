package com.gremma.android

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Calendar

data class GremmaState(
    val status: String = "Starting…",
    val modelName: String? = null,
    val indexReady: Boolean = false,
    val messages: List<ChatLine> = emptyList(),
    val records: List<MemoryRecord> = emptyList(),
    val busy: Boolean = false,
    val heard: String = "",
    val cameraRequest: Action? = null,
    val lastMs: Long = 0,
)

class GremmaViewModel(application: Application) : AndroidViewModel(application) {
    private val app: Application get() = getApplication()
    private val _state = MutableStateFlow(GremmaState())
    val state: StateFlow<GremmaState> = _state.asStateFlow()

    private val store = MemoryStore(application)
    private val gemma = GemmaService(application)
    private val embedder = Embedder(application)
    private val finder = Finder(store, embedder, gemma)
    private val people by lazy { PersonDetector(application) }
    private val pose by lazy { PoseDetector(application) }
    private val clips by lazy { ClipProcessor(store, gemma, embedder, people, pose) }
    private val work = Mutex()
    private val prefs = application.getSharedPreferences("gremma", Context.MODE_PRIVATE)

    val voice = Voice(application, onHeard = { ask(it) }, onState = { s -> _state.update { it.copy(heard = s) } })

    /** adb push models here: /sdcard/Android/data/com.gremma.android/files/models/ */
    private val modelDirs = listOfNotNull(application.getExternalFilesDir("models"), File(application.filesDir, "Models").apply { mkdirs() })
    /** The board's clips land here (adb push / downloader / Import clip). */
    val inbox: File = (application.getExternalFilesDir("clips") ?: File(application.filesDir, "clips")).apply { mkdirs() }

    init {
        refresh()
        viewModelScope.launch { loadModels() }
        viewModelScope.launch { watchInbox() }
    }

    private fun refresh() = _state.update { it.copy(records = store.all()) }

    private fun say(text: String, image: String? = null, speak: Boolean = true) {
        Log.i("Gremma", "say (${gemma.lastMs} ms): $text")
        _state.update { it.copy(messages = it.messages + ChatLine(false, text, image), lastMs = gemma.lastMs) }
        if (speak) voice.speak(text)
    }

    private fun status(s: String, busy: Boolean = _state.value.busy) = _state.update { it.copy(status = s, busy = busy) }

    private fun findModel(vararg names: String): File? =
        names.firstNotNullOfOrNull { n -> modelDirs.map { File(it, n) }.firstOrNull { it.exists() && it.length() > 0 } }

    private suspend fun loadModels() {
        val emb = findModel("embeddinggemma-2-740m.litertlm", "embeddinggemma-300m.litertlm")
        if (emb != null) runCatching { embedder.load(emb) }.onFailure { Log.w("Gremma", "embedder", it) }
        _state.update { it.copy(indexReady = embedder.isReady) }
        reindexMissing()
        val chat = findModel("gemma-4-E4B-it.litertlm", "gemma-4-E2B-it.litertlm")
        if (chat == null) {
            status("No Gemma model yet. Push gemma-4-E4B-it.litertlm to ${modelDirs.first()} or tap Add model.")
            return
        }
        status("Loading ${chat.name}…", busy = true)
        runCatching { gemma.load(chat) }
            .onSuccess { _state.update { it.copy(modelName = gemma.modelName, busy = false, status = "Ready. Tap the microphone and ask.") } }
            .onFailure { e -> status("Could not load ${chat.name}: ${e.message}", busy = false) }
    }

    private suspend fun reindexMissing() {
        if (!embedder.isReady) return
        val missing = store.all().filter { it.embedding == null }
        if (missing.isEmpty()) return
        missing.forEach { r -> store.delete(r.id); store.add(r.copy(embedding = embedder.embed(r.sentence(), false))) }
        refresh()
    }

    fun importModel(uri: Uri) = viewModelScope.launch {
        status("Copying model…", busy = true)
        runCatching {
            withContext(Dispatchers.IO) {
                val name = displayName(uri) ?: "model.litertlm"
                require(name.endsWith(".litertlm", true)) { "Choose a .litertlm model file." }
                val target = File(modelDirs.last(), name)
                app.contentResolver.openInputStream(uri)!!.use { input -> target.outputStream().use { input.copyTo(it) } }
            }
            loadModels()
        }.onFailure { e -> status(e.message ?: "Model import failed.", busy = false) }
    }

    fun importClip(uri: Uri) = viewModelScope.launch(Dispatchers.IO) {
        val name = displayName(uri) ?: "clip_${System.currentTimeMillis()}.mp4"
        app.contentResolver.openInputStream(uri)?.use { input -> File(inbox, name).outputStream().use { input.copyTo(it) } }
    }

    private fun displayName(uri: Uri): String? = app.contentResolver.query(uri, null, null, null, null)?.use { c ->
        val col = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (c.moveToFirst() && col >= 0) c.getString(col) else null
    }

    // ---- Asking ----

    fun ask(text: String) {
        val q = text.trim(); if (q.isEmpty()) return
        _state.update { it.copy(messages = it.messages + ChatLine(true, q), heard = "") }
        val intent = Router.route(q)
        if (intent in Router.NEEDS_PHOTO) {
            _state.update { it.copy(cameraRequest = intent) }
            return
        }
        viewModelScope.launch { work.withLock { answer(intent, q) } }
    }

    /** adb test hook: run a photo action on an image already on the phone. */
    fun askWithImage(action: Action, path: String) = onPhoto(Uri.fromFile(File(path)), action)

    fun quick(intent: Action) {
        if (intent in Router.NEEDS_PHOTO) _state.update { it.copy(cameraRequest = intent) }
        else viewModelScope.launch { work.withLock { answer(intent, intent.name.lowercase().replace('_', ' ')) } }
    }

    fun cameraHandled() = _state.update { it.copy(cameraRequest = null) }

    private suspend fun answer(intent: Action, q: String) {
        status("Thinking…", busy = true)
        try {
            when (intent) {
                Action.FIND -> finder.find(q).let { r -> say(r.answer, r.matches.firstOrNull()?.evidenceImage) }
                Action.WHAT_CHANGED -> {
                    val last = prefs.getLong("changesAsked", 0)
                    val since = if (last > 0 && store.all().any { it.kind != MemoryKind.SEEN && it.timeMs >= last }) last else startOfToday()
                    say(Routines.whatChanged(store, since), store.all().firstOrNull { it.kind != MemoryKind.SEEN && it.timeMs >= since }?.evidenceImage)
                    prefs.edit().putLong("changesAsked", System.currentTimeMillis()).apply()
                }
                Action.MEDICINE_STATUS -> say(Routines.medicineStatus(store),
                    store.all().firstOrNull { Routines.isMedicine(it.name) && it.timeMs >= startOfToday() }?.evidenceImage)
                Action.SUMMARY -> say(Routines.dailySummary(store))
                Action.VISITORS -> say(Routines.visitors(store))
                Action.LAST_MOVEMENT -> say(Routines.lastMovement(store))
                Action.HAZARDS -> Routines.floorItems(store).let { items ->
                    say(if (items.isEmpty()) "I haven't seen anything left on the floor today."
                        else items.take(3).joinToString(" ") { "A ${it.name} is ${it.location}, since ${clock(it.timeMs)}." }, items.firstOrNull()?.evidenceImage)
                }
                Action.LIST -> {
                    val seen = store.all().distinctBy { it.name.lowercase() }.take(10)
                    say(if (seen.isEmpty()) "I don't remember anything yet." else "I remember: " + seen.joinToString(", ") { it.name } + ".")
                }
                else -> {
                    if (!gemma.isReady) { say("The Gemma model is still loading."); return }
                    say(gemma.generate(Prompts.CHAT, q, maxTokens = 200))
                }
            }
        } catch (e: Exception) {
            Log.e("Gremma", "answer failed", e); say("Sorry, something went wrong: ${e.message}")
        } finally { status("Ready.", busy = false) }
    }

    fun onPhoto(uri: Uri, intent: Action) = viewModelScope.launch {
        work.withLock {
            status("Looking…", busy = true)
            try {
                val bmp = withContext(Dispatchers.IO) { Images.load(app, uri, 1024) }
                val photoName = store.saveImage(Images.jpeg(bmp), "photo_${System.currentTimeMillis()}.jpg")
                _state.update { it.copy(messages = it.messages + ChatLine(true, "📷 photo", photoName)) }
                if (!gemma.isReady && intent !in setOf(Action.READ_TEXT, Action.READ_MEDICINE, Action.READ_EXPIRY)) {
                    say("The Gemma model is still loading."); return@withLock
                }
                when (intent) {
                    Action.DESCRIBE -> say(gemma.generate(Prompts.SCENE, "Describe what is in front of me.", Images.png(bmp), 200))
                    Action.REMEMBER -> remember(bmp, photoName)
                    else -> read(bmp, intent)
                }
            } catch (e: Exception) {
                Log.e("Gremma", "photo failed", e); say("Sorry, I couldn't use that photo: ${e.message}")
            } finally { status("Ready.", busy = false) }
        }
    }

    private suspend fun remember(bmp: android.graphics.Bitmap, photoName: String) {
        val rows = gemma.generateRows(Prompts.MEMORY, "List the objects in this photo.", Images.png(bmp), 300)
        val now = System.currentTimeMillis()
        var id = store.nextId()
        val records = rows.filter { it.size >= 3 && it[0].isNotBlank() }.map { r ->
            MemoryRecord(id++, MemoryKind.SEEN, r[0].lowercase(), r[1], r[2], timeMs = now, source = "photo", afterImage = photoName)
        }.distinctBy { it.name + it.location }
        val indexed = records.map { it.copy(embedding = embedder.embed(it.sentence(), false)) }
        store.addAll(indexed); refresh()
        say(if (indexed.isEmpty()) "I couldn't make out any objects. Try holding the phone steady with more light."
            else "I'll remember ${indexed.size} things: " + indexed.take(6).joinToString(", ") { "${it.name} ${it.location}" } + ".")
    }

    private suspend fun read(bmp: android.graphics.Bitmap, intent: Action) {
        val ocr = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).process(InputImage.fromBitmap(bmp, 0)).await().text
        if (ocr.isBlank()) { say("I couldn't find readable text. Try moving the label closer and holding steady."); return }
        if (!gemma.isReady) { say(ocr); return }
        val system = when (intent) { Action.READ_MEDICINE -> Prompts.READ_MEDICINE; Action.READ_EXPIRY -> Prompts.READ_EXPIRY; else -> Prompts.READ_TEXT }
        say(gemma.generate(system, "OCR text:\n$ocr", Images.png(bmp), 300, visionTokens = 280))
    }

    // ---- Board clips ----

    private suspend fun watchInbox() {
        val done = prefs.getStringSet("clipsDone", emptySet())!!.toMutableSet()
        while (true) {
            val ready = inbox.listFiles()?.filter { f ->
                f.name !in done && !f.name.startsWith(".") &&
                    (f.isDirectory || f.extension.lowercase() in setOf("mp4", "mov", "mkv", "webm")) &&
                    System.currentTimeMillis() - newest(f) > 3000
            }?.sortedBy { it.lastModified() }.orEmpty()
            for (clip in ready) {
                if (!gemma.isReady) break
                work.withLock {
                    status("New activity from the home camera…", busy = true)
                    val outcome = runCatching { withContext(Dispatchers.Default) { clips.process(clip) } }
                        .onFailure { Log.e("Gremma", "clip failed", it) }.getOrNull()
                    done += clip.name; prefs.edit().putStringSet("clipsDone", done.toSet()).apply()
                    refresh()
                    outcome?.events?.firstOrNull()?.let { say("Home camera: " + outcome.note, it.evidenceImage, speak = false) }
                    outcome?.hazards?.firstOrNull()?.let { say(Routines.hazardAlert(it), it.evidenceImage) }
                    prefs.edit().remove("quietAlertFor").apply()
                    status("Ready.", busy = false)
                }
            }
            checkMedicineReminder()
            checkInactivity()
            delay(3000)
        }
    }

    /** Daytime only; one alert per quiet stretch. Threshold in minutes, default 3 hours (set lower for the demo). */
    private fun checkInactivity() {
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        if (hour < 8 || hour >= 22) return
        val last = store.activity().firstOrNull()?.timeMs ?: return
        if (prefs.getLong("quietAlertFor", 0) == last) return
        Routines.inactivityAlert(store, prefs.getInt("quietMin", 180) / 60.0)?.let {
            prefs.edit().putLong("quietAlertFor", last).apply()
            say("Alert: $it")
        }
    }

    fun setQuietMinutes(min: Int) = prefs.edit().putInt("quietMin", min).apply()

    private fun newest(f: File): Long = if (f.isDirectory) f.listFiles()?.maxOfOrNull { it.lastModified() } ?: f.lastModified() else f.lastModified()

    private fun checkMedicineReminder() {
        val hour = prefs.getInt("medHour", 9)
        val now = Calendar.getInstance()
        val today = startOfToday()
        if (now.get(Calendar.HOUR_OF_DAY) < hour || prefs.getLong("remindedOn", 0) == today) return
        if (store.all().none { Routines.isMedicine(it.name) }) return
        prefs.edit().putLong("remindedOn", today).apply()
        if (!Routines.medicineTakenToday(store)) say("Reminder: I haven't seen your medicine picked up today.")
    }

    fun forget(id: Long) { store.delete(id); refresh() }

    fun clearAll() {
        store.clear(); prefs.edit().remove("clipsDone").remove("changesAsked").apply(); refresh()
        _state.update { it.copy(messages = emptyList()) }
    }

    fun imageFile(name: String?) = store.imageFile(name)

    override fun onCleared() { voice.close(); gemma.close(); embedder.close(); super.onCleared() }
}
