package com.tampagamingguild.tgg_mobile

import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth's Android BiometricPrompt integration requires a
// FragmentActivity-based host to show the biometric dialog -- plain
// FlutterActivity (Flutter's default) doesn't support it.
class MainActivity : FlutterFragmentActivity()
