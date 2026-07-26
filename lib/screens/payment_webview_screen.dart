import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Generic in-app webview for a Stripe Checkout (or pay-entrance.php) flow.
/// Watches every URL the webview navigates to for one of [terminalMarkers]
/// (e.g. 'status=success', 'status=cash_pending', 'status=cancelled') and
/// pops with that marker the moment one appears -- the actual payment
/// processing already happened server-side by then (see renew.php's /
/// pay-entrance.php's "run before auth check" success handling), this is
/// just how the app notices it's done. Pops with null if the user taps the
/// close button instead.
class PaymentWebViewScreen extends StatefulWidget {
  final String title;
  final String initialUrl;
  final List<String> terminalMarkers;

  const PaymentWebViewScreen({
    super.key,
    required this.title,
    required this.initialUrl,
    this.terminalMarkers = const ['status=success', 'status=cash_pending', 'status=cancelled'],
  });

  @override
  State<PaymentWebViewScreen> createState() => _PaymentWebViewScreenState();
}

class _PaymentWebViewScreenState extends State<PaymentWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: _checkTerminal,
        onPageFinished: (url) {
          _checkTerminal(url);
          if (mounted) setState(() => _loading = false);
        },
      ))
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  void _checkTerminal(String url) {
    if (_closing) return;
    for (final marker in widget.terminalMarkers) {
      if (!url.contains(marker)) continue;
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(marker);
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
