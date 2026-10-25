package com.gremma.android

import android.app.Application

class GremmaApp : Application() {
    val core by lazy { GremmaCore(this) }
}
