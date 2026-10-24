package com.gremma.android

import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme(colorScheme = darkColorScheme()) { GremmaScreen() } }
    }
}

@Composable
private fun GremmaScreen(vm: GremmaViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    var text by remember { mutableStateOf("") }
    val modelPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? -> uri?.let(vm::importModel) }
    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? -> uri?.let(vm::readImage) }

    Scaffold(bottomBar = {
        Column(Modifier.fillMaxWidth().padding(12.dp)) {
            OutlinedTextField(value = text, onValueChange = { text = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Ask Gremma") })
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                Button(onClick = { vm.send(text); text = "" }, enabled = text.isNotBlank() && !state.busy) { Text("Send") }
                OutlinedButton(onClick = { imagePicker.launch("image/*") }) { Text("Read photo") }
                OutlinedButton(onClick = { modelPicker.launch(arrayOf("*/*")) }) { Text("Add model") }
            }
        }
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Text("Gremma", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 20.dp)) }
            item { Text(state.status, style = MaterialTheme.typography.bodyMedium) }
            if (state.modelName == null) item {
                Text("Import a compatible .litertlm model to start. Models run locally on this device.", modifier = Modifier.padding(vertical = 8.dp))
            } else item { Text("Local model · ${state.modelName}") }
            if (state.busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            items(state.messages) { message ->
                Card(Modifier.fillMaxWidth()) { Text(message, Modifier.padding(16.dp), style = MaterialTheme.typography.bodyLarge) }
            }
            if (state.memories.isNotEmpty()) item {
                Text("Saved observations", style = MaterialTheme.typography.titleLarge)
                state.memories.take(20).forEach { Text("${it.name} · ${it.room} · ${it.location}") }
            }
            state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        }
    }
}
