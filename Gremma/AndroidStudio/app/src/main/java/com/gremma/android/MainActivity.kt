package com.gremma.android

import android.Manifest
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : ComponentActivity() {
    private val vm: GremmaCore get() = (application as GremmaApp).core
    private val notifyPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startForegroundService(android.content.Intent(this, WatchService::class.java))
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            notifyPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xFFFFC94D), onPrimary = Color.Black)) {
                GremmaScreen(vm)
            }
        }
        handle(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        vm.startCameraReceiver()
    }

    override fun onStop() {
        // The receiver keeps running in WatchService; only the screen-on flag follows the activity.
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onStop()
    }

    /** adb shell am start -n com.gremma.android/.MainActivity --es ask "where are my keys" */
    private fun handle(intent: android.content.Intent?) {
        intent?.getStringExtra("ask")?.let { vm.ask(it) }
        intent?.getStringExtra("image")?.let { path ->
            vm.askWithImage(Action.valueOf(intent.getStringExtra("action") ?: "DESCRIBE"), path)
        }
        if (intent?.hasExtra("quietMin") == true) vm.setQuietMinutes(intent.getIntExtra("quietMin", 180))
        intent?.removeExtra("ask"); intent?.removeExtra("image")
    }
}

@Composable
fun GremmaScreen(vm: GremmaCore) {
    val state by vm.state.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var photoUri by remember { mutableStateOf<Uri?>(null) }
    var photoAction by remember { mutableStateOf<Action?>(null) }
    var showCamera by remember { mutableStateOf(false) }
    var pairingCopied by remember { mutableStateOf(false) }

    if (showCamera) {
        AlertDialog(onDismissRequest = { showCamera = false }, title = { Text("Home camera") }, text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(state.camera.status)
                Text("Keep this phone on the same Wi-Fi as the camera. Gremma keeps receiving in the background; clips are saved before processing and resume after a restart.")
                Text(state.camera.endpoint.ifBlank { "Connect this phone to Wi-Fi, then reopen this setup screen." })
                if (state.camera.running) {
                    OutlinedButton(enabled = state.camera.endpoint.isNotBlank(), onClick = {
                        val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                        val clip = android.content.ClipData.newPlainText("Gremma camera pairing", state.camera.pairingText())
                        clip.description.extras = android.os.PersistableBundle().apply {
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                        }
                        clipboard.setPrimaryClip(clip)
                        pairingCopied = true
                    }) { Text(if (pairingCopied) "Board setup copied" else "Copy board setup") }
                } else {
                    OutlinedButton(onClick = vm::startCameraReceiver) { Text("Start receiver") }
                }
            }
        }, confirmButton = { TextButton(onClick = { showCamera = false }) { Text("Done") } })
    }

    val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) vm.voice.listen() }
    val takePhoto = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val uri = photoUri; val action = photoAction
        if (ok && uri != null && action != null) vm.onPhoto(uri, action)
    }
    val pickModel = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { it?.let(vm::importModel) }
    val pickClip = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { it?.let(vm::importClip) }

    LaunchedEffect(state.cameraRequest) {
        val action = state.cameraRequest ?: return@LaunchedEffect
        vm.cameraHandled()
        val file = File(context.cacheDir, "photos").apply { mkdirs() }.let { File(it, "capture.jpg") }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        photoUri = uri; photoAction = action
        takePhoto.launch(uri)
    }

    Scaffold(containerColor = Color(0xFF101014)) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(horizontal = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Gremma", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                TextButton(onClick = { vm.refreshCameraAddress(); pairingCopied = false; showCamera = true }) { Text("Camera") }
                Spacer(Modifier.width(8.dp))
                Text(listOfNotNull(state.modelName?.removeSuffix(".litertlm"), if (state.indexReady) "index on" else null,
                    if (state.lastMs > 0) "${state.lastMs} ms" else null).joinToString(" · "), color = Color.Gray, fontSize = 12.sp)
            }
            Text(state.heard.ifBlank { state.status }, color = Color.LightGray, fontSize = 16.sp,
                modifier = Modifier.semantics { contentDescription = "Status: ${state.status}" })
            TabRow(selectedTabIndex = tab, containerColor = Color.Transparent) {
                listOf("Ask", "Timeline", "Memories").forEachIndexed { i, t ->
                    Tab(selected = tab == i, onClick = { tab = i }, text = { Text(t, fontSize = 16.sp) })
                }
            }
            Box(Modifier.weight(1f)) {
                when (tab) {
                    0 -> ChatList(state.messages, vm)
                    1 -> RecordList(state.records.filter { it.kind != MemoryKind.SEEN }, vm, "No changes from the home camera yet.")
                    else -> RecordList(state.records.filter { it.kind == MemoryKind.SEEN }, vm, "Nothing remembered yet. Tap Remember and take a photo of a room.")
                }
            }
            if (tab == 0) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(Action.REMEMBER to "Remember", Action.DESCRIBE to "Describe", Action.READ_TEXT to "Read",
                        Action.READ_MEDICINE to "Medicine label", Action.WHAT_CHANGED to "What changed", Action.MEDICINE_STATUS to "Meds today?",
                        Action.VISITORS to "Visitors?", Action.SUMMARY to "My day").forEach { (a, label) ->
                        OutlinedButton(onClick = { vm.quick(a) }, enabled = !state.busy) { Text(label) }
                    }
                }
                var text by rememberSaveable { mutableStateOf("") }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 8.dp)) {
                    OutlinedTextField(text, { text = it }, Modifier.weight(1f), placeholder = { Text("Where are my keys?") }, singleLine = true)
                    Spacer(Modifier.width(6.dp))
                    Button(onClick = { vm.ask(text); text = "" }, enabled = text.isNotBlank() && !state.busy) { Text("Send") }
                }
                Button(
                    onClick = { micPermission.launch(Manifest.permission.RECORD_AUDIO) },
                    enabled = !state.busy,
                    shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxWidth().height(84.dp).semantics { contentDescription = "Talk to Gremma" },
                ) { Text(if (state.busy) "Working…" else "🎤  Tap and ask", fontSize = 24.sp, color = Color.Black) }
            } else {
                Row(Modifier.padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedButton(onClick = { pickClip.launch(arrayOf("video/*")) }) { Text("Import clip") }
                    OutlinedButton(onClick = { pickModel.launch(arrayOf("*/*")) }) { Text("Add model") }
                    TextButton(onClick = vm::clearAll) { Text("Clear all", color = Color(0xFFFF8080)) }
                }
            }
        }
    }
}

