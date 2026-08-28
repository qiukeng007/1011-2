import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 详情页：在 APP 内嵌 WebView 打开银豹详情（货流单/销售单等），
/// 自动注入门店 Cookie，保持登录状态，不跳出到外部浏览器
class DetailWebViewPage extends StatefulWidget {
  final String url;
  final String? cookie;
  final String title;

  const DetailWebViewPage({
    super.key,
    required this.url,
    this.cookie,
    this.title = '详情',
  });

  @override
  State<DetailWebViewPage> createState() => _DetailWebViewPageState();
}

class _DetailWebViewPageState extends State<DetailWebViewPage> {
  InAppWebViewController? _ctrl;
  bool _loading = true;
  String? _error;

  /// 把门店 Cookie 注入 WebView（与微信登录页一致），再加载详情地址
  Future<void> _seedAndLoad(InAppWebViewController c) async {
    final cookie = widget.cookie;
    if (cookie != null && cookie.isNotEmpty) {
      try {
        final uri = Uri.parse(widget.url);
        final base = WebUri('${uri.scheme}://${uri.authority}');
        for (final part in cookie.split(';')) {
          final idx = part.indexOf('=');
          if (idx <= 0) continue;
          await CookieManager.instance().setCookie(
            url: base,
            name: part.substring(0, idx).trim(),
            value: part.substring(idx + 1).trim(),
            path: '/',
            domain: uri.host,
          );
        }
      } catch (_) {}
    }
    c.loadUrl(urlRequest: URLRequest(url: WebUri(widget.url)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
          tooltip: '关闭',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => _ctrl?.reload(),
          ),
        ],
      ),
      body: Stack(children: [
        InAppWebView(
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            useShouldOverrideUrlLoading: false,
          ),
          onWebViewCreated: (c) async {
            _ctrl = c;
            await _seedAndLoad(c);
          },
          onLoadStop: (c, url) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = null;
              });
            }
          },
          onReceivedError: (c, req, err) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = err.description;
              });
            }
          },
        ),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
        if (_error != null)
          Positioned.fill(
            child: Container(
              color: Colors.white,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      size: 40, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text(
                    '页面加载失败：$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _error = null;
                      });
                      _ctrl?.reload();
                    },
                    child: const Text('重新加载'),
                  ),
                ],
              ),
            ),
          ),
      ]),
    );
  }
}
