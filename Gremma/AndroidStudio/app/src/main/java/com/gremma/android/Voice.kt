package com.gremma.android

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.util.Log
import java.util.Locale

/** On-device speech in (when the phone supports it) and TextToSpeech out. */
class Voice(private val context: Context, private val onHeard: (String) -> Unit, private val onState: (String) -> Unit) {
    private var recognizer: SpeechRecognizer? = null
    private var ttsReady = false
    private lateinit var tts: TextToSpeech

    init {
        tts = TextToSpeech(context) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) tts.language = Locale.US
        }
    }

    val onDevice: Boolean = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    fun listen() {
        stopSpeaking()
        recognizer?.destroy()
        val r = if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = onState("Listening…")
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() = onState("Thinking…")
            override fun onError(error: Int) { Log.w("GremmaVoice", "speech error $error"); onState(if (error == SpeechRecognizer.ERROR_NO_MATCH) "I didn't catch that." else "") }
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                onState("")
                if (text.isNotBlank()) onHeard(text)
            }
            override fun onPartialResults(partialResults: Bundle?) {
                partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { onState(it) }
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        })
    }

    fun stopListening() { recognizer?.stopListening() }

    fun speak(text: String) {
        if (ttsReady) tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "gremma")
    }

    fun stopSpeaking() { if (ttsReady) tts.stop() }

    fun close() { recognizer?.destroy(); tts.shutdown() }
}