@Composable
private fun ChatList(messages: List<ChatLine>, vm: GremmaCore) {
    val list = rememberLazyListState()
    LaunchedEffect(messages.size) { if (messages.isNotEmpty()) list.animateScrollToItem(messages.size - 1) }
    LazyColumn(state = list, verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxSize().padding(vertical = 8.dp)) {
        items(messages) { m ->
            Column(Modifier.fillMaxWidth(), horizontalAlignment = if (m.fromUser) Alignment.End else Alignment.Start) {
                Column(Modifier.background(if (m.fromUser) Color(0xFF3A3320) else Color(0xFF22232A), RoundedCornerShape(14.dp)).padding(12.dp)) {
                    Thumb(vm.imageFile(m.image), 220)
                    Text(m.text, fontSize = 18.sp, color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun RecordList(records: List<MemoryRecord>, vm: GremmaCore, empty: String) {
    if (records.isEmpty()) { Text(empty, color = Color.Gray, modifier = Modifier.padding(16.dp)); return }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxSize().padding(vertical = 8.dp)) {
        items(records, key = { it.id }) { r ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(10.dp)) {
                    Text("${clock(r.timeMs)} · ${r.kind.name.lowercase().replace('_', ' ')}", color = Color.Gray, fontSize = 12.sp)
                    Text(r.spoken(), fontSize = 16.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (r.kind == MemoryKind.SEEN) Thumb(vm.imageFile(r.afterImage), 120)
                        else { Thumb(vm.imageFile(r.beforeImage), 120); if (r.afterImage != r.beforeImage) Thumb(vm.imageFile(r.afterImage), 120) }
                    }
                    TextButton(onClick = { vm.forget(r.id) }) { Text("Forget") }
                }
            }
        }
    }
}

@Composable
private fun Thumb(file: File?, size: Int) {
    if (file == null) return
    val bmp = remember(file.path) { BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 2 })?.asImageBitmap() } ?: return
    Image(bmp, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(size.dp).padding(bottom = 6.dp))
}
